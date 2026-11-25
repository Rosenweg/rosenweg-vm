// SPDX-License-Identifier: GPL-3.0-or-later

// Package tunnel baut einen WireGuard-Tunnel ganz im Prozess der App auf.
//
// Warum im Prozess und nicht als Systemtunnel: Ein Systemtunnel braucht auf
// jeder Plattform Sonderrechte (Linux root bzw. CAP_NET_ADMIN, Windows einen
// Admin-Dienst mit wintun, macOS/iOS eine Network Extension mit eigener
// Apple-Berechtigung, Android den VPN-Dialog). Die App braucht aber nur zwei
// Ziele im Haus: die Proxmox-API und den SPICE-Proxy. Deshalb laeuft hier
// wireguard-go mit dem gVisor-Netzstapel (netstack) im Benutzerraum: keine
// Schnittstelle, keine Route, kein DNS im System wird angefasst, und der
// Tunnel ist weg, sobald die App zu ist.
//
// Die App spricht den Tunnel ueber einen lokalen HTTP-CONNECT-Proxy an
// (siehe proxy.go). Das koennen sowohl der Dart-HttpClient als auch
// spice-glib von Haus aus.
package tunnel

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"strconv"
	"strings"
)

// Konfig ist das, was die App beim Start uebergibt (als JSON ueber die C-Schnittstelle).
type Konfig struct {
	// WgQuick ist die Konfiguration, wie sie wg-control liefert (INI im
	// wg-quick-Format). Dort steht beim PrivateKey nur ein Platzhalter, weil
	// der private Schluessel das Geraet nie verlaesst.
	WgQuick string `json:"wg_quick"`
	// PrivateKey (Base64) kommt aus dem sicheren Speicher der App.
	PrivateKey string `json:"private_key"`
	// ErlaubteZiele: nur diese host:port duerfen durch den lokalen Proxy.
	// Sonst koennte jedes Programm auf dem Rechner, das den Port findet, den
	// Tunnel der angemeldeten Person als Sprungbrett ins Hausnetz nutzen.
	ErlaubteZiele []string `json:"erlaubte_ziele"`
	// SpiceProxy ist der SPICE-Proxy des Clusters (host:3128). CONNECT-Ziele
	// der Form "pvespiceproxy:…" gehen dorthin weiter (siehe proxy.go).
	SpiceProxy string `json:"spice_proxy"`
	// Hosts: feste Adressen fuer Namen, falls der DNS im Tunnel nicht
	// antwortet. Leer = DNS aus der wg-quick-Konfiguration.
	Hosts map[string]string `json:"hosts"`
}

// wgKonfig ist die ausgewertete wg-quick-Konfiguration.
type wgKonfig struct {
	adressen   []netip.Addr
	dns        []netip.Addr
	privat     []byte
	peerPublic []byte
	psk        []byte
	endpoint   string
	allowedIPs []netip.Prefix
	keepalive  int
}

func schluessel(b64 string) ([]byte, error) {
	k, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil || len(k) != 32 {
		return nil, errors.New("Schluessel ungueltig")
	}
	return k, nil
}

// wgQuickLesen wertet die INI aus. Bewusst nur die Felder, die wg-control
// schreibt; Unbekanntes wird abgelehnt statt still uebergangen, damit eine
// spaetere Aenderung dort hier auffaellt.
func wgQuickLesen(text, privatB64 string) (*wgKonfig, error) {
	k := &wgKonfig{}
	abschnitt := ""
	sc := bufio.NewScanner(strings.NewReader(text))
	for sc.Scan() {
		zeile := strings.TrimSpace(sc.Text())
		if zeile == "" || strings.HasPrefix(zeile, "#") {
			continue
		}
		if strings.HasPrefix(zeile, "[") {
			abschnitt = strings.ToLower(strings.Trim(zeile, "[]"))
			continue
		}
		name, wert, ok := strings.Cut(zeile, "=")
		if !ok {
			return nil, fmt.Errorf("Zeile ohne '=': %q", zeile)
		}
		name = strings.ToLower(strings.TrimSpace(name))
		wert = strings.TrimSpace(wert)
		switch abschnitt + "." + name {
		case "interface.privatekey":
			// Platzhalter von wg-control; der echte kommt separat.
		case "interface.address":
			for _, a := range strings.Split(wert, ",") {
				p, err := netip.ParsePrefix(strings.TrimSpace(a))
				if err != nil {
					return nil, fmt.Errorf("Address: %w", err)
				}
				k.adressen = append(k.adressen, p.Addr())
			}
		case "interface.dns":
			for _, a := range strings.Split(wert, ",") {
				ip, err := netip.ParseAddr(strings.TrimSpace(a))
				if err != nil {
					return nil, fmt.Errorf("DNS: %w", err)
				}
				k.dns = append(k.dns, ip)
			}
		case "interface.mtu", "interface.listenport":
			// Netstack waehlt selbst; Port des Clients ist egal.
		case "peer.publickey":
			b, err := schluessel(wert)
			if err != nil {
				return nil, fmt.Errorf("PublicKey: %w", err)
			}
			k.peerPublic = b
		case "peer.presharedkey":
			b, err := schluessel(wert)
			if err != nil {
				return nil, fmt.Errorf("PresharedKey: %w", err)
			}
			k.psk = b
		case "peer.allowedips":
			for _, a := range strings.Split(wert, ",") {
				p, err := netip.ParsePrefix(strings.TrimSpace(a))
				if err != nil {
					return nil, fmt.Errorf("AllowedIPs: %w", err)
				}
				k.allowedIPs = append(k.allowedIPs, p)
			}
		case "peer.endpoint":
			k.endpoint = wert
		case "peer.persistentkeepalive":
			n, err := strconv.Atoi(wert)
			if err != nil {
				return nil, fmt.Errorf("PersistentKeepalive: %w", err)
			}
			k.keepalive = n
		default:
			return nil, fmt.Errorf("unbekanntes Feld %s.%s", abschnitt, name)
		}
	}
	p, err := schluessel(privatB64)
	if err != nil {
		return nil, fmt.Errorf("privater Schluessel: %w", err)
	}
	k.privat = p
	if len(k.adressen) == 0 || k.peerPublic == nil || k.endpoint == "" || len(k.allowedIPs) == 0 {
		return nil, errors.New("Konfiguration unvollstaendig (Address, PublicKey, Endpoint, AllowedIPs)")
	}
	return k, nil
}

// uapi baut die Einstellung fuer wireguard-go (Schluessel dort in Hex).
func (k *wgKonfig) uapi(endpointIP string) string {
	var b strings.Builder
	fmt.Fprintf(&b, "private_key=%s\n", hex.EncodeToString(k.privat))
	fmt.Fprintf(&b, "public_key=%s\n", hex.EncodeToString(k.peerPublic))
	if k.psk != nil {
		fmt.Fprintf(&b, "preshared_key=%s\n", hex.EncodeToString(k.psk))
	}
	fmt.Fprintf(&b, "endpoint=%s\n", endpointIP)
	if k.keepalive > 0 {
		fmt.Fprintf(&b, "persistent_keepalive_interval=%d\n", k.keepalive)
	}
	for _, p := range k.allowedIPs {
		fmt.Fprintf(&b, "allowed_ip=%s\n", p.String())
	}
	return b.String()
}
