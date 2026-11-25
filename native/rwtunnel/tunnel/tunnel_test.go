package tunnel

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/netip"
	"strings"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// hausSeite spielt wg-control samt Hausnetz nach: ein zweites wireguard-go
// mit eigenem Netzstapel auf 192.168.2.1, dahinter eine "Proxmox-API" auf
// :8006 und ein "SPICE-Proxy" auf :3128. Kein Netz ausserhalb von 127.0.0.1.
func hausSeite(t *testing.T, clientPub string) (port int, serverPub string, stop func()) {
	t.Helper()
	priv, pub, err := Schluesselpaar()
	if err != nil {
		t.Fatal(err)
	}
	tdev, tnet, err := netstack.CreateNetTUN([]netip.Addr{netip.MustParseAddr("192.168.2.1")}, nil, 1420)
	if err != nil {
		t.Fatal(err)
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "haus: "))
	// Freien UDP-Port suchen.
	u, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	port = u.LocalAddr().(*net.UDPAddr).Port
	u.Close()
	hx := func(b64 string) string { b, _ := base64.StdEncoding.DecodeString(b64); return hex.EncodeToString(b) }
	cfg := fmt.Sprintf("private_key=%s\nlisten_port=%d\npublic_key=%s\nallowed_ip=192.168.2.37/32\n", hx(priv), port, hx(clientPub))
	if err := dev.IpcSet(cfg); err != nil {
		t.Fatal(err)
	}
	if err := dev.Up(); err != nil {
		t.Fatal(err)
	}

	api, err := tnet.ListenTCP(&net.TCPAddr{IP: net.ParseIP("192.168.2.1"), Port: 8006})
	if err != nil {
		t.Fatal(err)
	}
	go http.Serve(api, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		io.WriteString(w, "proxmox:"+r.URL.Path)
	}))

	spice, err := tnet.ListenTCP(&net.TCPAddr{IP: net.ParseIP("192.168.2.1"), Port: 3128})
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		for {
			c, err := spice.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				zeile, _ := br.ReadString('\n')
				// Erwartet: genau eine CONNECT-Zeile, ohne lokales Geheimnis.
				for {
					l, err := br.ReadString('\n')
					if err != nil || l == "\r\n" {
						break
					}
					if strings.HasPrefix(strings.ToLower(l), "proxy-authorization") {
						io.WriteString(c, "HTTP/1.0 500 Geheimnis durchgereicht\r\n\r\n")
						return
					}
				}
				if !strings.HasPrefix(zeile, "CONNECT pvespiceproxy:") {
					io.WriteString(c, "HTTP/1.0 400 Bad\r\n\r\n")
					return
				}
				io.WriteString(c, "HTTP/1.0 200 OK\r\n\r\n")
				io.Copy(c, br) // Echo statt SPICE
			}(c)
		}
	}()
	return port, pub, func() { api.Close(); spice.Close(); dev.Close() }
}

func connect(t *testing.T, port int, ziel, geheimnis string) (net.Conn, *bufio.Reader, string) {
	t.Helper()
	c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", port))
	if err != nil {
		t.Fatal(err)
	}
	auth := ""
	if geheimnis != "" {
		auth = "Proxy-Authorization: Basic " + base64.StdEncoding.EncodeToString([]byte("rw:"+geheimnis)) + "\r\n"
	}
	fmt.Fprintf(c, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n%s\r\n", ziel, ziel, auth)
	br := bufio.NewReader(c)
	c.SetReadDeadline(time.Now().Add(10 * time.Second))
	status, _ := br.ReadString('\n')
	for {
		l, err := br.ReadString('\n')
		if err != nil || l == "\r\n" {
			break
		}
	}
	return c, br, strings.TrimSpace(status)
}

func TestTunnelUndProxy(t *testing.T) {
	cpriv, cpub, err := Schluesselpaar()
	if err != nil {
		t.Fatal(err)
	}
	port, spub, stop := hausSeite(t, cpub)
	defer stop()

	// So sieht die Konfiguration von wg-control aus (renderClientConf).
	wgq := fmt.Sprintf(`[Interface]
PrivateKey = <wird auf dem Geraet eingesetzt>
Address = 192.168.2.37/32
DNS = 192.168.2.1

[Peer]
PublicKey = %s
AllowedIPs = 100.64.0.0/16, 192.168.2.0/24
Endpoint = 127.0.0.1:%d
PersistentKeepalive = 25
`, spub, port)

	tun, err := Start(Konfig{
		WgQuick:       wgq,
		PrivateKey:    cpriv,
		ErlaubteZiele: []string{"pve1.rosenweg4303.ch:8006"},
		SpiceProxy:    "pve1.rosenweg4303.ch:3128",
		Hosts:         map[string]string{"pve1.rosenweg4303.ch": "192.168.2.1"},
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tun.Stop()

	// Ohne Geheimnis: 407.
	c, _, st := connect(t, tun.ProxyPort(), "pve1.rosenweg4303.ch:8006", "")
	c.Close()
	if !strings.Contains(st, "407") {
		t.Fatalf("ohne Geheimnis: %s", st)
	}
	// Nicht freigegebenes Ziel: 403.
	c, _, st = connect(t, tun.ProxyPort(), "100.64.2.1:22", tun.ProxyGeheimnis())
	c.Close()
	if !strings.Contains(st, "403") {
		t.Fatalf("fremdes Ziel: %s", st)
	}

	// API durch den Tunnel.
	c, br, st := connect(t, tun.ProxyPort(), "pve1.rosenweg4303.ch:8006", tun.ProxyGeheimnis())
	if !strings.Contains(st, "200") {
		t.Fatalf("API: %s", st)
	}
	fmt.Fprintf(c, "GET /api2/json/version HTTP/1.0\r\nHost: pve1\r\n\r\n")
	antwort, _ := io.ReadAll(br)
	c.Close()
	if !strings.Contains(string(antwort), "proxmox:/api2/json/version") {
		t.Fatalf("API-Antwort: %q", antwort)
	}

	// SPICE: CONNECT pvespiceproxy:… wird an :3128 weitergereicht.
	c, br, st = connect(t, tun.ProxyPort(), "pvespiceproxy:6a2b:107:pve1:61000", tun.ProxyGeheimnis())
	if !strings.Contains(st, "200") {
		t.Fatalf("SPICE: %s", st)
	}
	io.WriteString(c, "REDQ")
	buf := make([]byte, 4)
	if _, err := io.ReadFull(br, buf); err != nil || string(buf) != "REDQ" {
		t.Fatalf("SPICE-Echo: %q %v", buf, err)
	}
	c.Close()

	z, err := tun.Zustand()
	if err != nil || z.LetzterHandshake == 0 || z.Empfangen == 0 {
		t.Fatalf("Zustand: %+v %v", z, err)
	}
}

func TestWgQuickUnbekanntesFeld(t *testing.T) {
	_, err := wgQuickLesen("[Interface]\nPostUp = rm -rf /\n", "")
	if err == nil {
		t.Fatal("PostUp haette abgelehnt werden muessen")
	}
}

func TestProxySchliesst(t *testing.T) {
	p, err := NeuerProxy(ProxyKonfig{Waehlen: func(ctx context.Context, a string) (net.Conn, error) { return nil, fmt.Errorf("nein") }})
	if err != nil {
		t.Fatal(err)
	}
	p.Close()
}
