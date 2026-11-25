package tunnel

import (
	"context"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"net/netip"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/curve25519"
	"golang.zx2c4.com/wireguard/conn"
	"golang.zx2c4.com/wireguard/device"
	"golang.zx2c4.com/wireguard/tun/netstack"
)

// Schluesselpaar erzeugt ein WireGuard-Paar auf dem Geraet. Nur der
// oeffentliche Teil geht an die API (wie bei den Laptop-Stationen), damit
// weder die API noch wg-control den privaten je sehen.
func Schluesselpaar() (privat, oeffentlich string, err error) {
	var k [32]byte
	if _, err = rand.Read(k[:]); err != nil {
		return "", "", err
	}
	// Klemmen nach RFC 7748, wie `wg genkey`.
	k[0] &= 248
	k[31] = (k[31] & 127) | 64
	pub, err := curve25519.X25519(k[:], curve25519.Basepoint)
	if err != nil {
		return "", "", err
	}
	return base64.StdEncoding.EncodeToString(k[:]), base64.StdEncoding.EncodeToString(pub), nil
}

// Tunnel ist ein laufender Tunnel samt lokalem Proxy.
type Tunnel struct {
	dev   *device.Device
	tnet  *netstack.Net
	proxy *Proxy
	once  sync.Once
}

// Zustand ist, was die Oberflaeche anzeigt ("Verbunden" vs. "Wartet").
type Zustand struct {
	LetzterHandshake int64  `json:"letzter_handshake"` // Unix-Sekunden, 0 = noch keiner
	Empfangen        uint64 `json:"empfangen"`
	Gesendet         uint64 `json:"gesendet"`
	ProxyPort        int    `json:"proxy_port"`
}

// Start baut den Tunnel auf und startet den Proxy auf 127.0.0.1.
func Start(k Konfig) (*Tunnel, error) {
	wg, err := wgQuickLesen(k.WgQuick, k.PrivateKey)
	if err != nil {
		return nil, err
	}
	endpointIP, err := endpointAufloesen(wg.endpoint)
	if err != nil {
		return nil, err
	}
	// 1420 wie wg-quick: passt in die uebliche 1500er-Strecke samt IPv6-Kopf.
	tdev, tnet, err := netstack.CreateNetTUN(wg.adressen, wg.dns, 1420)
	if err != nil {
		return nil, fmt.Errorf("Netzstapel: %w", err)
	}
	dev := device.NewDevice(tdev, conn.NewDefaultBind(), device.NewLogger(device.LogLevelError, "rwtunnel: "))
	if err := dev.IpcSet(wg.uapi(endpointIP)); err != nil {
		dev.Close()
		return nil, fmt.Errorf("WireGuard-Einstellung: %w", err)
	}
	if err := dev.Up(); err != nil {
		dev.Close()
		return nil, err
	}
	t := &Tunnel{dev: dev, tnet: tnet}
	p, err := NeuerProxy(ProxyKonfig{
		ErlaubteZiele: k.ErlaubteZiele,
		SpiceProxy:    k.SpiceProxy,
		Hosts:         k.Hosts,
		Waehlen:       t.waehlen,
	})
	if err != nil {
		dev.Close()
		return nil, err
	}
	t.proxy = p
	return t, nil
}

func endpointAufloesen(ep string) (string, error) {
	host, port, err := net.SplitHostPort(ep)
	if err != nil {
		return "", fmt.Errorf("Endpoint %q: %w", ep, err)
	}
	if ip, err := netip.ParseAddr(host); err == nil {
		return netip.AddrPortFrom(ip, mustPort(port)).String(), nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	ips, err := net.DefaultResolver.LookupNetIP(ctx, "ip", host)
	if err != nil || len(ips) == 0 {
		return "", fmt.Errorf("Endpoint %s nicht aufloesbar: %v", host, err)
	}
	// IPv4 zuerst: der Endpunkt des Hauses ist heute nur ueber IPv4 erreichbar,
	// und ein gewaehltes IPv6 ohne Weg dorthin wuerde stumm nie verbinden.
	best := ips[0]
	for _, ip := range ips {
		if ip.Unmap().Is4() {
			best = ip.Unmap()
			break
		}
	}
	return netip.AddrPortFrom(best, mustPort(port)).String(), nil
}

func mustPort(s string) uint16 {
	n, _ := strconv.Atoi(s)
	return uint16(n)
}

// waehlen oeffnet eine TCP-Verbindung im Tunnel. Namen werden ueber den DNS
// im Tunnel aufgeloest (100.64.2.1), nicht ueber den des Geraets: der
// oeffentliche DNS gibt fuer pve1 eine andere Adresse heraus als der interne.
func (t *Tunnel) waehlen(ctx context.Context, adresse string) (net.Conn, error) {
	return t.tnet.DialContext(ctx, "tcp", adresse)
}

// ProxyPort und ProxyGeheimnis braucht die App fuer "PROXY rw:<geheimnis>@127.0.0.1:<port>".
func (t *Tunnel) ProxyPort() int         { return t.proxy.Port() }
func (t *Tunnel) ProxyGeheimnis() string { return t.proxy.Geheimnis() }

// Zustand liest Handshake und Zaehler aus wireguard-go.
func (t *Tunnel) Zustand() (Zustand, error) {
	z := Zustand{ProxyPort: t.proxy.Port()}
	text, err := t.dev.IpcGet()
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
	return z, nil
}

// Stop schliesst Proxy und Tunnel. Mehrfacher Aufruf schadet nicht.
func (t *Tunnel) Stop() {
	t.once.Do(func() {
		if t.proxy != nil {
			t.proxy.Close()
		}
		t.dev.Close()
	})
}

var ErrKeinTunnel = errors.New("kein Tunnel")
