// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"sync"
	"time"
)

// PVE spricht mit Proxmox ueber das API-Token des Gateways.
//
// Das Token darf mehr als jede einzelne Person (es sieht alle Computer). Darum
// geht keine Anfrage einer Person ungeprueft durch: Rechte() fragt Proxmox,
// was der Proxmox-Benutzer DIESER Person an genau diesem Pfad darf, und erst
// dann handelt der Gateway. Rechte des Tokens (Rolle "VMGateway"):
// VM.Audit, VM.Console, VM.PowerMgmt auf /vms und Sys.Audit auf /access —
// kein VM.Config, kein Datastore, kein Sys.Modify.
type PVE struct {
	hosts     []string
	spicePort int
	token     string
	http      *http.Client

	mu    sync.Mutex
	aktiv int // zuletzt erreichbarer Knoten
}

type VM struct {
	VMID    int    `json:"vmid"`
	Name    string `json:"name"`
	Knoten  string `json:"node"`
	Status  string `json:"status"`
	Pool    string `json:"pool"`
	Typ     string `json:"type"`
	Vorlage int    `json:"template"`
}

type PVEFehler struct {
	Status int
	Text   string
}

func (e *PVEFehler) Error() string { return fmt.Sprintf("Proxmox %d: %s", e.Status, e.Text) }

func NeuesPVE(k Konfig, tlsKonfig *tls.Config) (*PVE, error) {
	if tlsKonfig == nil {
		tlsKonfig = &tls.Config{MinVersion: tls.VersionTLS12}
		if k.PVECA != "" {
			pem, err := os.ReadFile(k.PVECA)
			if err != nil {
				return nil, err
			}
			pool := x509.NewCertPool()
			if !pool.AppendCertsFromPEM(pem) {
				return nil, errors.New("PVE_CA enthaelt kein Zertifikat")
			}
			tlsKonfig.RootCAs = pool
		}
	}
	return &PVE{
		hosts: k.PVEHosts, spicePort: k.PVESpicePort, token: k.PVEToken,
		http: &http.Client{Timeout: 20 * time.Second, Transport: &http.Transport{TLSClientConfig: tlsKonfig}},
	}, nil
}

func mitPort(h string) string {
	if _, _, err := net.SplitHostPort(h); err == nil {
		return h
	}
	return net.JoinHostPort(h, "8006")
}

// ruf fragt die Knoten der Reihe nach, beginnend beim zuletzt erreichbaren.
// Liefert auch, welcher Knoten geantwortet hat (fuer den SPICE-Proxy).
func (p *PVE) ruf(ctx context.Context, methode, pfad string, form url.Values) (json.RawMessage, string, error) {
	p.mu.Lock()
	start := p.aktiv
	p.mu.Unlock()
	var letzter error
	for i := range p.hosts {
		n := (start + i) % len(p.hosts)
		host := p.hosts[n]
		var body io.Reader
		if form != nil {
			body = strings.NewReader(form.Encode())
		}
		req, err := http.NewRequestWithContext(ctx, methode, "https://"+mitPort(host)+"/api2/json"+pfad, body)
		if err != nil {
			return nil, "", err
		}
		req.Header.Set("Authorization", "PVEAPIToken="+p.token)
		if form != nil {
			req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
		}
		r, err := p.http.Do(req)
		if err != nil {
			letzter = err
			continue // naechster Knoten
		}
		text, _ := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		r.Body.Close()
		p.mu.Lock()
		p.aktiv = n
		p.mu.Unlock()
		if r.StatusCode != http.StatusOK {
			return nil, host, &PVEFehler{r.StatusCode, strings.TrimSpace(string(text))}
		}
		var h struct {
			Data json.RawMessage `json:"data"`
		}
		if err := json.Unmarshal(text, &h); err != nil {
			return nil, host, err
		}
		return h.Data, host, nil
	}
	return nil, "", fmt.Errorf("kein Proxmox-Knoten erreichbar: %v", letzter)
}

