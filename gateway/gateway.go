// SPDX-License-Identifier: GPL-3.0-or-later

// vm-gateway: der einzige Weg der App „Rosenweg Virtuelle Computer“ zu Proxmox.
//
//	App ──WireGuard──► vm-gateway (CT) ──HTTPS──► pve*:8006 (API-Token des Gateways)
//	                                   └─TCP────► pve*:3128 (SPICE, nur eigene Tickets)
//
// Der WireGuard-Teil endet in einem Netzstapel IM PROZESS (wireguard-go +
// gVisor). Es gibt keine Schnittstelle im Container, keine Route, kein
// Weiterleiten: Durch den Tunnel erreicht eine App genau zwei Ports dieses
// Dienstes (80: Schnittstelle, 3128: SPICE) und sonst nichts im Haus. Das ist
// keine Firewall-Regel, die man vergessen kann, sondern die Bauweise.
package main

import (
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Peer: ein Geraet einer Person, solange die App offen ist.
type Peer struct {
	IP       netip.Addr
	Public   [32]byte
	Email    string
	Benutzer string
	Geraet   string
	Angelegt time.Time
}

// Ticket: ein SPICE-Ziel, das der Gateway fuer genau diesen Peer geholt hat.
type Ticket struct {
	Peer      netip.Addr
	SpiceHost string // pveX:3128
	VMID      int
	Bis       time.Time
}

type Gateway struct {
	k      Konfig
	dev    *device.Device
	tnet   *netstack.Net
	eigen  netip.Addr // erste Adresse im Netz, z. B. 10.243.43.1
	public [32]byte

	konten *Konten
	pve    *PVE
	log    *Protokoll
	jetzt  func() time.Time

	mu      sync.Mutex
	peers   map[netip.Addr]*Peer
	tickets map[string]Ticket
	rechte  map[string]rechteMerker
}

type rechteMerker struct {
	privs map[string]bool
	zeit  time.Time
}

func schluesselLaden(pfad string) ([32]byte, error) {
	var k [32]byte
	if b, err := os.ReadFile(pfad); err == nil {
		d, err := base64.StdEncoding.DecodeString(strings.TrimSpace(string(b)))
		if err != nil || len(d) != 32 {
			return k, errors.New("Server-Schluessel unlesbar")
		}
		copy(k[:], d)
		return k, nil
	}
	if _, err := rand.Read(k[:]); err != nil {
		return k, err
	}
	k[0] &= 248
	k[31] = (k[31] & 127) | 64
	if err := os.MkdirAll(filepath.Dir(pfad), 0o700); err != nil {
		return k, err
	}
	return k, os.WriteFile(pfad, []byte(base64.StdEncoding.EncodeToString(k[:])+"\n"), 0o600)
}

func NeuerGateway(k Konfig, konten *Konten, pve *PVE, log *Protokoll) (*Gateway, error) {
	privat, err := schluesselLaden(k.Schluessel)
	if err != nil {
		return nil, err
	}
	pub, err := curve25519.X25519(privat[:], curve25519.Basepoint)
	if err != nil {
		return nil, err
	}
	eigen := k.Netz.Masked().Addr().Next()
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{eigen}, nil, 1420)
	if err != nil {
		return nil, err
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "vm-gateway: "))
	if err := dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\n", hex.EncodeToString(privat[:]), k.WgPort)); err != nil {
		dev.Close()
		return nil, err
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	g := &Gateway{
		k: k, dev: dev, tnet: tnet, eigen: eigen,
		konten: konten, pve: pve, log: log, jetzt: time.Now,
		peers: map[netip.Addr]*Peer{}, tickets: map[string]Ticket{}, rechte: map[string]rechteMerker{},
	}
	copy(g.public[:], pub)
	return g, nil
}

func (g *Gateway) Schliessen() { g.dev.Close() }

