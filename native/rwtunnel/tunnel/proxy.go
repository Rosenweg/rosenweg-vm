// SPDX-License-Identifier: GPL-3.0-or-later

package tunnel

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/textproto"
	"strings"
	"sync"
	"time"
)

// Der lokale Proxy ist die einzige Tuer in den Tunnel.
//
// Warum ein HTTP-CONNECT-Proxy: Der Dart-HttpClient kann ihn ueber findProxy
// benutzen und prueft das TLS-Zertifikat dabei weiterhin gegen den echten
// Namen (pve1.rosenweg4303.ch), weil TLS durch den CONNECT-Tunnel hindurch
// Ende-zu-Ende laeuft. spice-glib kann ihn ueber seine Eigenschaft "proxy"
// ebenso benutzen — genau so, wie es ohne Tunnel den SPICE-Proxy von Proxmox
// (Port 3128) benutzt.
//
// SPICE-Sonderfall: Proxmox erwartet am Port 3128 ein CONNECT auf ein Ziel
// "pvespiceproxy:<ticket>:<vmid>:<knoten>:<port>". Ein Proxy hinter einem
// Proxy ist in spice-glib nicht vorgesehen. Deshalb reicht dieser Proxy
// solche Ziele unveraendert an den SPICE-Proxy des Clusters weiter, statt sie
// selbst aufzuloesen. Die Antwort von Proxmox ("200 OK" oder ein Fehler) geht
// durch, als haette spice-glib direkt gefragt.
//
// Schutz: Er hoert nur auf 127.0.0.1, verlangt ein Geheimnis (Basic-Auth,
// pro Start neu) und laesst nur die Ziele durch, die die App beim Start
// nennt. Ein anderes Programm auf demselben Rechner kommt so nicht ueber den
// Tunnel der angemeldeten Person ins Hausnetz.

// ProxyKonfig steuert den Proxy; Waehlen oeffnet die Verbindung (im Tunnel
// oder im Test direkt).
type ProxyKonfig struct {
	ErlaubteZiele []string
	SpiceProxy    string
	Hosts         map[string]string
	Waehlen       func(ctx context.Context, adresse string) (net.Conn, error)
}

type Proxy struct {
	k         ProxyKonfig
	ln        net.Listener
	geheimnis string
	erlaubt   map[string]bool
	wg        sync.WaitGroup
	mu        sync.Mutex
	offen     map[net.Conn]struct{}
	weiter    []net.Listener
}

const spicePraefix = "pvespiceproxy:"

