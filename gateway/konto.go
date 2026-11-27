// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"
	"time"
)

// Konto ist die Person hinter einem Token der Rosenweg-Apps.
type Konto struct {
	Email    string
	Name     string
	Sub      string
	Benutzer string   // Proxmox-Benutzer, z. B. joerg.herrmann@authentik
	Gruppen  []string // nur bei rw_app_ (aus /api/auth/me), fuers Protokoll
	Art      string   // "authentik" oder "app" (Karte, QR, Handy)
}

// Konten prueft die Tokens der Rosenweg-Apps — dieselben Regeln wie
// api/routes/app-tunnel.js der Haupt-API. Zwei Arten:
//
//   - Authentik-Token (Rosenweg-Konto im Browser, Kerberos): gueltig laut
//     userinfo UND fuer die Anwendung rosenweg-apps ausgestellt (userinfo
//     allein nimmt Tokens jeder Authentik-Anwendung an). Proxmox-Benutzer aus
//     dem Claim preferred_username.
//   - rw_app_… (Anmeldung mit Rosenweg-Karte, Anmelde-QR oder "Mit dem Handy
//     anmelden"; Website api/routes/app-karte.js): Authentik kennt sie nicht.
//     Die Haupt-API stellt sie aus und beantwortet GET /api/auth/me damit
//     (seit Website #138). Proxmox-Benutzer aus user.username – das ist der
//     Authentik-Benutzername, den die API bei der Anmeldung im Portal aus
//     preferred_username uebernimmt (server.js). Die Rechte kommen wie immer
//     aus Proxmox fuer <username>@authentik.
type Konten struct {
	userinfo string
	apiMe    string
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

// ErrKeinBenutzer: angemeldet, aber ohne Benutzernamen fuer Proxmox (Karten-
// oder QR-Anmeldung einer Person, die nie mit dem Rosenweg-Konto im Portal
// war). Kein 401 – neu anmelden mit der Karte hilft nicht.
var ErrKeinBenutzer = errors.New("kein Benutzer fuer die Computer")

// anmeldeFehler: Status und Text fuer die App (Schnittstelle und Steuerung gleich).
func anmeldeFehler(err error) (int, string) {
	switch {
	case errors.Is(err, ErrKeinBenutzer):
		return http.StatusForbidden, "Mit dieser Anmeldung gibt es keinen Zugang zu den Computern. Bitte einmal mit dem Rosenweg-Konto anmelden."
	case errors.Is(err, ErrNichtAngemeldet):
		return http.StatusUnauthorized, "Anmeldung abgelaufen"
	default:
		return http.StatusServiceUnavailable, "Anmeldung konnte nicht geprueft werden (Anmeldedienst nicht erreichbar)"
	}
}

// Proxmox-Benutzernamen: nur was ein Realm-Benutzer sein kann. Alles andere
// (Schraegstrich, @, Leerzeichen) koennte einen anderen Pfad oder Realm meinen.
var benutzerRE = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`)

func NeueKonten(k Konfig) *Konten {
	return &Konten{
		userinfo: k.Userinfo, apiMe: k.APIMe, clientID: k.ClientID, claim: k.BenutzerClaim, realm: k.PVERealm,
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

// Praefix der App-Anmeldungen ohne Authentik (Website api/lib/appkarte.js).
const appPraefix = "rw_app_"

// Wie lange ein gepruefter Ausweis gemerkt wird. rw_app_ kuerzer: Karte
// entzogen oder Sitzung widerrufen soll schnell greifen (der Zugang selbst
// lebt 15 Minuten).
const (
	merkenAuthentik = time.Minute
	merkenApp       = 30 * time.Second
)

// Pruefen liefert das Konto oder ErrNichtAngemeldet. Ergebnis kurz gemerkt:
// Liste, Bildschirm und Einschalten fragen sonst dreimal nach.
func (ks *Konten) Pruefen(ctx context.Context, token string) (*Konto, error) {
	if token == "" || len(token) > 4096 {
		return nil, fmt.Errorf("%w: kein Token", ErrNichtAngemeldet)
	}
	app := strings.HasPrefix(token, appPraefix)
	dauer := merkenAuthentik
	if app {
		dauer = merkenApp
	}
	h := sha256.Sum256([]byte(token))
	ks.mu.Lock()
	if g, ok := ks.merker[h]; ok && ks.jetzt().Sub(g.zeit) < dauer {
		ks.mu.Unlock()
		return g.k, nil
	}
	ks.mu.Unlock()

	var k *Konto
	var err error
	if app {
		k, err = ks.appKonto(ctx, token)
	} else {
		k, err = ks.authentikKonto(ctx, token)
	}
	if err != nil {
		return nil, err
	}
	ks.mu.Lock()
	if len(ks.merker) > 10000 {
		ks.merker = map[[32]byte]gemerkt{}
	}
	ks.merker[h] = gemerkt{k, ks.jetzt()}
	ks.mu.Unlock()
	return k, nil
}

// appKonto: rw_app_-Token bei der Haupt-API pruefen (GET /api/auth/me).
// 401/403 = abgelehnt; Netzfehler und 5xx = "nicht pruefbar" (kein
// ErrNichtAngemeldet, damit die App nicht abmeldet, wenn nur die API kurz weg ist).
func (ks *Konten) appKonto(ctx context.Context, token string) (*Konto, error) {
	if len(token) > 100 {
		return nil, fmt.Errorf("%w: App-Token zu lang", ErrNichtAngemeldet)
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ks.apiMe, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	req.Header.Set("Accept", "application/json")
	r, err := ks.http.Do(req)
	if err != nil {
		return nil, fmt.Errorf("Haupt-API nicht erreichbar: %w", err)
	}
	defer r.Body.Close()
	switch {
	case r.StatusCode == http.StatusUnauthorized || r.StatusCode == http.StatusForbidden:
		return nil, fmt.Errorf("%w: Haupt-API /api/auth/me %d", ErrNichtAngemeldet, r.StatusCode)
	case r.StatusCode != http.StatusOK:
		return nil, fmt.Errorf("Haupt-API /api/auth/me %d", r.StatusCode)
	}
	var antwort struct {
		User struct {
			ID       any      `json:"id"`
			Email    string   `json:"email"`
			Name     string   `json:"name"`
			Username string   `json:"username"`
			Groups   []string `json:"groups"`
		} `json:"user"`
	}
	if json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&antwort) != nil {
		return nil, fmt.Errorf("Haupt-API /api/auth/me: Antwort unlesbar")
	}
	u := antwort.User
	email := strings.ToLower(strings.TrimSpace(u.Email))
	if email == "" {
		return nil, fmt.Errorf("%w: keine Mailadresse im Konto", ErrNichtAngemeldet)
	}
	if !benutzerRE.MatchString(u.Username) {
		// Ohne Benutzernamen kein Proxmox-Benutzer: die Person war noch nie mit
		// dem Rosenweg-Konto im Portal (dort uebernimmt die API ihn aus Authentik).
		return nil, fmt.Errorf("%w: kein gueltiger Benutzername (%q)", ErrKeinBenutzer, u.Username)
	}
	return &Konto{
		Email: email, Name: u.Name, Sub: fmt.Sprintf("rosenweg:%v", u.ID),
		Benutzer: u.Username + "@" + ks.realm, Gruppen: u.Groups, Art: "app",
	}, nil
}

// authentikKonto: Authentik-Token ueber userinfo pruefen.
func (ks *Konten) authentikKonto(ctx context.Context, token string) (*Konto, error) {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, ks.userinfo, nil)
	req.Header.Set("Authorization", "Bearer "+token)
	r, err := ks.http.Do(req)
	if err != nil {
		return nil, err // Netzfehler: nicht als "abgelehnt" werten
	}
	defer r.Body.Close()
	if r.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: Authentik userinfo %d", ErrNichtAngemeldet, r.StatusCode)
	}
	var info map[string]any
	if json.NewDecoder(r.Body).Decode(&info) != nil {
		return nil, fmt.Errorf("%w: Authentik userinfo: Antwort unlesbar", ErrNichtAngemeldet)
	}
	// Erst NACHDEM Authentik das Token bestaetigt hat, ist sein Inhalt echt.
	c := claimsLesen(token)
	if c == nil || !(enthaelt(c["aud"], ks.clientID) || enthaelt(c["azp"], ks.clientID)) {
		return nil, fmt.Errorf("%w: Token nicht fuer rosenweg-apps (aud/azp)", ErrNichtAngemeldet)
	}
	email, _ := info["email"].(string)
	email = strings.ToLower(strings.TrimSpace(email))
	// email_verified wird bewusst nicht verlangt (26.11.2026): Authentik meldet
	// fuer alle Rosenweg-Konten false, weil die Verwaltung die Adressen
	// eintraegt. Massgebend fuer Rechte ist der Proxmox-Benutzer aus dem Claim
	// darunter, nicht die Mailadresse.
	if email == "" {
		return nil, fmt.Errorf("%w: keine Mailadresse im Konto", ErrNichtAngemeldet)
	}
	b, _ := info[ks.claim].(string)
	if !benutzerRE.MatchString(b) {
		return nil, fmt.Errorf("%w: Claim %s ungueltig (%q)", ErrNichtAngemeldet, ks.claim, b)
	}
	name, _ := info["name"].(string)
	sub, _ := info["sub"].(string)
	return &Konto{Email: email, Name: name, Sub: sub, Benutzer: b + "@" + ks.realm, Art: "authentik"}, nil
}
