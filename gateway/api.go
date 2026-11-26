// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/netip"
	"sort"
	"strconv"
	"strings"
	"time"
)

// Schnittstelle fuer die App, NUR im Tunnel (Port 80 im Netzstapel).
//
// Jede Anfrage braucht zweierlei, und beides muss zur selben Person gehoeren:
//  1. den WireGuard-Absender (Peer-Adresse) — beweist das Geraet,
//  2. das Authentik-Token (Bearer) — beweist die Person.
// Ein fremdes Token ueber das eigene Geraet oder das eigene Token ueber ein
// fremdes Geraet wird abgewiesen. HTTP statt HTTPS ist hier richtig: der
// Tunnel verschluesselt schon und weist den Absender aus.

type anfrage struct {
	peer  *Peer
	konto *Konto
}

type ctxSchluessel struct{}

func (g *Gateway) mitAnmeldung(h func(http.ResponseWriter, *http.Request, anfrage)) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		var peer *Peer
		if err == nil {
			peer = g.Peer(ap.Addr())
		}
		if peer == nil {
			http.Error(w, `{"error":"unbekanntes Geraet"}`, http.StatusForbidden)
			return
		}
		token := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
		defer cancel()
		k, err := g.konten.Pruefen(ctx, token)
		if err != nil {
			status := http.StatusUnauthorized
			if !errors.Is(err, ErrNichtAngemeldet) {
				status = http.StatusServiceUnavailable
			}
			text := "Anmeldung abgelaufen"
			if status != http.StatusUnauthorized {
				text = "Anmeldung konnte nicht geprueft werden (Authentik nicht erreichbar)"
			}
			g.log.Schreiben(Eintrag{Aktion: "anmeldung", Ergebnis: "abgewiesen", Grund: err.Error()})
			json200(w, status, map[string]string{"error": text})
			return
		}
		if k.Email != peer.Email {
			g.log.Schreiben(Eintrag{Aktion: "anfrage", Email: k.Email, Peer: peer.IP.String(), Ergebnis: "abgewiesen", Grund: "Token gehoert nicht zum Geraet"})
			json200(w, http.StatusForbidden, map[string]string{"error": "Geraet gehoert einer anderen Person"})
			return
		}
		h(w, r.WithContext(context.WithValue(r.Context(), ctxSchluessel{}, peer)), anfrage{peer, k})
	}
}

func json200(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(v)
}

// Rechte der Person an einem Computer, aus Proxmox fuer IHREN Benutzer
// ermittelt (Pfad /vms/<id> und, falls in einem Pool, /pool/<name>).
// 30 Sekunden gemerkt, damit eine Liste nicht dutzende Anfragen ausloest;
// eine in Proxmox entzogene Berechtigung greift also spaetestens nach 30 s.
func (g *Gateway) rechteVon(ctx context.Context, benutzer string, vm VM) (map[string]bool, error) {
	pfade := []string{"/vms/" + strconv.Itoa(vm.VMID)}
	if vm.Pool != "" {
		pfade = append(pfade, "/pool/"+vm.Pool)
	}
	alle := map[string]bool{}
	for _, pfad := range pfade {
		schl := benutzer + " " + pfad
		g.mu.Lock()
		m, ok := g.rechte[schl]
		g.mu.Unlock()
		if !ok || g.jetzt().Sub(m.zeit) > 30*time.Second {
			privs, err := g.pve.Rechte(ctx, benutzer, pfad)
			if err != nil {
				return nil, err
			}
			m = rechteMerker{privs, g.jetzt()}
			g.mu.Lock()
			g.rechte[schl] = m
			g.mu.Unlock()
		}
		for p := range m.privs {
			alle[p] = true
		}
	}
	return alle, nil
}

type computerAntwort struct {
	VMID        int    `json:"vmid"`
	Name        string `json:"name"`
	Laeuft      bool   `json:"laeuft"`
	Oeffnen     bool   `json:"darf_oeffnen"`
	Einschalten bool   `json:"darf_einschalten"`
}

