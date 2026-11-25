// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"

	"ch.rosenweg4303/rwtunnel/tunnel"
)

// token baut ein JWT-artiges Token (Signatur egal: userinfo der Attrappe
// entscheidet ueber die Gueltigkeit, wie Authentik in echt).
func token(name, aud string) string {
	c, _ := json.Marshal(map[string]string{"aud": aud, "sub": name})
	return "kopf." + base64.RawURLEncoding.EncodeToString(c) + ".sig-" + name
}

type umgebungTest struct {
	t       *testing.T
	gw      *Laufend
	steuer  string
	tokens  map[string]string
	spiceIn chan string
}

func neueUmgebung(t *testing.T) *umgebungTest {
	u := &umgebungTest{t: t, tokens: map[string]string{
		"anna":  token("anna", "rosenweg-apps"),
		"bert":  token("bert", "rosenweg-apps"),
		"fremd": token("anna", "andere-anwendung"),
	}, spiceIn: make(chan string, 10)}

	// Authentik-Attrappe: userinfo
	ak := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		tok := strings.TrimPrefix(r.Header.Get("Authorization"), "Bearer ")
		for name, t := range u.tokens {
			if t == tok {
				json.NewEncoder(w).Encode(map[string]any{
					"email": strings.TrimSuffix(name, "fremd") + "@rosenweg.test", "email_verified": true,
					"preferred_username": map[string]string{"anna": "anna", "bert": "bert", "fremd": "anna"}[name],
					"name":               name, "sub": name,
				})
				return
			}
		}
		w.WriteHeader(401)
	}))
	t.Cleanup(ak.Close)

	// SPICE-Proxy-Attrappe (pve:3128): Echo nach "200 OK"
	sp, _ := net.Listen("tcp", "127.0.0.1:0")
	t.Cleanup(func() { sp.Close() })
	go func() {
		for {
			c, err := sp.Accept()
			if err != nil {
				return
			}
			go func(c net.Conn) {
				defer c.Close()
				br := bufio.NewReader(c)
				zeile, _ := br.ReadString('\n')
				br.ReadString('\n')
				u.spiceIn <- strings.TrimSpace(zeile)
				io.WriteString(c, "HTTP/1.0 200 OK\r\n\r\n")
				io.Copy(c, br)
			}(c)
		}
	}()

	// Proxmox-Attrappe
	rechte := map[string]map[string][]string{
		"anna@authentik": {
			"/vms/101":    {"VM.Audit", "VM.Console"},
			"/vms/102":    {"VM.Audit"},
			"/pool/buero": {"VM.Audit", "VM.Console", "VM.PowerMgmt"},
		},
	}
	pve := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "PVEAPIToken=vm-gateway@pve!app=geheim" {
			w.WriteHeader(401)
			return
		}
		antw := func(v any) { json.NewEncoder(w).Encode(map[string]any{"data": v}) }
		p := strings.TrimPrefix(r.URL.Path, "/api2/json")
		switch {
		case p == "/cluster/resources":
			antw([]map[string]any{
				{"vmid": 101, "name": "Buero", "node": "pve1", "status": "running", "type": "qemu"},
				{"vmid": 102, "name": "Nur sehen", "node": "pve2", "status": "running", "type": "qemu"},
				{"vmid": 103, "name": "Geheim", "node": "pve1", "status": "running", "type": "qemu"},
				{"vmid": 104, "name": "Pool", "node": "pve3", "status": "stopped", "type": "qemu", "pool": "buero"},
				{"vmid": 200, "name": "ct", "node": "pve1", "status": "running", "type": "lxc"},
			})
		case strings.HasPrefix(p, "/access/users/"):
			switch strings.TrimPrefix(p, "/access/users/") {
			case "anna@authentik":
				antw(map[string]any{"enable": 1, "expire": 0})
			case "bert@authentik":
				antw(map[string]any{"enable": 0, "expire": 0})
			default:
				w.WriteHeader(500)
				io.WriteString(w, `{"message":"no such user"}`)
			}
		case p == "/access/permissions":
			pfad := r.URL.Query().Get("path")
			privs := map[string]int{}
			for _, pr := range rechte[r.URL.Query().Get("userid")][pfad] {
				privs[pr] = 1
			}
			antw(map[string]any{pfad: privs})
		case strings.HasSuffix(p, "/spiceproxy"):
			vmid := strings.Split(p, "/")[4]
			antw(map[string]any{"host": "pvespiceproxy:TICKET:" + vmid + ":pve1", "tls-port": 61000,
				"password": "pw", "proxy": "http://x:3128", "ca": "-----BEGIN CERTIFICATE-----\\nX\\n-----END CERTIFICATE-----"})
		case strings.HasSuffix(p, "/status/start"):
			antw("UPID:test")
		default:
			w.WriteHeader(404)
		}
	}))
	t.Cleanup(pve.Close)

	udp, _ := net.ListenUDP("udp", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1)})
	wgPort := udp.LocalAddr().(*net.UDPAddr).Port
	udp.Close()

	k := Konfig{
		WgPort: wgPort, EndpointExtern: fmt.Sprintf("127.0.0.1:%d", wgPort), EndpointIntern: fmt.Sprintf("127.0.0.1:%d", wgPort),
		Netz: netip.MustParsePrefix("10.243.43.0/24"), SteuerBind: "127.0.0.1:0", SteuerToken: strings.Repeat("s", 40),
		Schluessel: filepath.Join(t.TempDir(), "server.key"),
		Userinfo:   ak.URL, ClientID: "rosenweg-apps",
		PVEHosts:     []string{strings.TrimPrefix(pve.URL, "https://")},
		PVESpicePort: sp.Addr().(*net.TCPAddr).Port,
		PVEToken:     "vm-gateway@pve!app=geheim", PVERealm: "authentik", BenutzerClaim: "preferred_username",
		OhneHandshake: 3 * time.Minute, Still: 5 * time.Minute, MaxJePerson: 2,
	}
	gw, err := Starten(k, pve.Client().Transport.(*http.Transport).TLSClientConfig)
	if err != nil {
		t.Fatal(err)
	}
	gw.log.aus = io.Discard
	if testing.Verbose() {
		gw.log.aus = os.Stderr
	}
	t.Cleanup(gw.Stoppen)
	u.gw = gw
	u.steuer = "http://" + gw.SteuerAdresse()
	return u
}

