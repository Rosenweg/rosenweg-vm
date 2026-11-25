// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"crypto/tls"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"
)

func main() {
	k, err := KonfigLesen()
	if err != nil {
		log.Fatalf("FATAL: %v", err)
	}
	g, err := Starten(k, nil)
	if err != nil {
		log.Fatalf("FATAL: %v", err)
	}
	defer g.Stoppen()
	fmt.Fprintf(os.Stderr, "vm-gateway: WireGuard UDP %d, Tunnelnetz %s, Steuerung %s\n", k.WgPort, k.Netz, k.SteuerBind)

	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)
	<-sig
}

// Laufend: Gateway samt Servern; fuer main und die Tests.
type Laufend struct {
	*Gateway
	server []*http.Server
	steuer net.Listener
	stop   chan struct{}
}

func (l *Laufend) SteuerAdresse() string { return l.steuer.Addr().String() }

func (l *Laufend) Stoppen() {
	close(l.stop)
	for _, s := range l.server {
		s.Close()
	}
	l.Schliessen()
}

// Starten: pveTLS nur fuer Tests (eigene CA); sonst nil = Systemvorrat bzw. PVE_CA.
func Starten(k Konfig, pveTLS *tls.Config) (*Laufend, error) {
	konten := NeueKonten(k)
	pve, err := NeuesPVE(k, pveTLS)
	if err != nil {
		return nil, err
	}
	g, err := NeuerGateway(k, konten, pve, &Protokoll{aus: os.Stdout})
	if err != nil {
		return nil, err
	}
	l := &Laufend{Gateway: g, stop: make(chan struct{})}

	api, err := g.tnet.ListenTCP(&net.TCPAddr{IP: net.IP(g.eigen.AsSlice()), Port: 80})
	if err != nil {
		return nil, err
	}
	spice, err := g.tnet.ListenTCP(&net.TCPAddr{IP: net.IP(g.eigen.AsSlice()), Port: 3128})
	if err != nil {
		return nil, err
	}
	steuer, err := net.Listen("tcp", k.SteuerBind)
	if err != nil {
		return nil, err
	}
	l.steuer = steuer
	sAPI := &http.Server{Handler: g.Schnittstelle(), ReadHeaderTimeout: 10 * time.Second}
	sSteuer := &http.Server{Handler: g.Steuerung(), ReadHeaderTimeout: 10 * time.Second}
	l.server = []*http.Server{sAPI, sSteuer}
	go sAPI.Serve(api)
	go sSteuer.Serve(steuer)
	go func() {
		g.SpiceAnnehmen(spice)
	}()
	go func() {
		<-l.stop
		spice.Close()
	}()
	go func() {
		t := time.NewTicker(30 * time.Second)
		defer t.Stop()
		for {
			select {
			case <-t.C:
				g.Aufraeumen()
			case <-l.stop:
				return
			}
		}
	}()
	return l, nil
}
