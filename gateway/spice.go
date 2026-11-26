// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/netip"
	"net/textproto"
	"strings"
	"time"
)

// SPICE-Weiterreichung (Port 3128 im Netzstapel).
//
// spice-glib in der App schickt "CONNECT pvespiceproxy:<ticket>:<vmid>:<knoten>:<port>".
// Durchgelassen wird NUR ein Ziel, das der Gateway selbst kurz vorher fuer
// genau diesen Peer bei Proxmox geholt hat (POST /computer/<id>/bildschirm)
// und das hoechstens zwei Minuten alt ist. Alles andere: 403. So wird der
// Gateway nie zum allgemeinen Sprungbrett zu pve:3128, auch nicht mit einem
// woanders erbeuteten Ticket.
//
// Der Inhalt bleibt Ende-zu-Ende verschluesselt (TLS zwischen spice-glib und
// QEMU, geprueft mit der CA und dem Betreff aus der spiceproxy-Antwort); der
// Gateway sieht keinen Bildschirm.

func (g *Gateway) SpiceAnnehmen(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		go func() {
			defer c.Close()
			g.spiceBedienen(c)
		}()
	}
}

func antwort(c net.Conn, status int, text string) {
	fmt.Fprintf(c, "HTTP/1.0 %d %s\r\n\r\n", status, text)
}

func (g *Gateway) spiceBedienen(c net.Conn) {
	c.SetReadDeadline(time.Now().Add(15 * time.Second))
	ap, err := netip.ParseAddrPort(c.RemoteAddr().String())
	if err != nil {
		return
	}
	peer := g.Peer(ap.Addr())
	if peer == nil {
		return
	}
	br := bufio.NewReader(c)
	tp := textproto.NewReader(br)
	zeile, err := tp.ReadLine()
	if err != nil || len(zeile) > 4096 {
		return
	}
	if _, err := tp.ReadMIMEHeader(); err != nil {
		return
	}
	teile := strings.Fields(zeile)
	if len(teile) != 3 || teile[0] != "CONNECT" {
		antwort(c, 405, "Method Not Allowed")
		return
	}
	ziel := teile[1]
	e := Eintrag{Aktion: "spice", Email: peer.Email, Benutzer: peer.Benutzer, Peer: peer.IP.String()}

	g.mu.Lock()
	t, ok := g.tickets[ziel]
	g.mu.Unlock()
	if !ok || t.Peer != peer.IP || g.jetzt().After(t.Bis) || strings.ContainsAny(ziel, "\r\n") {
		e.Ergebnis, e.Grund = "abgewiesen", "Ziel nicht vom Gateway ausgestellt"
		g.log.Schreiben(e)
		antwort(c, 403, "Forbidden")
		return
	}
	e.VMID = t.VMID

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	var d net.Dialer
	oben, err := d.DialContext(ctx, "tcp", t.SpiceHost)
	cancel()
	if err != nil {
		e.Ergebnis, e.Grund = "fehler", "pve:3128 nicht erreichbar"
		g.log.Schreiben(e)
		antwort(c, 502, "Bad Gateway")
		return
	}
	defer oben.Close()
	// Der spiceproxy von Proxmox liest das Ticket aus dem Host-Kopf, nicht aus
	// der CONNECT-Zeile (PVE::APIServer::AnyEvent, verify_spice_connect_url).
	// Ohne Host antwortet er "401 invalid ticket". Das Ticket gilt dort nur
	// rund 40 Sekunden ab Ausstellung.
	if _, err := fmt.Fprintf(oben, "CONNECT %s HTTP/1.0\r\nHost: %s\r\n\r\n", ziel, ziel); err != nil {
		return
	}
	// Antwort von pve:3128 lesen, damit das Protokoll stimmt ("ok" erst bei
	// 200), und unveraendert an die App weitergeben.
	oben.SetReadDeadline(time.Now().Add(15 * time.Second))
	obenBr := bufio.NewReader(oben)
	var kopf strings.Builder
	status := ""
	for {
		l, err := obenBr.ReadString('\n')
		if err != nil || kopf.Len() > 8192 {
			e.Ergebnis, e.Grund = "fehler", "pve:3128 antwortet nicht"
			g.log.Schreiben(e)
			antwort(c, 502, "Bad Gateway")
			return
		}
		if status == "" {
			status = strings.TrimSpace(l)
		}
		kopf.WriteString(l)
		if l == "\r\n" || l == "\n" {
			break
		}
	}
	oben.SetReadDeadline(time.Time{})
	if f := strings.Fields(status); len(f) < 2 || f[1] != "200" {
		e.Ergebnis, e.Grund = "fehler", "pve:3128: "+status
	} else {
		e.Ergebnis = "ok"
	}
	g.log.Schreiben(e)
	if _, err := io.WriteString(c, kopf.String()); err != nil || e.Ergebnis != "ok" {
		return
	}
	c.SetReadDeadline(time.Time{})

	fertig := make(chan struct{}, 2)
	go func() { io.Copy(oben, br); fertig <- struct{}{} }()
	go func() { io.Copy(c, obenBr); fertig <- struct{}{} }()
	<-fertig
}