// anmelden: wie die Haupt-API — Peer anlegen, dann Tunnel auf App-Seite.
func (u *umgebungTest) anmelden(wer, geraet string) (*tunnel.Tunnel, string) {
	priv, pub, _ := tunnel.Schluesselpaar()
	body, _ := json.Marshal(map[string]string{"geraet": geraet, "schluessel": pub})
	req, _ := http.NewRequest("POST", u.steuer+"/peers", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+strings.Repeat("s", 40))
	req.Header.Set("X-Rosenweg-Token", u.tokens[wer])
	r, err := http.DefaultClient.Do(req)
	if err != nil || r.StatusCode != 200 {
		u.t.Fatalf("Peer fuer %s: %v %v", wer, err, r.Status)
	}
	var a map[string]string
	json.NewDecoder(r.Body).Decode(&a)
	r.Body.Close()
	tun, err := tunnel.Start(tunnel.Konfig{
		WgQuick: a["config"], PrivateKey: priv,
		ErlaubteZiele: []string{a["gateway"] + ":80"}, SpiceProxy: a["gateway"] + ":3128",
	})
	if err != nil {
		u.t.Fatal(err)
	}
	u.t.Cleanup(tun.Stop)
	port, err := tun.Weiterleiten(a["gateway"] + ":80")
	if err != nil {
		u.t.Fatal(err)
	}
	return tun, fmt.Sprintf("http://127.0.0.1:%d", port)
}

func ruf(t *testing.T, methode, url, tok string) (int, []byte) {
	req, _ := http.NewRequest(methode, url, nil)
	req.Header.Set("Authorization", "Bearer "+tok)
	r, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer r.Body.Close()
	b, _ := io.ReadAll(r.Body)
	return r.StatusCode, b
}