// sichtbar: die Computer, an denen die Person ueberhaupt etwas darf.
func (g *Gateway) sichtbar(ctx context.Context, k *Konto) ([]computerAntwort, map[int]VM, error) {
	aktiv, err := g.pve.BenutzerAktiv(ctx, k.Benutzer)
	if err != nil {
		return nil, nil, err
	}
	if !aktiv {
		return []computerAntwort{}, map[int]VM{}, nil
	}
	vms, err := g.pve.Computer(ctx)
	if err != nil {
		return nil, nil, err
	}
	liste := []computerAntwort{}
	nachID := map[int]VM{}
	for _, vm := range vms {
		r, err := g.rechteVon(ctx, k.Benutzer, vm)
		if err != nil {
			return nil, nil, err
		}
		if !(r["VM.Audit"] || r["VM.Console"]) {
			continue
		}
		name := vm.Name
		if name == "" {
			name = "Computer " + strconv.Itoa(vm.VMID)
		}
		liste = append(liste, computerAntwort{vm.VMID, name, vm.Status == "running", r["VM.Console"], r["VM.PowerMgmt"]})
		nachID[vm.VMID] = vm
	}
	sort.Slice(liste, func(i, j int) bool { return strings.ToLower(liste[i].Name) < strings.ToLower(liste[j].Name) })
	return liste, nachID, nil
}

// pruefen: darf k an vmid das Recht priv? Die Maschine (und ihr Knoten) kommt
// IMMER aus der eigenen Liste des Gateways, nie aus der Anfrage.
func (g *Gateway) pruefen(ctx context.Context, k *Konto, vmidText, priv string) (VM, int, string) {
	vmid, err := strconv.Atoi(vmidText)
	if err != nil || vmid <= 0 {
		return VM{}, http.StatusBadRequest, "ungueltige Nummer"
	}
	aktiv, err := g.pve.BenutzerAktiv(ctx, k.Benutzer)
	if err != nil {
		return VM{}, http.StatusBadGateway, "Proxmox nicht erreichbar"
	}
	if !aktiv {
		return VM{}, http.StatusForbidden, "Benutzer in Proxmox nicht aktiv"
	}
	vms, err := g.pve.Computer(ctx)
	if err != nil {
		return VM{}, http.StatusBadGateway, "Proxmox nicht erreichbar"
	}
	for _, vm := range vms {
		if vm.VMID != vmid {
			continue
		}
		r, err := g.rechteVon(ctx, k.Benutzer, vm)
		if err != nil {
			return VM{}, http.StatusBadGateway, "Proxmox nicht erreichbar"
		}
		if !r[priv] {
			return VM{}, http.StatusForbidden, "keine Berechtigung (" + priv + ")"
		}
		return vm, 0, ""
	}
	// Unbekannt und "nicht erlaubt" sehen gleich aus: niemand soll per
	// Durchprobieren herausfinden, welche Nummern es gibt.
	return VM{}, http.StatusForbidden, "keine Berechtigung (" + priv + ")"
}