func NeuerProxy(k ProxyKonfig) (*Proxy, error) {
	if k.Waehlen == nil {
		return nil, errors.New("Waehlen fehlt")
	}
	g := make([]byte, 24)
	if _, err := rand.Read(g); err != nil {
		return nil, err
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	p := &Proxy{k: k, ln: ln, geheimnis: hex.EncodeToString(g), erlaubt: map[string]bool{}, offen: map[net.Conn]struct{}{}}
	for _, z := range k.ErlaubteZiele {
		p.erlaubt[strings.ToLower(z)] = true
	}
	p.wg.Add(1)
	go p.annehmen()
	return p, nil
}

func (p *Proxy) Port() int         { return p.ln.Addr().(*net.TCPAddr).Port }
func (p *Proxy) Geheimnis() string { return p.geheimnis }

func (p *Proxy) Close() {
	p.ln.Close()
	p.mu.Lock()
	for _, l := range p.weiter {
		l.Close()
	}
	for c := range p.offen {
		c.Close()
	}
	p.mu.Unlock()
	p.wg.Wait()
}

func (p *Proxy) merken(c net.Conn, an bool) {
	p.mu.Lock()
	defer p.mu.Unlock()
	if an {
		p.offen[c] = struct{}{}
	} else {
		delete(p.offen, c)
	}
}

func (p *Proxy) annehmen() {
	defer p.wg.Done()
	for {
		c, err := p.ln.Accept()
		if err != nil {
			return
		}
		p.wg.Add(1)
		go func() {
			defer p.wg.Done()
			p.merken(c, true)
			defer p.merken(c, false)
			defer c.Close()
			p.bedienen(c)
		}()
	}
}

func antworten(c net.Conn, status int, text string) {
	fmt.Fprintf(c, "HTTP/1.1 %d %s\r\nContent-Length: 0\r\nConnection: close\r\n", status, text)
	if status == http.StatusProxyAuthRequired {
		io.WriteString(c, "Proxy-Authenticate: Basic realm=\"rosenweg\"\r\n")
	}
	io.WriteString(c, "\r\n")
}

func (p *Proxy) berechtigt(kopf http.Header) bool {
	h := kopf.Get("Proxy-Authorization")
	art, wert, ok := strings.Cut(h, " ")
	if !ok || !strings.EqualFold(art, "Basic") {
		return false
	}
	roh, err := base64.StdEncoding.DecodeString(strings.TrimSpace(wert))
	if err != nil {
		return false
	}
	_, pw, _ := strings.Cut(string(roh), ":")
	return subtle.ConstantTimeCompare([]byte(pw), []byte(p.geheimnis)) == 1
}

func (p *Proxy) bedienen(c net.Conn) {
	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	br := bufio.NewReader(c)
	// Nicht http.ReadRequest: das versteht das Proxmox-Ziel
	// "pvespiceproxy:<ticket>:<vmid>:<knoten>:<port>" nicht als Authority und
	// lehnt es ab. Eine CONNECT-Anfrage ist einfach genug, um sie selbst zu lesen.
	tp := textproto.NewReader(br)
	zeile, err := tp.ReadLine()
	if err != nil || len(zeile) > 4096 {
		return
	}
	teile := strings.Fields(zeile)
	if len(teile) != 3 || !strings.HasPrefix(teile[2], "HTTP/1.") {
		antworten(c, http.StatusBadRequest, "Bad Request")
		return
	}
	kopf, err := tp.ReadMIMEHeader()
	if err != nil {
		return
	}
	if teile[0] != http.MethodConnect {
		antworten(c, http.StatusMethodNotAllowed, "Method Not Allowed")
		return
	}
	if !p.berechtigt(http.Header(kopf)) {
		antworten(c, http.StatusProxyAuthRequired, "Proxy Authentication Required")
		return
	}
	ziel := teile[1]
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	if strings.HasPrefix(strings.ToLower(ziel), spicePraefix) {
		p.spiceWeiterreichen(c, br, ziel, ctx)
		return
	}

	host, port, err := net.SplitHostPort(ziel)
	if err != nil || !p.erlaubt[strings.ToLower(ziel)] {
		antworten(c, http.StatusForbidden, "Forbidden")
		return
	}
	if fest, ok := p.k.Hosts[strings.ToLower(host)]; ok && fest != "" {
		host = fest
	}
	ziel2, err := p.k.Waehlen(ctx, net.JoinHostPort(host, port))
	if err != nil {
		antworten(c, http.StatusBadGateway, "Bad Gateway")
		return
	}
	defer ziel2.Close()
	c.SetReadDeadline(time.Time{})
	io.WriteString(c, "HTTP/1.1 200 Connection established\r\n\r\n")
	p.verbinden(c, br, ziel2)
}

func (p *Proxy) spiceWeiterreichen(c net.Conn, br *bufio.Reader, ziel string, ctx context.Context) {
	if p.k.SpiceProxy == "" {
		antworten(c, http.StatusForbidden, "Forbidden")
		return
	}
	// Nur das Format von Proxmox, damit hier nichts Fremdes durchrutscht
	// (Zeilenumbrueche, Leerzeichen). Inhaltlich prueft Proxmox das Ticket.
	if strings.ContainsAny(ziel, " \r\n\t") || len(ziel) > 2048 {
		antworten(c, http.StatusBadRequest, "Bad Request")
		return
	}
	host, port, err := net.SplitHostPort(p.k.SpiceProxy)
	if err != nil {
		antworten(c, http.StatusBadGateway, "Bad Gateway")
		return
	}
	if fest, ok := p.k.Hosts[strings.ToLower(host)]; ok && fest != "" {
		host = fest
	}
	oben, err := p.k.Waehlen(ctx, net.JoinHostPort(host, port))
	if err != nil {
		antworten(c, http.StatusBadGateway, "Bad Gateway")
		return
	}
	defer oben.Close()
	// Die Anfrage neu schreiben statt durchreichen: so geht das lokale
	// Geheimnis nie an Proxmox, und nur die eine Zeile, die Proxmox braucht.
	if _, err := fmt.Fprintf(oben, "CONNECT %s HTTP/1.0\r\n\r\n", ziel); err != nil {
		return
	}
	c.SetReadDeadline(time.Time{})
	p.verbinden(c, br, oben)
}

// verbinden pumpt in beide Richtungen, bis eine Seite schliesst.
func (p *Proxy) verbinden(c net.Conn, br *bufio.Reader, ziel net.Conn) {
	fertig := make(chan struct{}, 2)
	go func() {
		// Was der Client schon nach der Anfrage geschickt hat, liegt im Puffer.
		io.Copy(ziel, br)
		if cw, ok := ziel.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		}
		fertig <- struct{}{}
	}()
	go func() {
		io.Copy(c, ziel)
		if cw, ok := c.(interface{ CloseWrite() error }); ok {
			cw.CloseWrite()
		}
		fertig <- struct{}{}
	}()
	// Ist eine Richtung zu Ende, bekommt die andere kurz Zeit fuer den Rest.
	// Danach wird hart geschlossen: sonst haengt eine Seite, deren Gegenueber
	// kein halbes Schliessen kennt (netstack, Keep-Alive-Verbindungen), ewig
	// — und Close() des Proxys wartet mit. Im Gateway-Test so aufgefallen.
	<-fertig
	select {
	case <-fertig:
	case <-time.After(5 * time.Second):
	}
	c.Close()
	ziel.Close()
}

