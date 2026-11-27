// SPDX-License-Identifier: GPL-3.0-or-later

package tunnel

// Hoermodus: die Telefonseite der Fernwartung (geteilte Rosenweg-Telefone).
//
// Anders als Start (die App waehlt sich ins Haus ein) wartet der Tunnel hier
// auf die Zentrale: Rosenweg Geraet oeffnet ihn dauerhaft zur adb-zentrale,
// und im eigenen Netzstapel hoeren genau zwei Ports, beide nur fuer die
// Adresse der Zentrale im Tunnel:
//
//	<adresse>:5555  ->  127.0.0.1:5555 (adbd des Telefons, unveraendert durchgereicht)
//	<adresse>:7000  Anzeige: die Zentrale meldet, wer die Sitzung oeffnet und wozu
//
// Sonst nichts: keine Route, kein Weiterleiten ins WLAN, kein Waehlen nach
// aussen. Das ist Bauweise wie beim vm-gateway, keine Firewall-Regel.
//
// Weil jede adb-Verbindung in diesem Netzstapel ankommt, sieht das Telefon
// selbst, wann Technik verbunden ist (Ereignisse "auf"/"zu"). Daran haengt
// das Band "Fernwartung aktiv". Die Anzeige auf :7000 liefert nur den Namen;
// fehlt sie, zeigt das Telefon das Band trotzdem ("unbekannt").

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// HoerKonfig: was Rosenweg Geraet beim Start uebergibt (JSON).
type HoerKonfig struct {
	PrivateKey string `json:"private_key"` // Base64, entsteht auf dem Telefon (Schluesselpaar)
	PeerPublic string `json:"peer_public"` // Base64, Schluessel der adb-zentrale
	Endpoint   string `json:"endpoint"`    // host:port der Zentrale (UDP)
	Adresse    string `json:"adresse"`     // eigene Adresse im Tunnel, z. B. 10.243.44.12
	Gateway    string `json:"gateway"`     // Adresse der Zentrale im Tunnel, z. B. 10.243.44.1
	Keepalive  int    `json:"keepalive"`   // Sekunden, 0 = 25
	// AdbZiel: wohin :5555 im Tunnel geht. Leer = 127.0.0.1:5555. Nur fuer
	// Tests anders; das Telefon setzt es nie.
	AdbZiel string `json:"adb_ziel,omitempty"`
}

const (
	AdbPort     = 5555
	AnzeigePort = 7000
	// Nachlauf: so lange gilt eine Sitzung nach der letzten Verbindung noch
	// als offen (adb verbindet sich fuer manche Befehle neu).
	Nachlauf = 10 * time.Second
)

// Anzeige: wer gerade verbunden ist, laut Zentrale.
type Anzeige struct {
	Person string `json:"person"`
	Zweck  string `json:"zweck"`
	Seit   int64  `json:"seit"` // Unix-Sekunden der Meldung
}

// Ereignis: fuer das Band. Art "auf", "zu" oder "anzeige".
type Ereignis struct {
	Art    string   `json:"art"`
	Offen  int      `json:"offen"` // offene adb-Verbindungen danach
	Zeit   int64    `json:"zeit"`
	Anzeig *Anzeige `json:"anzeige,omitempty"`
}

// HoerZustand: was Geraet anzeigt und an die Anlage melden kann.
type HoerZustand struct {
	LetzterHandshake int64    `json:"letzter_handshake"`
	Empfangen        uint64   `json:"empfangen"`
	Gesendet         uint64   `json:"gesendet"`
	Offen            int      `json:"offen"`        // offene adb-Verbindungen
	Verbindungen     uint64   `json:"verbindungen"` // seit dem Start
	LetzteZu         int64    `json:"letzte_zu"`    // Unix-Sekunden, 0 = nie
	Sitzung          bool     `json:"sitzung"`      // offen oder im Nachlauf
	Anzeige          *Anzeige `json:"anzeige,omitempty"`
	Abgewiesen       uint64   `json:"abgewiesen"` // Verbindungen nicht von der Zentrale
}

