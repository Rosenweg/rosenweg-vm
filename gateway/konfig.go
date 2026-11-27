// SPDX-License-Identifier: GPL-3.0-or-later

package main

import (
	"errors"
	"fmt"
	"net/netip"
	"os"
	"strconv"
	"strings"
	"time"
)

// Konfig kommt aus der Umgebung (systemd: EnvironmentFile=/etc/vm-gateway/env).
// Geheim sind nur GW_STEUER_TOKEN und PVE_TOKEN; die Datei ist 0600.
type Konfig struct {
	WgPort         int          // GW_WG_PORT, UDP, Standard 51831
	EndpointExtern string       // GW_ENDPOINT_EXTERN, z. B. kooperation.rosenweg4303.ch:51831
	EndpointIntern string       // GW_ENDPOINT_INTERN, z. B. 100.64.2.36:51831 (im Haus)
	Netz           netip.Prefix // GW_NETZ, nur im Tunnel, Standard 10.243.43.0/24
	SteuerBind     string       // GW_STEUER_BIND, LAN-Adresse fuer die Haupt-API, z. B. 100.64.2.36:8080
	SteuerToken    string       // GW_STEUER_TOKEN
	Schluessel     string       // GW_SCHLUESSEL, privater Server-Schluessel (wird angelegt)

	Userinfo string // AUTHENTIK_USERINFO
	ClientID string // APPS_CLIENT_ID, Standard rosenweg-apps
	// ROSENWEG_API_ME, Standard http://100.64.2.52:3000/api/auth/me (Haupt-API, CT 128,
	// direkt im LAN wie die Steuerung; nftables.conf laesst nur dorthin): prueft die
	// Karten-, QR- und Handy-Anmeldungen der Apps (rw_app_…), die Authentik nicht kennt.
	APIMe string

	PVEHosts      []string // PVE_HOSTS, kommagetrennt, host[:port], Standard-Port 8006
	PVESpicePort  int      // PVE_SPICE_PORT, Standard 3128
	PVEToken      string   // PVE_TOKEN, "vm-gateway@pve!app=<geheimnis>"
	PVECA         string   // PVE_CA, optional: CA-Datei, sonst Systemvorrat
	PVERealm      string   // PVE_REALM, Standard authentik
	BenutzerClaim string   // PVE_BENUTZER_CLAIM, Standard preferred_username

	OhneHandshake time.Duration // GW_OHNE_HANDSHAKE, Standard 3m
	Still         time.Duration // GW_STILL, Standard 5m
	MaxJePerson   int           // GW_MAX_JE_PERSON, Standard 5
}

func umgebung(name, standard string) string {
	if v := strings.TrimSpace(os.Getenv(name)); v != "" {
		return v
	}
	return standard
}

func KonfigLesen() (Konfig, error) {
	var k Konfig
	var err error
	if k.WgPort, err = strconv.Atoi(umgebung("GW_WG_PORT", "51831")); err != nil {
		return k, fmt.Errorf("GW_WG_PORT: %w", err)
	}
	k.EndpointExtern = umgebung("GW_ENDPOINT_EXTERN", "")
	k.EndpointIntern = umgebung("GW_ENDPOINT_INTERN", "")
	if k.Netz, err = netip.ParsePrefix(umgebung("GW_NETZ", "10.243.43.0/24")); err != nil {
		return k, fmt.Errorf("GW_NETZ: %w", err)
	}
	k.SteuerBind = umgebung("GW_STEUER_BIND", "")
	k.SteuerToken = umgebung("GW_STEUER_TOKEN", "")
	k.Schluessel = umgebung("GW_SCHLUESSEL", "/var/lib/vm-gateway/server.key")
	k.Userinfo = umgebung("AUTHENTIK_USERINFO", "https://authentik.rosenweg4303.ch/application/o/userinfo/")
	k.ClientID = umgebung("APPS_CLIENT_ID", "rosenweg-apps")
	k.APIMe = umgebung("ROSENWEG_API_ME", "http://100.64.2.52:3000/api/auth/me")
	for _, h := range strings.Split(umgebung("PVE_HOSTS", "pve1.rosenweg4303.ch,pve2.rosenweg4303.ch,pve3.rosenweg4303.ch"), ",") {
		if h = strings.TrimSpace(h); h != "" {
			k.PVEHosts = append(k.PVEHosts, h)
		}
	}
	if k.PVESpicePort, err = strconv.Atoi(umgebung("PVE_SPICE_PORT", "3128")); err != nil {
		return k, fmt.Errorf("PVE_SPICE_PORT: %w", err)
	}
	k.PVEToken = umgebung("PVE_TOKEN", "")
	k.PVECA = umgebung("PVE_CA", "")
	k.PVERealm = umgebung("PVE_REALM", "authentik")
	k.BenutzerClaim = umgebung("PVE_BENUTZER_CLAIM", "preferred_username")
	if k.OhneHandshake, err = time.ParseDuration(umgebung("GW_OHNE_HANDSHAKE", "3m")); err != nil {
		return k, err
	}
	if k.Still, err = time.ParseDuration(umgebung("GW_STILL", "5m")); err != nil {
		return k, err
	}
	if k.MaxJePerson, err = strconv.Atoi(umgebung("GW_MAX_JE_PERSON", "5")); err != nil {
		return k, err
	}

	// Ohne diese Angaben startet der Dienst nicht — lieber laut scheitern als
	// mit einer halben Konfiguration offen herumstehen.
	switch {
	case k.EndpointExtern == "":
		return k, errors.New("GW_ENDPOINT_EXTERN fehlt")
	case k.SteuerBind == "":
		return k, errors.New("GW_STEUER_BIND fehlt (LAN-Adresse, nicht 0.0.0.0)")
	case len(k.SteuerToken) < 32:
		return k, errors.New("GW_STEUER_TOKEN fehlt oder ist kuerzer als 32 Zeichen")
	case !strings.Contains(k.PVEToken, "!") || !strings.Contains(k.PVEToken, "="):
		return k, errors.New("PVE_TOKEN fehlt (Form benutzer@realm!name=geheimnis)")
	case len(k.PVEHosts) == 0:
		return k, errors.New("PVE_HOSTS fehlt")
	}
	return k, nil
}
