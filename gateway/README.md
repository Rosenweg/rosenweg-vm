# vm-gateway

Der einzige Weg der App „Rosenweg Virtuelle Computer“ zu Proxmox. Er läuft
auf einem eigenen LXC (Vorschlag: `vm-gateway`, Debian) und ist **nicht**
ausgerollt.

```
App ──WireGuard (UDP 51831)──► vm-gateway ──HTTPS──► pve*:8006   API-Token des Gateways
     im Tunnel nur:                          └──TCP───► pve*:3128   SPICE, nur eigene Tickets
       10.243.43.1:80   Schnittstelle
       10.243.43.1:3128 SPICE
Haupt-API ──HTTP (LAN, Steuer-Token + Token der Person)──► vm-gateway:8080  Peers anlegen/entfernen
```

## Warum so

- **Getrennt von den Wohnungs-VLANs** (Entscheid Stefan): der App-Tunnel
  endet hier, nicht bei wg-control.
- **Kein Weiterleiten, keine Route.** WireGuard endet in einem Netzstapel
  *im Prozess* (wireguard-go + gVisor). Der Container hat keine
  wg-Schnittstelle, und durch den Tunnel erreicht eine App genau zwei Ports
  dieses Dienstes. Das ist die Bauweise, nicht eine Firewall-Regel. Der Dienst
  braucht deshalb keine Sonderrechte (kein CAP_NET_ADMIN, kein `nesting`).
- **Eine Anmeldung.** Die App schickt nur das Authentik-Token
  (`rosenweg-apps`). Der Gateway fragt Proxmox mit seinem eigenen API-Token,
  gibt der Person aber nur, was Proxmox ihrem Benutzer `<name>@authentik`
  erlaubt.

## Sicherheit: der Gateway darf mehr als die Person

Das Token des Gateways sieht alle Computer. Dass nichts durchrutscht, sichern
diese Regeln (alle im Test `gateway_test.go` geprüft):

1. **Zwei Ausweise pro Anfrage:** WireGuard-Absender (Gerät) und
   Token (Person) müssen zur selben Person gehören. Zwei Arten Token:
   - **Authentik** (Rosenweg-Konto im Browser, Kerberos an Stationen): über
     Authentik `userinfo` geprüft, muss für `rosenweg-apps` ausgestellt sein
     (`aud`/`azp`); Proxmox-Benutzer aus `preferred_username`. Eine Minute gemerkt.
   - **`rw_app_…`** (Rosenweg-Karte, Anmelde-QR, „Mit dem Handy anmelden“;
     Website `api/routes/app-karte.js`): Authentik kennt sie nicht. Geprüft
     mit `GET /api/auth/me` der Haupt-API, direkt im LAN (`ROSENWEG_API_ME`,
     Pflicht, z. B. `http://<Haupt-API>:3000/api/auth/me`, in `nftables.conf`
     freigegeben); Proxmox-Benutzer aus
     `user.username` (= Authentik-Benutzername, von der API beim Portal-Login
     übernommen). 30 Sekunden gemerkt, damit ein Entzug schnell greift.
     401/403 der API → „Anmeldung abgelaufen“; API nicht erreichbar → 503
     (die App bleibt angemeldet); ohne Benutzernamen → 403 mit Hinweis
     „einmal mit dem Rosenweg-Konto anmelden“.
   Die Rechte kommen in beiden Fällen gleich aus Proxmox (Punkt 2).
2. **Rechte aus Proxmox, für genau diese Person und diesen Computer:**
   `GET /access/permissions?userid=<person>@authentik&path=/vms/<id>` (und
   `/pool/<pool>`, falls der Computer in einem Pool liegt). Sehen braucht
   `VM.Audit` oder `VM.Console`, Bildschirm braucht `VM.Console`, Einschalten
   braucht `VM.PowerMgmt`. Ist der Proxmox-Benutzer gesperrt oder abgelaufen,
   gibt es nichts. Höchstens 30 Sekunden zwischengespeichert.
3. **Knoten und Computer kommen aus der eigenen Liste**, nie aus der
   Anfrage. Unbekannte und verbotene Nummern sehen gleich aus (403).