func TestGatewayEndeZuEnde(t *testing.T) {
	u := neueUmgebung(t)
	tun, api := u.anmelden("anna", "geraet-anna-1")

	// Steuerung ohne bzw. mit falschem Personen-Token
	req, _ := http.NewRequest("POST", u.steuer+"/peers", strings.NewReader(`{}`))
	req.Header.Set("Authorization", "Bearer falsch")
	if r, _ := http.DefaultClient.Do(req); r.StatusCode != 401 {
		t.Fatalf("Steuerung ohne Steuer-Token: %d", r.StatusCode)
	}

	// Liste: 101 (oeffnen), 102 (nur sehen), 104 (ueber Pool, oeffnen+einschalten); 103 und Container nicht.
	st, b := ruf(t, "GET", api+"/computer", u.tokens["anna"])
	if st != 200 {
		t.Fatalf("Liste: %d %s", st, b)
	}
	var liste []computerAntwort
	json.Unmarshal(b, &liste)
	got := map[int]computerAntwort{}
	for _, c := range liste {
		got[c.VMID] = c
	}
	if len(liste) != 3 || !got[101].Oeffnen || got[102].Oeffnen || !got[104].Einschalten || got[101].Einschalten {
		t.Fatalf("Liste falsch: %s", b)
	}
	if _, ok := got[103]; ok {
		t.Fatal("103 haette nicht sichtbar sein duerfen")
	}

	// Token einer anderen Anwendung: abgewiesen.
	if st, _ := ruf(t, "GET", api+"/computer", u.tokens["fremd"]); st != 401 {
		t.Fatalf("fremde Audience: %d", st)
	}

	// Aktionen ohne Recht
	for _, f := range []struct{ pfad string }{{"/computer/102/bildschirm"}, {"/computer/103/bildschirm"}, {"/computer/101/einschalten"}, {"/computer/999/bildschirm"}, {"/computer/abc/bildschirm"}} {
		if st, b := ruf(t, "POST", api+f.pfad, u.tokens["anna"]); st != 403 && st != 400 {
			t.Fatalf("%s haette abgewiesen werden muessen: %d %s", f.pfad, st, b)
		}
	}
	if st, _ := ruf(t, "POST", api+"/computer/104/einschalten", u.tokens["anna"]); st != 200 {
		t.Fatalf("Einschalten 104: %d", st)
	}

	// SPICE: Ticket holen, dann durch den Proxy der App zum Gateway und weiter.
	st, b = ruf(t, "POST", api+"/computer/101/bildschirm", u.tokens["anna"])
	if st != 200 {
		t.Fatalf("Bildschirm 101: %d %s", st, b)
	}
	var z map[string]any
	json.Unmarshal(b, &z)
	if _, da := z["proxy"]; da {
		t.Fatal("proxy darf nicht an die App gehen")
	}
	ziel := z["host"].(string) + ":" + strconv.Itoa(int(z["tls-port"].(float64)))
	spiceConnect := func(ziel string) string {
		c, err := net.Dial("tcp", fmt.Sprintf("127.0.0.1:%d", tun.ProxyPort()))
		if err != nil {
			t.Fatal(err)
		}
		defer c.Close()
		auth := base64.StdEncoding.EncodeToString([]byte("rw:" + tun.ProxyGeheimnis()))
		fmt.Fprintf(c, "CONNECT %s HTTP/1.0\r\nProxy-Authorization: Basic %s\r\n\r\n", ziel, auth)
		c.SetReadDeadline(time.Now().Add(10 * time.Second))
		br := bufio.NewReader(c)
		status, _ := br.ReadString('\n')
		if strings.Contains(status, "200") {
			br.ReadString('\n')
			io.WriteString(c, "REDQ")
			buf := make([]byte, 4)
			io.ReadFull(br, buf)
			return string(buf)
		}
		return strings.TrimSpace(status)
	}
	if e := spiceConnect(ziel); e != "REDQ" {
		t.Fatalf("SPICE ueber Gateway: %q", e)
	}
	if zeile := <-u.spiceIn; zeile != "CONNECT "+ziel+" HTTP/1.0" {
		t.Fatalf("an pve:3128 kam %q", zeile)
	}
	// Selbst ausgedachtes Ticket: nein.
	if e := spiceConnect("pvespiceproxy:GEFAELSCHT:103:pve1:61000"); !strings.Contains(e, "403") {
		t.Fatalf("fremdes SPICE-Ziel: %q", e)
	}

	// Bert (in Proxmox gesperrt) sieht nichts; Annas Token ueber Berts Geraet: 403.
	_, apiBert := u.anmelden("bert", "geraet-bert-1")
	if st, b := ruf(t, "GET", apiBert+"/computer", u.tokens["bert"]); st != 200 || string(bytes.TrimSpace(b)) != "[]" {
		t.Fatalf("gesperrter Benutzer: %d %s", st, b)
	}
	if st, _ := ruf(t, "GET", apiBert+"/computer", u.tokens["anna"]); st != 403 {
		t.Fatalf("fremdes Token ueber Geraet: %d", st)
	}
	// Annas SPICE-Ticket ueber Berts Tunnel: nein (Ticket gehoert Annas Peer).
	// (ueber Berts Proxy geprueft im naechsten Schritt indirekt: Peer-Bindung im Ticket)

	// Hoechstens 2 Geraete je Person (im Test), drittes abgewiesen.
	u.anmelden("anna", "geraet-anna-2")
	priv := func() string { _, p, _ := tunnel.Schluesselpaar(); return p }()
	body, _ := json.Marshal(map[string]string{"geraet": "geraet-anna-3", "schluessel": priv})
	req, _ = http.NewRequest("POST", u.steuer+"/peers", bytes.NewReader(body))
	req.Header.Set("Authorization", "Bearer "+strings.Repeat("s", 40))
	req.Header.Set("X-Rosenweg-Token", u.tokens["anna"])
	if r, _ := http.DefaultClient.Do(req); r.StatusCode != 429 {
		t.Fatalf("drittes Geraet: %d", r.StatusCode)
	}

	// Abmelden entfernt den Peer sofort.
	if st, _ := ruf(t, "POST", api+"/abmelden", u.tokens["anna"]); st != 200 {
		t.Fatalf("abmelden: %d", st)
	}
	time.Sleep(1500 * time.Millisecond)
	if n := u.gw.Anzahl(); n != 2 {
		t.Fatalf("nach Abmelden noch %d Peers (erwartet 2)", n)
	}

	// Absturz: nach 6 Minuten ohne Handshake ist alles weg.
	u.gw.jetzt = func() time.Time { return time.Now().Add(6 * time.Minute) }
	u.gw.Aufraeumen()
	if n := u.gw.Anzahl(); n != 0 {
		t.Fatalf("nach Ablauf noch %d Peers", n)
	}
}