func (g *Gateway) Schnittstelle() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /gesundheit", func(w http.ResponseWriter, r *http.Request) {
		// Nur fuer bekannte Peers; sagt der App "im Haus erreichbar".
		ap, err := netip.ParseAddrPort(r.RemoteAddr)
		if err != nil || g.Peer(ap.Addr()) == nil {
			http.Error(w, "", http.StatusForbidden)
			return
		}
		json200(w, 200, map[string]bool{"ok": true})
	})
	m.HandleFunc("GET /ich", g.mitAnmeldung(func(w http.ResponseWriter, r *http.Request, a anfrage) {
		json200(w, 200, map[string]string{"name": a.konto.Name, "email": a.konto.Email, "benutzer": a.konto.Benutzer})
	}))
	m.HandleFunc("GET /computer", g.mitAnmeldung(func(w http.ResponseWriter, r *http.Request, a anfrage) {
		liste, _, err := g.sichtbar(r.Context(), a.konto)
		if err != nil {
			g.log.Schreiben(Eintrag{Aktion: "liste", Email: a.konto.Email, Benutzer: a.konto.Benutzer, Ergebnis: "fehler", Grund: err.Error()})
			json200(w, http.StatusBadGateway, map[string]string{"error": "Proxmox nicht erreichbar"})
			return
		}
		json200(w, 200, liste)
	}))
	m.HandleFunc("POST /computer/{vmid}/einschalten", g.mitAnmeldung(func(w http.ResponseWriter, r *http.Request, a anfrage) {
		vm, status, grund := g.pruefen(r.Context(), a.konto, r.PathValue("vmid"), "VM.PowerMgmt")
		e := Eintrag{Aktion: "einschalten", Email: a.konto.Email, Benutzer: a.konto.Benutzer, Peer: a.peer.IP.String(), VMID: vm.VMID}
		if status != 0 {
			e.Ergebnis, e.Grund = "abgewiesen", grund
			g.log.Schreiben(e)
			json200(w, status, map[string]string{"error": grund})
			return
		}
		if err := g.pve.Starten(r.Context(), vm); err != nil {
			e.Ergebnis, e.Grund = "fehler", err.Error()
			g.log.Schreiben(e)
			json200(w, http.StatusBadGateway, map[string]string{"error": "Einschalten ging nicht"})
			return
		}
		e.Ergebnis = "ok"
		g.log.Schreiben(e)
		json200(w, 200, map[string]bool{"ok": true})
	}))
	m.HandleFunc("POST /computer/{vmid}/bildschirm", g.mitAnmeldung(func(w http.ResponseWriter, r *http.Request, a anfrage) {
		vm, status, grund := g.pruefen(r.Context(), a.konto, r.PathValue("vmid"), "VM.Console")
		e := Eintrag{Aktion: "bildschirm", Email: a.konto.Email, Benutzer: a.konto.Benutzer, Peer: a.peer.IP.String(), VMID: vm.VMID}
		if status != 0 {
			e.Ergebnis, e.Grund = "abgewiesen", grund
			g.log.Schreiben(e)
			json200(w, status, map[string]string{"error": grund})
			return
		}
		z, spiceHost, err := g.pve.Spice(r.Context(), vm)
		if err != nil {
			e.Ergebnis, e.Grund = "fehler", err.Error()
			g.log.Schreiben(e)
			text := "Bildschirm nicht verfuegbar"
			if strings.Contains(strings.ToLower(err.Error()), "spice") {
				text = "Dieser Computer hat keine SPICE-Anzeige – Technik: Anzeige auf SPICE stellen"
			}
			json200(w, http.StatusBadGateway, map[string]string{"error": text})
			return
		}
		host, _ := z["host"].(string)
		tls := toInt(z["tls-port"])
		if host == "" || tls == 0 {
			json200(w, http.StatusBadGateway, map[string]string{"error": "Antwort von Proxmox unvollstaendig"})
			return
		}
		// Nur dieses Ziel, nur fuer diesen Peer, nur kurz: siehe spice.go.
		g.mu.Lock()
		// Kein net.JoinHostPort: das setzt um ein Ziel mit Doppelpunkten
		// eckige Klammern, spice-glib schickt es aber ohne.
		g.tickets[host+":"+strconv.Itoa(tls)] = Ticket{Peer: a.peer.IP, SpiceHost: spiceHost, VMID: vm.VMID, Bis: g.jetzt().Add(2 * time.Minute)}
		g.mu.Unlock()
		e.Ergebnis = "ok"
		g.log.Schreiben(e)
		// "proxy" bewusst weggelassen: die App geht ueber den Gateway (Port 3128).
		delete(z, "proxy")
		json200(w, 200, z)
	}))
	m.HandleFunc("POST /abmelden", g.mitAnmeldung(func(w http.ResponseWriter, r *http.Request, a anfrage) {
		// Erst antworten, dann entfernen: ohne Peer kaeme die Antwort nicht
		// mehr durch den Tunnel zurueck (im Test so haengengeblieben).
		json200(w, 200, map[string]bool{"ok": true})
		ip := a.peer.IP
		time.AfterFunc(time.Second, func() { g.PeerEntfernen(ip, "abgemeldet") })
	}))
	return m
}

func toInt(v any) int {
	switch x := v.(type) {
	case float64:
		return int(x)
	case string:
		n, _ := strconv.Atoi(x)
		return n
	}
	return 0
}