// Weiterleiten oeffnet einen lokalen Port, der jede Verbindung unveraendert
// zu ziel im Tunnel durchreicht, und liefert dessen Nummer.
//
// Wozu neben dem Proxy: Die Schnittstelle des Gateways spricht im Tunnel
// einfaches HTTP (WireGuard verschluesselt und weist den Absender schon
// aus). Fuer http:// schickt der Dart-HttpClient einem Proxy aber kein
// CONNECT, sondern die ganze Anfrage — das kann dieser Proxy bewusst nicht.
// Eine Weiterleitung ist einfacher und genauso eng: nur das eine Ziel aus der
// Freigabeliste. Ein Geheimnis braucht sie nicht, weil der Gateway ohnehin
// bei jeder Anfrage das Token der Person verlangt.
func (p *Proxy) Weiterleiten(ziel string) (int, error) {
	if !p.erlaubt[strings.ToLower(ziel)] {
		return 0, fmt.Errorf("Ziel %s nicht freigegeben", ziel)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	p.mu.Lock()
	p.weiter = append(p.weiter, ln)
	p.mu.Unlock()
	p.wg.Add(1)
	go func() {
		defer p.wg.Done()
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			p.wg.Add(1)
			go func() {
				defer p.wg.Done()
				p.merken(c, true)
				defer p.merken(c, false)
				defer c.Close()
				ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
				z, err := p.k.Waehlen(ctx, p.fest(ziel))
				cancel()
				if err != nil {
					return
				}
				defer z.Close()
				p.verbinden(c, bufio.NewReader(c), z)
			}()
		}
	}()
	return ln.Addr().(*net.TCPAddr).Port, nil
}

// fest setzt eine feste Adresse aus Hosts ein, falls fuer den Namen eine da ist.
func (p *Proxy) fest(ziel string) string {
	host, port, err := net.SplitHostPort(ziel)
	if err != nil {
		return ziel
	}
	if f, ok := p.k.Hosts[strings.ToLower(host)]; ok && f != "" {
		return net.JoinHostPort(f, port)
	}
	return ziel
}