// Hoerer ist ein laufender Tunnel im Hoermodus.
type Hoerer struct {
	k       HoerKonfig
	peer    []byte
	eigen   netip.Addr
	gateway netip.Addr
	dev     *device.Device
	tnet    *netstack.Net
	lnAdb   net.Listener
	lnAnz   net.Listener
	adbZiel string

	mu         sync.Mutex
	offen      map[net.Conn]struct{}
	anzeige    *Anzeige
	letzteZu   time.Time
	ereignisse chan Ereignis
	zu         chan struct{}
	once       sync.Once
	wg         sync.WaitGroup

	verbindungen atomic.Uint64
	abgewiesen   atomic.Uint64
}

// HoerenStart baut den Tunnel auf und oeffnet die beiden Ports.
func HoerenStart(k HoerKonfig) (*Hoerer, error) {
	priv, err := schluessel(k.PrivateKey)
	if err != nil {
		return nil, fmt.Errorf("privater Schluessel: %w", err)
	}
	peer, err := schluessel(k.PeerPublic)
	if err != nil {
		return nil, fmt.Errorf("Schluessel der Zentrale: %w", err)
	}
	eigen, err := netip.ParseAddr(k.Adresse)
	if err != nil || !eigen.Is4() {
		return nil, fmt.Errorf("Adresse %q ungueltig", k.Adresse)
	}
	gw, err := netip.ParseAddr(k.Gateway)
	if err != nil || !gw.Is4() || gw == eigen {
		return nil, fmt.Errorf("Gateway %q ungueltig", k.Gateway)
	}
	ep, err := endpointAufloesen(k.Endpoint)
	if err != nil {
		return nil, err
	}
	if k.Keepalive <= 0 {
		k.Keepalive = 25
	}
	ziel := k.AdbZiel
	if ziel == "" {
		ziel = net.JoinHostPort("127.0.0.1", strconv.Itoa(AdbPort))
	}
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{eigen}, nil, 1420)
	if err != nil {
		return nil, fmt.Errorf("Netzstapel: %w", err)
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "rwtunnel-hoeren: "))
	// allowed_ip nur die Zentrale: Pakete anderer Absender verwirft WireGuard
	// schon vor dem Netzstapel (cryptokey routing).
	cfg := fmt.Sprintf("private_key=%s\npublic_key=%s\nendpoint=%s\npersistent_keepalive_interval=%d\nallowed_ip=%s/32\n",
		hex.EncodeToString(priv), hex.EncodeToString(peer), ep, k.Keepalive, gw)
	if err := dev.IpcSet(cfg); err != nil {
		dev.Close()
		return nil, fmt.Errorf("WireGuard-Einstellung: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	h := &Hoerer{k: k, peer: peer, eigen: eigen, gateway: gw, dev: dev, tnet: tnet, adbZiel: ziel,
		offen: map[net.Conn]struct{}{}, ereignisse: make(chan Ereignis, 64), zu: make(chan struct{})}
	h.lnAdb, err = tnet.ListenTCP(&net.TCPAddr{IP: net.IP(eigen.AsSlice()), Port: AdbPort})
	if err == nil {
		h.lnAnz, err = tnet.ListenTCP(&net.TCPAddr{IP: net.IP(eigen.AsSlice()), Port: AnzeigePort})
	}
	if err != nil {
		h.Stop()
		return nil, err
	}
	h.wg.Add(2)
	go h.annehmen(h.lnAdb, h.adb)
	go h.annehmen(h.lnAnz, h.anzeigeLesen)
	// Gleich einen Handshake anstossen, statt auf den ersten Keepalive zu warten.
	h.Anstossen()
	return h, nil
}

func (h *Hoerer) vonZentrale(c net.Conn) bool {
	a, ok := c.RemoteAddr().(*net.TCPAddr)
	if !ok {
		return false
	}
	ip, ok := netip.AddrFromSlice(a.IP)
	return ok && ip.Unmap() == h.gateway
}