4. **SPICE nur mit selbst ausgestelltem Ticket:** Port 3128 lässt nur ein
   `CONNECT`-Ziel durch, das der Gateway kurz vorher für genau diesen Peer
   geholt hat (höchstens 2 Minuten alt). Der Inhalt bleibt TLS zwischen App
   und QEMU; der Gateway sieht keinen Bildschirm.
5. **Token des Gateways minimal:** eigene Rolle `VMGateway` mit `VM.Audit`,
   `VM.Console`, `VM.PowerMgmt` auf `/vms` (bzw. `/`) und `Sys.Audit` auf
   `/access`. Kein `VM.Config.*`, kein `Datastore.*`, kein `Sys.Modify`, kein
   `Permissions.Modify`.
6. **Protokoll pro Aktion** (Journal, eine JSON-Zeile): Liste-Fehler,
   Bildschirm, Einschalten, SPICE-Verbindung, Peer neu/weg, Abweisungen mit
   Grund. Nie Tokens, Tickets oder Schlüssel.
7. **Peers leben nur, solange die App lebt:** App schliessen → `POST
   /abmelden`. Absturz → ohne Handshake nach 3 Minuten bzw. 5 Minuten Stille
   entfernt (App sendet alle 25 s ein Lebenszeichen). Neustart des Dienstes →
   alle Peers weg (der Zustand liegt nur im Speicher), die Apps melden sich neu.
8. **Höchstens 5 Geräte je Person**, 253 gleichzeitig insgesamt.

Restrisiko: Wer das Steuer-Token UND ein gültiges Authentik-Token einer Person
hat, kann für diese Person einen Peer anlegen. Das ist dieselbe Macht, die das
Authentik-Token über die Haupt-API ohnehin gibt.

## Einrichten (nicht gemacht)

1. **CT anlegen:** Debian 13, unprivilegiert, 1 vCPU, 256 MB, eine
   LAN-Adresse im Servernetz. Kein nesting,
   kein TUN-Gerät nötig.
2. **Programm bauen und einspielen:**
   `GOOS=linux GOARCH=amd64 CGO_ENABLED=0 go build -trimpath -o vm-gateway .`,
   dann im CT `./setup.sh vm-gateway`.
3. **Proxmox:** Benutzer `vm-gateway@pve` (ohne Passwort), Rolle `VMGateway`
   (Rechte oben), ACL `/vms` → `vm-gateway@pve` + Token, `/access` →
   `Sys.Audit`. Token `vm-gateway@pve!app` **mit** Rechte-Trennung, dieselben
   ACLs aufs Token. `PVE_TOKEN=vm-gateway@pve!app=<geheimnis>` in
   `/etc/vm-gateway/env`.
   **Zu prüfen:** ob `spiceproxy` mit einem API-Token ein brauchbares
   SPICE-Ticket liefert (der Gateway-Test simuliert Proxmox). Falls nicht:
   im Gateway eine Anmeldung mit Benutzer und Passwort (`/access/ticket`)
   statt Token nachrüsten (kleiner Umbau in `pve.go`).
4. **Netz und Firewall:**
   - Router/UDM: Weiterleitung **UDP 51831** von `kooperation.rosenweg4303.ch`
     auf den CT.
   - Vom CT **hinaus** nur: `pve1..3:8006/tcp`, `pve1..3:3128/tcp`,
     `authentik.rosenweg4303.ch:443/tcp`, DNS. Sonst nichts.
   - **Hinein** nur: `51831/udp` von überall, `8080/tcp` nur vom
     API-Container.
   - Umgesetzt mit nftables **im CT** (`nftables.conf`), nicht mit der
     Proxmox-Firewall; siehe Abschnitt „Firewall“.
   - pve-Knoten: 8006 und 3128 vom CT erlauben (falls die Proxmox-Firewall
     dort filtert).
   - Kein Wohnungs-VLAN braucht Zugang zum CT; der Tunnel ersetzt das.
5. **Haupt-API:** `ROSENWEG_API_ME=http://<Haupt-API>:3000/api/auth/me` in
   `/etc/vm-gateway/env` (Pflicht, ohne startet der Dienst nicht);
   `VM_GATEWAY_URL=http://<CT-Adresse>:8080` und
   `VM_GATEWAY_TOKEN=<GW_STEUER_TOKEN>` in `/opt/rosenweg-core/.env`.