// PeerAnlegen ersetzt einen alten Peer desselben Geraets derselben Person und
// legt den neuen an. Gibt die Client-Konfiguration im wg-quick-Format zurueck.
func (g *Gateway) PeerAnlegen(k *Konto, geraet string, public [32]byte) (*Peer, string, error) {
	g.mu.Lock()
	defer g.mu.Unlock()
	anzahl := 0
	for ip, p := range g.peers {
		if p.Email == k.Email && p.Geraet == geraet {
			g.peerEntfernenGesperrt(ip, "ersetzt")
			continue
		}
		if p.Email == k.Email {
			anzahl++
		}
		if p.Public == public {
			return nil, "", errors.New("Schluessel schon vergeben")
		}
	}
	if anzahl >= g.k.MaxJePerson {
		return nil, "", fmt.Errorf("hoechstens %d Geraete gleichzeitig", g.k.MaxJePerson)
	}
	// Erste freie Adresse nach der eigenen; die letzte (Broadcast) bleibt frei.
	var ip netip.Addr
	for c := g.eigen.Next(); g.k.Netz.Contains(c.Next()); c = c.Next() {
		if _, belegt := g.peers[c]; !belegt {
			ip = c
			break
		}
	}
	if !ip.IsValid() {
		return nil, "", errors.New("keine Adresse mehr frei")
	}
	if err := g.dev.IpcSet(fmt.Sprintf("public_key=%s\nreplace_allowed_ips=true\nallowed_ip=%s/32\n",
		hex.EncodeToString(public[:]), ip)); err != nil {
		return nil, "", err
	}
	p := &Peer{IP: ip, Public: public, Email: k.Email, Benutzer: k.Benutzer, Geraet: geraet, Angelegt: g.jetzt()}
	g.peers[ip] = p
	konfig := fmt.Sprintf(`[Interface]
PrivateKey = <wird auf dem Geraet eingesetzt>
Address = %s/32

[Peer]
PublicKey = %s
AllowedIPs = %s/32
Endpoint = %s
PersistentKeepalive = 25
`, ip, base64.StdEncoding.EncodeToString(g.public[:]), g.eigen, g.k.EndpointExtern)
	return p, konfig, nil
}

func (g *Gateway) peerEntfernenGesperrt(ip netip.Addr, grund string) {
	p, ok := g.peers[ip]
	if !ok {
		return
	}
	g.dev.IpcSet(fmt.Sprintf("public_key=%s\nremove=true\n", hex.EncodeToString(p.Public[:])))
	delete(g.peers, ip)
	for z, t := range g.tickets {
		if t.Peer == ip {
			delete(g.tickets, z)
		}
	}
	g.log.Schreiben(Eintrag{Aktion: "peer-weg", Email: p.Email, Peer: ip.String(), Ergebnis: "ok", Grund: grund})
}

func (g *Gateway) PeerEntfernen(ip netip.Addr, grund string) {
	g.mu.Lock()
	defer g.mu.Unlock()
	g.peerEntfernenGesperrt(ip, grund)
}

// PeerVonGeraet: fuer DELETE ueber die Haupt-API (App beendet).
func (g *Gateway) PeerVonGeraet(email, geraet string) (netip.Addr, bool) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for ip, p := range g.peers {
		if p.Email == email && p.Geraet == geraet {
			return ip, true
		}
	}
	return netip.Addr{}, false
}

func (g *Gateway) Peer(ip netip.Addr) *Peer {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.peers[ip]
}

// handshakes liest den letzten Handshake je oeffentlichem Schluessel.
func (g *Gateway) handshakes() map[[32]byte]time.Time {
	m := map[[32]byte]time.Time{}
	text, err := g.dev.IpcGet()
	if err != nil {
		return m
	}
	var aktuell [32]byte
	for _, z := range strings.Split(text, "\n") {
		name, wert, _ := strings.Cut(z, "=")
		switch name {
		case "public_key":
			b, _ := hex.DecodeString(wert)
			copy(aktuell[:], b)
		case "last_handshake_time_sec":
			if s, _ := strconv.ParseInt(wert, 10, 64); s > 0 {
				m[aktuell] = time.Unix(s, 0)
			}
		}
	}
	return m
}

// Aufraeumen entfernt Peers, deren App nicht mehr lebt:
//   - nie ein Handshake binnen GW_OHNE_HANDSHAKE (App kam nie an), oder
//   - letzter Handshake aelter als GW_STILL. Die App schickt alle 25 s ein
//     Lebenszeichen, WireGuard handelt dabei spaetestens alle 2 Minuten neu
//     aus; 5 Minuten Stille heisst: App zu, abgestuerzt oder Geraet weg.
//
// Dazu abgelaufene SPICE-Tickets.
func (g *Gateway) Aufraeumen() {
	hs := g.handshakes()
	jetzt := g.jetzt()
	g.mu.Lock()
	defer g.mu.Unlock()
	for ip, p := range g.peers {
		t, ok := hs[p.Public]
		switch {
		case !ok && jetzt.Sub(p.Angelegt) > g.k.OhneHandshake:
			g.peerEntfernenGesperrt(ip, "kein Handshake")
		case ok && jetzt.Sub(t) > g.k.Still:
			g.peerEntfernenGesperrt(ip, "still")
		}
	}
	for z, t := range g.tickets {
		if jetzt.After(t.Bis) {
			delete(g.tickets, z)
		}
	}
}

func (g *Gateway) Anzahl() int {
	g.mu.Lock()
	defer g.mu.Unlock()
	return len(g.peers)
}