func (h *Hoerer) annehmen(ln net.Listener, bedienen func(net.Conn)) {
	defer h.wg.Done()
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		if !h.vonZentrale(c) {
			h.abgewiesen.Add(1)
			c.Close()
			continue
		}
		h.wg.Add(1)
		go func() {
			defer h.wg.Done()
			bedienen(c)
		}()
	}
}

func (h *Hoerer) melden(e Ereignis) {
	e.Zeit = time.Now().Unix()
	select {
	case h.ereignisse <- e:
	default:
		// Niemand liest (Geraet haengt): aeltestes verwerfen, neuestes behalten.
		select {
		case <-h.ereignisse:
		default:
		}
		select {
		case h.ereignisse <- e:
		default:
		}
	}
}

func (h *Hoerer) adb(c net.Conn) {
	defer c.Close()
	ziel, err := net.DialTimeout("tcp", h.adbZiel, 5*time.Second)
	if err != nil {
		return
	}
	defer ziel.Close()
	h.verbindungen.Add(1)
	h.mu.Lock()
	h.offen[c] = struct{}{}
	n := len(h.offen)
	anz := h.anzeige
	h.mu.Unlock()
	h.melden(Ereignis{Art: "auf", Offen: n, Anzeig: anz})

	fertig := make(chan struct{}, 2)
	go func() { io.Copy(ziel, c); halbZu(ziel); fertig <- struct{}{} }()
	go func() { io.Copy(c, ziel); halbZu(c); fertig <- struct{}{} }()
	select {
	case <-fertig:
		select {
		case <-fertig:
		case <-time.After(5 * time.Second):
		}
	case <-h.zu:
	}
	c.Close()
	ziel.Close()

	h.mu.Lock()
	delete(h.offen, c)
	n = len(h.offen)
	h.letzteZu = time.Now()
	h.mu.Unlock()
	h.melden(Ereignis{Art: "zu", Offen: n})
}

func halbZu(c net.Conn) {
	if cw, ok := c.(interface{ CloseWrite() error }); ok {
		cw.CloseWrite()
	}
}

// anzeigeLesen: eine JSON-Zeile {"person":..,"zweck":..}, Antwort "ok".
// Kurz und streng: hoechstens 1 KB, 5 s, nur druckbare Zeichen.
func (h *Hoerer) anzeigeLesen(c net.Conn) {
	defer c.Close()
	c.SetDeadline(time.Now().Add(5 * time.Second))
	zeile, err := bufio.NewReader(io.LimitReader(c, 1024)).ReadString('\n')
	if err != nil {
		return
	}
	var a Anzeige
	if json.Unmarshal([]byte(zeile), &a) != nil {
		io.WriteString(c, "fehler\n")
		return
	}
	a.Person, a.Zweck = sauber(a.Person, 60), sauber(a.Zweck, 40)
	a.Seit = time.Now().Unix()
	h.mu.Lock()
	h.anzeige = &a
	h.mu.Unlock()
	h.melden(Ereignis{Art: "anzeige", Offen: h.anzahlOffen(), Anzeig: &a})
	io.WriteString(c, "ok\n")
}

func sauber(s string, n int) string {
	var b strings.Builder
	for _, r := range s {
		if r >= 0x20 && r != 0x7f && !(r >= 0x80 && r < 0xa0) {
			b.WriteRune(r)
		}
	}
	t := strings.TrimSpace(b.String())
	if r := []rune(t); len(r) > n {
		t = string(r[:n])
	}
	return t
}

func (h *Hoerer) anzahlOffen() int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.offen)
}

// WarteEreignis blockiert bis zum naechsten Ereignis oder bis zum Ablauf
// (dann ok=false). Fuer einen eigenen Faden in Geraet: kein Abfragen im Takt.
func (h *Hoerer) WarteEreignis(warte time.Duration) (Ereignis, bool) {
	t := time.NewTimer(warte)
	defer t.Stop()
	select {
	case e := <-h.ereignisse:
		return e, true
	case <-t.C:
		return Ereignis{}, false
	case <-h.zu:
		return Ereignis{Art: "stop"}, true
	}
}

