// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"time"
)

// Steuerung: nur fuer die Haupt-API, nur im LAN (GW_STEUER_BIND).
//
// Die Haupt-API ist die oeffentliche Tuer (HTTPS, Ratenbegrenzung); hier
// kommt sie mit ZWEI Ausweisen an:
//   Authorization: Bearer <GW_STEUER_TOKEN>      — die Anfrage kommt von der API
//   X-Rosenweg-Token: <Authentik-Token der Person> — fuer wen
// Der Gateway prueft das Token der Person selbst noch einmal. Ein geleakter
// Steuer-Token allein reicht also nicht, um Peers fuer andere anzulegen.

var geraetRE = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{7,39}$`)

func (g *Gateway) steuerBerechtigt(r *http.Request) bool {
	t := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
	return subtle.ConstantTimeCompare([]byte(t), []byte(g.k.SteuerToken)) == 1
}

func (g *Gateway) steuerKonto(w http.ResponseWriter, r *http.Request) *Konto {
	if !g.steuerBerechtigt(r) {
		json200(w, http.StatusUnauthorized, map[string]string{"error": "unauthorized"})
		return nil
	}
	ctx, cancel := context.WithTimeout(r.Context(), 10*time.Second)
	defer cancel()
	k, err := g.konten.Pruefen(ctx, r.Header.Get("X-Rosenweg-Token"))
	if err != nil {
		status := http.StatusUnauthorized
		if !errors.Is(err, ErrNichtAngemeldet) {
			status = http.StatusServiceUnavailable
		}
		json200(w, status, map[string]string{"error": "Anmeldung abgelaufen"})
		return nil
	}
	return k
}

func (g *Gateway) Steuerung() http.Handler {
	m := http.NewServeMux()
	m.HandleFunc("GET /gesundheit", func(w http.ResponseWriter, r *http.Request) {
		json200(w, 200, map[string]any{"ok": true, "peers": g.Anzahl()})
	})
	m.HandleFunc("POST /peers", func(w http.ResponseWriter, r *http.Request) {
		k := g.steuerKonto(w, r)
		if k == nil {
			return
		}
		var b struct {
			Geraet     string `json:"geraet"`
			Schluessel string `json:"schluessel"`
		}
		if json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&b) != nil || !geraetRE.MatchString(b.Geraet) {
			json200(w, http.StatusBadRequest, map[string]string{"error": "Ungueltige Geraetekennung"})
			return
		}
		roh, err := base64.StdEncoding.DecodeString(b.Schluessel)
		if err != nil || len(roh) != 32 {
			json200(w, http.StatusBadRequest, map[string]string{"error": "Oeffentlicher Schluessel ungueltig"})
			return
		}
		var pub [32]byte
		copy(pub[:], roh)
		p, konfig, err := g.PeerAnlegen(k, b.Geraet, pub)
		e := Eintrag{Aktion: "peer-neu", Email: k.Email, Benutzer: k.Benutzer}
		if err != nil {
			e.Ergebnis, e.Grund = "abgewiesen", err.Error()
			g.log.Schreiben(e)
			json200(w, http.StatusTooManyRequests, map[string]string{"error": err.Error()})
			return
		}
		e.Peer, e.Ergebnis = p.IP.String(), "ok"
		g.log.Schreiben(e)
		json200(w, 200, map[string]string{
			"config": konfig, "adresse": p.IP.String(), "gateway": g.eigen.String(),
			"endpoint_intern": g.k.EndpointIntern,
		})
	})
	m.HandleFunc("DELETE /peers/{geraet}", func(w http.ResponseWriter, r *http.Request) {
		k := g.steuerKonto(w, r)
		if k == nil {
			return
		}
		n := 0
		if ip, ok := g.PeerVonGeraet(k.Email, r.PathValue("geraet")); ok {
			g.PeerEntfernen(ip, "abgemeldet (API)")
			n = 1
		}
		json200(w, 200, map[string]int{"entfernt": n})
	})
	return m
}
