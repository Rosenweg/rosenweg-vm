// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Konto ist die Person hinter einem Authentik-Token der Rosenweg-Apps.
type Konto struct {
	Email    string
	Name     string
	Sub      string
	Benutzer string // Proxmox-Benutzer, z. B. joerg.herrmann@authentik
}

// Konten prueft Authentik-Tokens — dieselben Regeln wie api/routes/app-tunnel.js
// der Haupt-API: gueltig laut userinfo UND fuer die Anwendung rosenweg-apps
// ausgestellt (userinfo allein nimmt Tokens jeder Authentik-Anwendung an).
type Konten struct {
	userinfo string
	clientID string
	claim    string
	realm    string
	http     *http.Client
	jetzt    func() time.Time

	mu     sync.Mutex
	merker map[[32]byte]gemerkt
}

type gemerkt struct {
	k    *Konto
	zeit time.Time
}

var ErrNichtAngemeldet = errors.New("nicht angemeldet")

// Proxmox-Benutzernamen: nur was ein Realm-Benutzer sein kann. Alles andere
// (Schraegstrich, @, Leerzeichen) koennte einen anderen Pfad oder Realm meinen.
var benutzerRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func NeueKonten(k Konfig) *Konten {
	return &Konten{
		userinfo: k.Userinfo, clientID: k.ClientID, claim: k.BenutzerClaim, realm: k.PVERealm,
		http:   &http.Client{Timeout: 6 * time.Second},
		jetzt:  time.Now,
		merker: map[[32]byte]gemerkt{},
	}
}

func claimsLesen(token string) map[string]any {
	teile := strings.Split(token, ".")
	if len(teile) < 2 {
		return nil
	}
	roh, err := base64.RawURLEncoding.DecodeString(strings.TrimRight(teile[1], "="))
	if err != nil {
		return nil
	}
	var c map[string]any
	if json.Unmarshal(roh, &c) != nil {
		return nil
	}
	return c
}

func enthaelt(v any, s string) bool {
	switch x := v.(type) {
	case string:
		return x == s
	case []any:
		for _, e := range x {
			if e == s {
				return true
			}
		}
	}
	return false
}

// Pruefen liefert das Konto oder ErrNichtAngemeldet. Ergebnis eine Minute
// gemerkt: Liste, Bildschirm und Einschalten fragen sonst Authentik dreimal.
func (ks *Konten) Pruefen(ctx context.Context, token string) (*Konto, error) {
	if token == "" || len(token) > 4096 {
		return nil, ErrNichtAngemeldet
	}
	h := sha256.Sum256([]byte(token))
	ks.mu.Lock()
	if g, ok := ks.merker[h]; ok && ks.jetzt().Sub(g.zeit) < time.Minute {
		ks.mu.Unlock()
		return g.k, nil
	}
	ks.mu.Unlock()

	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ks.userinfo, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	r, err := ks.http.Do(req)
	if err != nil {
		return nil, err // Netzfehler: nicht als "abgelehnt" werten
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		return nil, ErrNichtAngemeldet
	}
	var info map[string]any
	if json.NewDecoder(r.Body).Decode(&info) != nil {
		return nil, ErrNichtAngemeldet
	}
	// Erst NACHDEM Authentik das Token bestaetigt hat, ist sein Inhalt echt.
	c := claimsLesen(token)
	if c == nil || !(enthaelt(c["aud"], ks.clientID) || enthaelt(c["azp"], ks.clientID)) {
		return nil, ErrNichtAngemeldet
	}
	email, _ := info["email"].(string)
	email = strings.ToLower(strings.TrimSpace(email))
	// email_verified wird bewusst nicht verlangt (26.11.2026): Authentik meldet
	// fuer alle Rosenweg-Konten false, weil die Verwaltung die Adressen
	// eintraegt. Massgebend fuer Rechte ist der Proxmox-Benutzer aus dem Claim
	// darunter, nicht die Mailadresse.
	if email == "" {
		return nil, ErrNichtAngemeldet
	}
	b, _ := info[ks.claim].(string)
	if !benutzerRE.MatchString(b) {
		return nil, ErrNichtAngemeldet
	}
	name, _ := info["name"].(string)
	sub, _ := info["sub"].(string)
	k := &Konto{Email: email, Name: name, Sub: sub, Benutzer: b + "@" + ks.realm}

	ks.mu.Lock()
	if len(ks.merker) > 10000 {
		ks.merker = map[[32]byte]gemerkt{}
	}
	ks.merker[h] = gemerkt{k, ks.jetzt()}
	ks.mu.Unlock()
	return k, nil
}