// Anstossen schickt ein Paket durch den Tunnel. WireGuard handelt dabei
// einen Handshake aus, falls keiner mehr gilt (nach Ruhezustand, Netzwechsel).
// Die Zentrale verwirft das Paket (Port 9, discard).
func (h *Hoerer) Anstossen() {
	u, err := h.tnet.DialUDPAddrPort(netip.AddrPort{}, netip.AddrPortFrom(h.gateway, 9))
	if err != nil {
		return
	}
	u.Write([]byte{0})
	u.Close()
}

// NetzWechsel: nach jedem Wechsel des WLANs (anderes VLAN, anderer
// Zugangspunkt) den UDP-Socket neu binden und sofort anstossen.
func (h *Hoerer) NetzWechsel() error {
	err := h.dev.BindUpdate()
	h.Anstossen()
	return err
}

// EndpunktSetzen wechselt den Endpunkt der Zentrale (Roaming, intern/extern).
func (h *Hoerer) EndpunktSetzen(ep string) error {
	ip, err := endpointAufloesen(ep)
	if err != nil {
		return err
	}
	err = h.dev.IpcSet(fmt.Sprintf("public_key=%x\nupdate_only=true\nendpoint=%s\n", h.peer, ip))
	h.Anstossen()
	return err
}

// KeepaliveSetzen: kuerzer bei Bildschirm an, laenger im Ruhezustand.
func (h *Hoerer) KeepaliveSetzen(sek int) error {
	if sek < 0 || sek > 3600 {
		return errors.New("Keepalive 0..3600 s")
	}
	return h.dev.IpcSet(fmt.Sprintf("public_key=%x\nupdate_only=true\npersistent_keepalive_interval=%d\n", h.peer, sek))
}

// Zustand: Handshake, Zaehler, offene Verbindungen, letzte Anzeige.
func (h *Hoerer) Zustand() (HoerZustand, error) {
	var z HoerZustand
	text, err := h.dev.IpcGet()
	if err != nil {
		return z, err
	}
	for _, zeile := range strings.Split(text, "\n") {
		name, wert, ok := strings.Cut(zeile, "=")
		if !ok {
			continue
		}
		switch name {
		case "last_handshake_time_sec":
			z.LetzterHandshake, _ = strconv.ParseInt(wert, 10, 64)
		case "rx_bytes":
			z.Empfangen, _ = strconv.ParseUint(wert, 10, 64)
		case "tx_bytes":
			z.Gesendet, _ = strconv.ParseUint(wert, 10, 64)
		}
	}
	h.mu.Lock()
	z.Offen = len(h.offen)
	if !h.letzteZu.IsZero() {
		z.LetzteZu = h.letzteZu.Unix()
	}
	z.Sitzung = z.Offen > 0 || (!h.letzteZu.IsZero() && time.Since(h.letzteZu) < Nachlauf)
	if h.anzeige != nil && z.Sitzung {
		a := *h.anzeige
		z.Anzeige = &a
	}
	h.mu.Unlock()
	z.Verbindungen = h.verbindungen.Load()
	z.Abgewiesen = h.abgewiesen.Load()
	return z, nil
}

// Stop schliesst Ports, offene Verbindungen und den Tunnel.
func (h *Hoerer) Stop() {
	h.once.Do(func() {
		close(h.zu)
		if h.lnAdb != nil {
			h.lnAdb.Close()
		}
		if h.lnAnz != nil {
			h.lnAnz.Close()
		}
		h.mu.Lock()
		for c := range h.offen {
			c.Close()
		}
		h.mu.Unlock()
		h.wg.Wait()
		h.dev.Close()
	})
}

// OeffentlicherSchluessel leitet aus dem privaten den oeffentlichen ab (Base64).
// Geraet braucht ihn, wenn es nach einem Update nur noch den privaten hat.
func OeffentlicherSchluessel(privatB64 string) (string, error) {
	k, err := schluessel(privatB64)
	if err != nil {
		return "", err
	}
	pub, err := x25519Basis(k)
	if err != nil {
		return "", err
	}
	return base64.StdEncoding.EncodeToString(pub), nil
}

func x25519Basis(k []byte) ([]byte, error) { return curve25519.X25519(k, curve25519.Basepoint) }