6. `GW_ENDPOINT_INTERN=<CT-Adresse>:51831` setzen: im Haus verbindet die App
   direkt dorthin, ohne Umweg über die öffentliche Adresse.

## Firewall

`nftables.conf` (dieses Verzeichnis) ist im Gateway-CT als `/etc/nftables.conf`
eingespielt, `nftables.service` ist aktiv und beim Start eingeschaltet. nft
geht im unprivilegierten CT ohne Sonderrechte (eigener Netz-Namensraum).
Die Proxmox-Datacenter-Firewall bleibt aus.

Die Adressen des Hauses stehen **nicht** im Repo (öffentlich), sondern im CT in
`/etc/vm-gateway/nft-adressen.conf`; `nftables.conf` holt sie mit `include`.
Vorlage mit Beispieladressen aus den Doku-Bereichen (`192.0.2.x`,
`2001:db8::`): `nft-adressen.beispiel.conf` (legt `setup.sh` beim ersten Mal
an). **Erst diese Datei anlegen, dann die neue `nftables.conf` einspielen:**
fehlt sie, lädt nft gar nichts, und nach einem Neustart des CT wäre keine
Regel aktiv.

| Richtung | Erlaubt | Sonst |
|---|---|---|
| hinein | `lo`; Rückweg (established/related); `51831/udp` von überall; `8080/tcp` nur von `$API` (Haupt-API); ICMPv6-Nachbarschaft/Router-Anzeigen, Ping | verworfen (drop), Protokoll `vmgw-ein-weg:` (5/min) |
| hinaus | `lo`; Rückweg; UDP **vom** Port 51831 (WireGuard zu den Apps); DNS `$DNS:53` udp/tcp; `$PVE4`/`$PVE6` (pve1..3) auf `8006`, `3128`; Authentik `$AUTH4`/`$AUTH6` auf `443`; `$API:3000` (`/api/auth/me`); ICMPv6-Nachbarschaft | abgewiesen (reject, schnelle Fehlermeldung), Protokoll `vmgw-aus-weg:` (5/min) |
| weiter | nichts | drop |

Die Adressen sind feste A/AAAA von `pve1..3` und `authentik.rosenweg4303.ch`
(nft löst keine Namen auf). Ändert sich eine, `/etc/vm-gateway/nft-adressen.conf`
anpassen und `systemctl reload nftables`.

Einspielen bzw. ändern (im CT):

```bash
test -f /etc/vm-gateway/nft-adressen.conf || install -m 0644 nft-adressen.beispiel.conf /etc/vm-gateway/nft-adressen.conf   # dann echte Adressen eintragen
install -m 0644 nftables.conf /etc/nftables.conf
nft -c -f /etc/nftables.conf && systemctl enable --now nftables && systemctl reload nftables
nft list chain inet vmgw ein          # Zähler: 51831, 8080, verworfen
journalctl -k | grep vmgw-            # was abgewiesen wurde
```

**Paket-Updates:** apt (deb.debian.org, security.debian.org) ist hinaus
gesperrt, `unattended-upgrades`/`apt-daily` laufen deshalb ins Leere. Zum
Aktualisieren kurz öffnen und wieder schliessen:

```bash
nft insert rule inet vmgw aus "tcp dport { 80, 443 } accept"
apt update && apt full-upgrade
systemctl reload nftables             # Datei neu laden = Ausnahme weg
```

Geprüft am 26.11.2026 (vorher/nachher): Dienst läuft, `/gesundheit` vom
API-Container ok, pve1..3 `8006`/`3128` offen, Authentik `userinfo` antwortet
(401 ohne Token), DNS geht; zu sind pve `22`, Authentik `22`, `1.1.1.1:443`,
`deb.debian.org:80`; von einem Knoten aus sind CT-Ports `8080` und `22` zu,
`51831/udp` kommt an (Zähler).

## Prüfen

```bash
systemctl is-active vm-gateway
curl -s http://<CT-Adresse>:8080/gesundheit     # {"ok":true,"peers":N}
journalctl -u vm-gateway -o cat | tail          # JSON-Zeilen pro Aktion
```

## Entwickeln

`go test .` startet Gateway, nachgebautes Authentik und Proxmox sowie die
App-Seite des Tunnels (`native/rwtunnel`) mit echtem WireGuard-Handshake.
