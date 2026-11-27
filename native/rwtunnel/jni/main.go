// SPDX-License-Identifier: GPL-3.0-or-later

//go:build android

// JNI-Schnittstelle fuer Rosenweg Geraet (Java): die Telefonseite der
// Fernwartung (tunnel.HoerenStart). Gegenstueck: java/ch/rosenweg4303/rwtunnel/
// RwFernwartung.java, das die App unveraendert uebernimmt.
//
// Wie capi alles als JSON-Text. Java-Strings sind "modified UTF-8"; damit
// Zeichen ausserhalb der BMP nicht stoeren, gehen alle Antworten als reines
// ASCII hinaus (\uXXXX).
//
// Gebaut mit ./bauen.sh android-jni -> build/android-jni/<abi>/librwtunnel_jni.so
package main

/*
#include <jni.h>
#include <stdlib.h>

static const char* rw_utf(JNIEnv* e, jstring s) { return s ? (*e)->GetStringUTFChars(e, s, NULL) : NULL; }
static void rw_utf_frei(JNIEnv* e, jstring s, const char* c) { if (s && c) (*e)->ReleaseStringUTFChars(e, s, c); }
static jstring rw_neu(JNIEnv* e, const char* c) { return (*e)->NewStringUTF(e, c); }
*/
import "C"

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"
	"time"
	"unsafe"

	"ch.rosenweg4303/rwtunnel/tunnel"
)

var (
	mu    sync.Mutex
	aktiv *tunnel.Hoerer
)

func ascii(b []byte) string {
	var s strings.Builder
	for _, r := range string(b) {
		if r < 0x80 {
			s.WriteRune(r)
		} else if r <= 0xffff {
			fmt.Fprintf(&s, `\u%04x`, r)
		} else {
			r -= 0x10000
			fmt.Fprintf(&s, `\u%04x\u%04x`, 0xd800+(r>>10), 0xdc00+(r&0x3ff))
		}
	}
	return s.String()
}

func antwort(env *C.JNIEnv, v any) C.jstring {
	b, err := json.Marshal(v)
	if err != nil {
		b = []byte(`{"fehler":"intern"}`)
	}
	cs := C.CString(ascii(b))
	defer C.free(unsafe.Pointer(cs))
	return C.rw_neu(env, cs)
}

func fehler(env *C.JNIEnv, err error) C.jstring {
	return antwort(env, map[string]string{"fehler": err.Error()})
}

func text(env *C.JNIEnv, s C.jstring) string {
	c := C.rw_utf(env, s)
	if c == nil {
		return ""
	}
	defer C.rw_utf_frei(env, s, c)
	return C.GoString(c)
}

// auffangen: ein panic darf den Prozess von Geraet (Device Owner, Kiosk) nie beenden.
func auffangen(env *C.JNIEnv, aus *C.jstring) {
	if r := recover(); r != nil && aus != nil {
		*aus = fehler(env, fmt.Errorf("interner Fehler im Tunnel: %v", r))
	}
}

func mitTunnel(env *C.JNIEnv, f func(h *tunnel.Hoerer) (any, error)) C.jstring {
	mu.Lock()
	h := aktiv
	mu.Unlock()
	if h == nil {
		return fehler(env, tunnel.ErrKeinTunnel)
	}
	v, err := f(h)
	if err != nil {
		return fehler(env, err)
	}
	return antwort(env, v)
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_schluesselpaar
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_schluesselpaar(env *C.JNIEnv, _ C.jclass) (aus C.jstring) {
	defer auffangen(env, &aus)
	priv, pub, err := tunnel.Schluesselpaar()
	if err != nil {
		return fehler(env, err)
	}
	return antwort(env, map[string]string{"privat": priv, "oeffentlich": pub})
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_oeffentlich
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_oeffentlich(env *C.JNIEnv, _ C.jclass, privat C.jstring) (aus C.jstring) {
	defer auffangen(env, &aus)
	pub, err := tunnel.OeffentlicherSchluessel(text(env, privat))
	if err != nil {
		return fehler(env, err)
	}
	return antwort(env, map[string]string{"oeffentlich": pub})
}

// start: ein laufender Tunnel wird vorher geschlossen (nie zwei).
//
//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_start
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_start(env *C.JNIEnv, _ C.jclass, konfig C.jstring) (aus C.jstring) {
	defer auffangen(env, &aus)
	var k tunnel.HoerKonfig
	if err := json.Unmarshal([]byte(text(env, konfig)), &k); err != nil {
		return fehler(env, err)
	}
	k.AdbZiel = "" // immer adbd des Telefons, nie ein anderes Ziel
	mu.Lock()
	defer mu.Unlock()
	if aktiv != nil {
		aktiv.Stop()
		aktiv = nil
	}
	h, err := tunnel.HoerenStart(k)
	if err != nil {
		return fehler(env, err)
	}
	aktiv = h
	return antwort(env, map[string]bool{"ok": true})
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_zustand
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_zustand(env *C.JNIEnv, _ C.jclass) (aus C.jstring) {
	defer auffangen(env, &aus)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) { return h.Zustand() })
}

// warte: blockiert bis zum naechsten Ereignis (auf/zu/anzeige) oder ms;
// {"art":""} = nichts passiert. Fuer einen eigenen Faden.
//
//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_warte
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_warte(env *C.JNIEnv, _ C.jclass, ms C.jint) (aus C.jstring) {
	defer auffangen(env, &aus)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) {
		e, ok := h.WarteEreignis(time.Duration(ms) * time.Millisecond)
		if !ok {
			return map[string]string{"art": ""}, nil
		}
		return e, nil
	})
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_anstossen
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_anstossen(env *C.JNIEnv, _ C.jclass) (aus C.jstring) {
	defer auffangen(env, &aus)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) { h.Anstossen(); return map[string]bool{"ok": true}, nil })
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_netzWechsel
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_netzWechsel(env *C.JNIEnv, _ C.jclass) (aus C.jstring) {
	defer auffangen(env, &aus)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) { return map[string]bool{"ok": true}, h.NetzWechsel() })
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_endpunkt
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_endpunkt(env *C.JNIEnv, _ C.jclass, ep C.jstring) (aus C.jstring) {
	defer auffangen(env, &aus)
	e := text(env, ep)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) { return map[string]bool{"ok": true}, h.EndpunktSetzen(e) })
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_keepalive
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_keepalive(env *C.JNIEnv, _ C.jclass, sek C.jint) (aus C.jstring) {
	defer auffangen(env, &aus)
	return mitTunnel(env, func(h *tunnel.Hoerer) (any, error) { return map[string]bool{"ok": true}, h.KeepaliveSetzen(int(sek)) })
}

//export Java_ch_rosenweg4303_rwtunnel_RwFernwartung_stop
func Java_ch_rosenweg4303_rwtunnel_RwFernwartung_stop(env *C.JNIEnv, _ C.jclass) {
	defer auffangen(env, nil)
	mu.Lock()
	h := aktiv
	aktiv = nil
	mu.Unlock()
	if h != nil {
		h.Stop()
	}
}

func main() {}