// Computer: alle virtuellen Maschinen (keine Container, keine Vorlagen).
func (p *PVE) Computer(ctx context.Context) ([]VM, error) {
	d, _, err := p.ruf(ctx, http.MethodGet, "/cluster/resources?type=vm", nil)
	if err != nil {
		return nil, err
	}
	var alle []VM
	if err := json.Unmarshal(d, &alle); err != nil {
		return nil, err
	}
	var vms []VM
	for _, v := range alle {
		if v.Typ == "qemu" && v.Vorlage != 1 {
			vms = append(vms, v)
		}
	}
	return vms, nil
}

// BenutzerAktiv: gibt es den Proxmox-Benutzer, ist er an und nicht abgelaufen?
// Ein in Proxmox gesperrter Benutzer bekommt auch ueber den Gateway nichts.
func (p *PVE) BenutzerAktiv(ctx context.Context, benutzer string) (bool, error) {
	d, _, err := p.ruf(ctx, http.MethodGet, "/access/users/"+url.PathEscape(benutzer), nil)
	if err != nil {
		// Unbekannter Benutzer: Proxmox antwortet mit 500 "no such user"
		// (oder 4xx). Das heisst "keine Rechte", nicht "Gateway kaputt".
		var pf *PVEFehler
		if errors.As(err, &pf) && (pf.Status < 500 || strings.Contains(strings.ToLower(pf.Text), "no such user")) {
			return false, nil
		}
		return false, err
	}
	var u struct {
		Enable json.Number `json:"enable"`
		Expire json.Number `json:"expire"`
	}
	if err := json.Unmarshal(d, &u); err != nil {
		return false, err
	}
	if u.Enable.String() == "0" {
		return false, nil
	}
	if e, _ := strconv.ParseInt(u.Expire.String(), 10, 64); e > 0 && time.Now().Unix() > e {
		return false, nil
	}
	return true, nil
}

// Rechte: was darf benutzer an pfad (wirksam, mit Vererbung und Gruppen).
// Braucht Sys.Audit auf /access fuer das Token.
func (p *PVE) Rechte(ctx context.Context, benutzer, pfad string) (map[string]bool, error) {
	q := url.Values{"userid": {benutzer}, "path": {pfad}}
	d, _, err := p.ruf(ctx, http.MethodGet, "/access/permissions?"+q.Encode(), nil)
	if err != nil {
		return nil, err
	}
	var m map[string]map[string]json.Number
	if err := json.Unmarshal(d, &m); err != nil {
		return nil, err
	}
	r := map[string]bool{}
	// Nur genau dieser Pfad zaehlt; Proxmox liefert dort schon das Wirksame.
	for priv := range m[pfad] {
		r[priv] = true
	}
	return r, nil
}

// Spice holt ein SPICE-Ticket. proxy = der antwortende Knoten; dessen
// spiceproxy reicht zum Knoten der Maschine weiter.
func (p *PVE) Spice(ctx context.Context, vm VM) (map[string]any, string, error) {
	p.mu.Lock()
	host := p.hosts[p.aktiv]
	p.mu.Unlock()
	h, _, _ := net.SplitHostPort(mitPort(host))
	d, antwortete, err := p.ruf(ctx, http.MethodPost,
		fmt.Sprintf("/nodes/%s/qemu/%d/spiceproxy", url.PathEscape(vm.Knoten), vm.VMID), url.Values{"proxy": {h}})
	if err != nil {
		return nil, "", err
	}
	var z map[string]any
	if err := json.Unmarshal(d, &z); err != nil {
		return nil, "", err
	}
	// Antwortete ein anderer Knoten als gedacht, gilt dessen Proxy.
	ah, _, _ := net.SplitHostPort(mitPort(antwortete))
	return z, net.JoinHostPort(ah, strconv.Itoa(p.spicePort)), nil
}

func (p *PVE) Starten(ctx context.Context, vm VM) error {
	_, _, err := p.ruf(ctx, http.MethodPost,
		fmt.Sprintf("/nodes/%s/qemu/%d/status/start", url.PathEscape(vm.Knoten), vm.VMID), url.Values{})
	return err
}
