// SPDX-License-Identifier: GPL-3.0-or-later

// C-Schnittstelle fuer dart:ffi.
//
// Alles geht als JSON-Text hin und her: vier Funktionen, keine Strukturen,
// die auf beiden Seiten gleich ausgelegt sein muessten. Bei einer Handvoll
// Aufrufen pro Sitzung kostet das nichts und erspart eine ganze Fehlerklasse.
//
// Jeder zurueckgegebene Text gehoert dem Aufrufer und muss mit rwt_frei
// freigegeben werden.
//
// Gebaut als c-shared (Linux .so, Windows .dll, macOS .dylib, Android .so)
// bzw. c-archive fuer iOS (dort sind eigene dynamische Go-Bibliotheken
// moeglich, aber ein statisches Archiv ist der uebliche Weg; Go und
// wireguard-go sind MIT/BSD, statisch linken ist unbedenklich).
package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"os"
	"runtime/debug"
	"sync"
	"unsafe"

	"ch.rosenweg4303/rwtunnel/tunnel"
)

var (
	mu    sync.Mutex
	aktiv *tunnel.Tunnel
)

func antwort(v any) *C.char {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"fehler":"intern"}`)
	}
	return C.CString(string(b))
}

func fehler(err error) *C.char { return antwort(map[string]string{"fehler": err.Error()}) }

// auffangen macht aus einem panic in einer exportierten Funktion eine
// Fehlerantwort. Ohne das beendet die Go-Laufzeit den ganzen Prozess (App-
// Fenster weg, kein Absturzbericht von macOS). Gilt nur fuer den Aufruf
// selbst; panics in Hintergrund-Goroutinen landen in der Absturzdatei
// (rwt_absturzdatei). Ein "defer mu.Unlock()" der Funktion laeuft vorher.
func auffangen(aus **C.char) {
	if r := recover(); r != nil {
		if aus != nil {
			*aus = fehler(fmt.Errorf("interner Fehler im Tunnel: %v", r))
		}
	}
}

// rwt_absturzdatei: wohin die Go-Laufzeit bei einem nicht aufgefangenen
// panic/fatal error ihre Ausgabe zusaetzlich schreibt (Logdatei der App).
//
//export rwt_absturzdatei
func rwt_absturzdatei(pfad *C.char) (aus *C.char) {
	defer auffangen(&aus)
	f, err := os.OpenFile(C.GoString(pfad), os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o600)
	if err != nil {
		return fehler(err)
	}
	if err := debug.SetCrashOutput(f, debug.CrashOptions{}); err != nil {
		f.Close()
		return fehler(err)
	}
	f.Close() // SetCrashOutput haelt eine eigene Kopie
	return antwort(map[string]bool{"ok": true})
}

//export rwt_schluesselpaar
func rwt_schluesselpaar() (aus *C.char) {
	defer auffangen(&aus)
	priv, pub, err := tunnel.Schluesselpaar()
	if err != nil {
		return fehler(err)
	}
	return antwort(map[string]string{"privat": priv, "oeffentlich": pub})
}

// rwt_start baut den (einzigen) Tunnel auf. Ein laufender wird vorher
// geschlossen: die App hat nie mehr als einen, und ein vergessener zweiter
// waere ein offenes Loch ins Hausnetz.
//
//export rwt_start
func rwt_start(konfigJSON *C.char) (aus *C.char) {
	defer auffangen(&aus)
	var k tunnel.Konfig
	if err := json.Unmarshal([]byte(C.GoString(konfigJSON)), &k); err != nil {
		return fehler(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if aktiv != nil {
		aktiv.Stop()
		aktiv = nil
	}
	t, err := tunnel.Start(k)
	if err != nil {
		return fehler(err)
	}
	aktiv = t
	return antwort(map[string]any{"proxy_port": t.ProxyPort(), "proxy_geheimnis": t.ProxyGeheimnis()})
}

//export rwt_zustand
func rwt_zustand() (aus *C.char) {
	defer auffangen(&aus)
	mu.Lock()
	defer mu.Unlock()
	if aktiv == nil {
		return fehler(tunnel.ErrKeinTunnel)
	}
	z, err := aktiv.Zustand()
	if err != nil {
		return fehler(err)
	}
	return antwort(z)
}

// rwt_weiterleitung oeffnet einen lokalen Port zu einem freigegebenen Ziel.
//
//export rwt_weiterleitung
func rwt_weiterleitung(ziel *C.char) (aus *C.char) {
	defer auffangen(&aus)
	mu.Lock()
	defer mu.Unlock()
	if aktiv == nil {
		return fehler(tunnel.ErrKeinTunnel)
	}
	port, err := aktiv.Weiterleiten(C.GoString(ziel))
	if err != nil {
		return fehler(err)
	}
	return antwort(map[string]int{"port": port})
}

// rwt_endpunkt wechselt den Endpunkt im laufenden Tunnel (Roaming).
//
//export rwt_endpunkt
func rwt_endpunkt(ep *C.char) (aus *C.char) {
	defer auffangen(&aus)
	mu.Lock()
	defer mu.Unlock()
	if aktiv == nil {
		return fehler(tunnel.ErrKeinTunnel)
	}
	if err := aktiv.EndpunktSetzen(C.GoString(ep)); err != nil {
		return fehler(err)
	}
	return antwort(map[string]bool{"ok": true})
}

//export rwt_stop
func rwt_stop() {
	defer auffangen(nil)
	mu.Lock()
	defer mu.Unlock()
	if aktiv != nil {
		aktiv.Stop()
		aktiv = nil
	}
}

//export rwt_frei
func rwt_frei(p *C.char) { C.free(unsafe.Pointer(p)) }

func main() {}
