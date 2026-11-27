// SPDX-License-Identifier: GPL-3.0-or-later

package tunnel

import (
	"bufio"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// zentraleSeite spielt die adb-zentrale nach: wireguard-go mit Netzstapel auf
// 10.243.44.1, ein Peer (das Telefon) mit 10.243.44.12/32.
func zentraleSeite(t *testing.T, telefonPub string) (port int, pub string, tnet *netstack.Net, stop func()) {
	t.Helper()
	priv, pub, err := Schluesselpaar()
	if err != nil {
		t.Fatal(err)
	}
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("10.243.44.1")}, nil, 1420)
	if err != nil {
		t.Fatal(err)
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "zentrale: "))
	u, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	port = u.LocalAddr().(*net.UDPAddr).Port
	u.Close()
	hx := func(b64 string) string { b, _ := base64.StdEncoding.DecodeString(b64); return hex.EncodeToString(b) }
	if err := dev.IpcSet(fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=10.243.44.12/32\n",
		hx(priv), port, hx(telefonPub))); err != nil {
		t.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}
	return port, pub, tnet, dev.Close
}

// adbdAttrappe: Echo auf 127.0.0.1, wie adbd fuer diesen Test genuegt.
func adbdAttrappe(t *testing.T) string {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); io.Copy(c, c) }()
		}
	}()
	return ln.Addr().String()
}

func warteArt(t *testing.T, h *Hoerer, art string) Ereignis {
	t.Helper()
	ende := time.Now().Add(10 * time.Second)
	for time.Now().Before(ende) {
		e, ok := h.WarteEreignis(time.Second)
		if ok && e.Art == art {
			return e
		}
	}
	t.Fatalf("kein Ereignis %q", art)
	return Ereignis{}
}

func TestHoerenAdbUndAnzeige(t *testing.T) {
	tPriv, tPub, _ := Schluesselpaar()
	port, zPub, znet, stop := zentraleSeite(t, tPub)
	defer stop()
	adbd := adbdAttrappe(t)

	h, err := HoerenStart(HoerKonfig{PrivateKey: tPriv, PeerPublic: zPub, Endpoint: fmt.Sprintf("127.0.0.1:%d", port),
		Adresse: "10.243.44.12", Gateway: "10.243.44.1", Keepalive: 1, AdbZiel: adbd})
	if err != nil {
		t.Fatal(err)
	}
	defer h.Stop()

	// Anzeige: wer kommt
	a, err := znet.Dial("tcp", "10.243.44.12:7000")
	if err != nil {
		t.Fatal(err)
	}
	fmt.Fprintln(a, `{"person":"Stefan\u0007","zweck":"shell"}`)
	antwort, _ := bufio.NewReader(a).ReadString('\n')
	a.Close()
	if antwort != "ok\n" {
		t.Fatalf("Anzeige: %q", antwort)
	}
	if e := warteArt(t, h, "anzeige"); e.Anzeig == nil || e.Anzeig.Person != "Stefan" {
		t.Fatalf("Anzeige-Ereignis: %+v", e)
	}

	// adb: geht unveraendert an 127.0.0.1 durch
	c, err := znet.Dial("tcp", "10.243.44.12:5555")
	if err != nil {
		t.Fatal(err)
	}
	if e := warteArt(t, h, "auf"); e.Offen != 1 || e.Anzeig == nil {
		t.Fatalf("auf: %+v", e)
	}
	io.WriteString(c, "CNXN host::\n")
	zeile, _ := bufio.NewReader(c).ReadString('\n')
	if zeile != "CNXN host::\n" {
		t.Fatalf("Echo: %q", zeile)
	}
	z, _ := h.Zustand()
	if z.Offen != 1 || !z.Sitzung || z.Anzeige == nil || z.LetzterHandshake == 0 {
		t.Fatalf("Zustand waehrend Sitzung: %+v", z)
	}
	c.Close()
	if e := warteArt(t, h, "zu"); e.Offen != 0 {
		t.Fatalf("zu: %+v", e)
	}
	z, _ = h.Zustand()
	if z.Offen != 0 || !z.Sitzung || z.Verbindungen != 1 {
		t.Fatalf("Zustand im Nachlauf: %+v", z)
	}

	// Kein anderer Port im Tunnel
	if c2, err := znet.DialTCPAddrPort(netip.MustParseAddrPort("10.243.44.12:22")); err == nil {
		c2.Close()
		t.Fatal("Port 22 im Tunnel offen")
	}
}

func TestHoerenNurVonZentrale(t *testing.T) {
	// Zweite Adresse auf der Zentrale-Seite waere eine Fremdquelle; WireGuard
	// laesst sie wegen allowed_ip gar nicht durch. Hier die Pruefung selbst.
	h := &Hoerer{gateway: netip.MustParseAddr("10.243.44.1")}
	fremd := &fakeConn{remote: &net.TCPAddr{IP: net.ParseIP("10.243.44.7"), Port: 4000}}
	gut := &fakeConn{remote: &net.TCPAddr{IP: net.ParseIP("10.243.44.1"), Port: 4000}}
	if h.vonZentrale(fremd) || !h.vonZentrale(gut) {
		t.Fatal("vonZentrale prueft die Quelle nicht richtig")
	}
}

func TestSauber(t *testing.T) {
	if s := sauber("  Anna\nMüller\x00 ", 60); s != "AnnaMüller" {
		t.Fatalf("%q", s)
	}
	if s := sauber(strings.Repeat("x", 100), 10); len(s) != 10 {
		t.Fatalf("%q", s)
	}
}

func TestOeffentlicherSchluessel(t *testing.T) {
	priv, pub, _ := Schluesselpaar()
	p2, err := OeffentlicherSchluessel(priv)
	if err != nil || p2 != pub {
		t.Fatalf("%v %s %s", err, p2, pub)
	}
}

type fakeConn struct {
	net.Conn
	remote net.Addr
}

func (f *fakeConn) RemoteAddr() net.Addr { return f.remote }
