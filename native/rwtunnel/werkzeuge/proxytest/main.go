// proxytest: lokaler Proxy wie in der App, aber ohne WireGuard (direkte
// Verbindungen) und mit einem nachgebauten SPICE-Proxy von Proxmox davor.
// Damit laesst sich spice-glib durch die ganze Proxy-Kette testen:
//
//   spice-glib ─CONNECT pvespiceproxy:…─► Proxy (Geheimnis) ─► "Proxmox :3128" ─► SPICE-Server
//
// Aufruf: proxytest <spice-server host:port>
// Gibt die Proxy-Adresse fuer spice-glib aus und laeuft, bis er beendet wird.
package main

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"os"
	"strings"

	"ch.rosenweg4303/rwtunnel/tunnel"
)

func main() {
	ziel := os.Args[1]
	oben, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	go func() {
		for {
			c, err := oben.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				zeile, _ := br.ReadString('\n')
				for {
					l, err := br.ReadString('\n')
					if err != nil || l == "\r\n" {
						break
					}
				}
				if !strings.HasPrefix(zeile, "CONNECT pvespiceproxy:") {
					io.WriteString(c, "HTTP/1.0 400 Bad\r\n\r\n")
					return
				}
				fmt.Fprintf(os.Stderr, "Proxmox-Attrappe: %s", zeile)
				s, err := net.Dial("tcp", ziel)
				if err != nil {
					io.WriteString(c, "HTTP/1.0 502 Bad\r\n\r\n")
					return
				}
				defer s.Close()
				io.WriteString(c, "HTTP/1.0 200 OK\r\n\r\n")
				go io.Copy(s, br)
				io.Copy(c, s)
			}(c)
		}
	}()
	var d net.Dialer
	p, err := tunnel.NeuerProxy(tunnel.ProxyKonfig{
		SpiceProxy: oben.Addr().String(),
		Waehlen:    func(ctx context.Context, a string) (net.Conn, error) { return d.DialContext(ctx, "tcp", a) },
	})
	if err != nil {
		panic(err)
	}
	fmt.Printf("http://rw:%s@127.0.0.1:%d\n", p.Geheimnis(), p.Port())
	select {}
}
