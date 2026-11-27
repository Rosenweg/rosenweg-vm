<p align="center"><img src="assets/logo/rosenweg-vm-512.png" width="96" alt="Logo"></p>
<h1 align="center">Rosenweg Virtuelle Computer</h1>
<p align="center">Die eigenen virtuellen Computer des Rosenwegs öffnen – mit Ton und USB, im Haus und unterwegs.</p>
<p align="center"><a href="https://www.rosenweg4303.ch/apps">Herunterladen</a> · <a href="docs/anleitung.md">Anleitung</a></p>

## Inhalt

- [Überblick](#überblick)
- [Plattformen](#plattformen)
- [Rechte](#rechte)
- [Bedienung](#bedienung)
- [Ablauf und Architektur](#ablauf-und-architektur)
- [vm-gateway](#vm-gateway)
- [Aufbau](#aufbau)
- [Bauen und testen](#bauen-und-testen)
- [CI und Release](#ci-und-release)
- [Einrichtung ausserhalb der App](#einrichtung-ausserhalb-der-app)
- [Konfiguration](#konfiguration)
- [Lizenz](#lizenz)

## Überblick

Eine App für Linux, macOS, Windows, Android und iOS: einmal mit dem Rosenweg-Konto anmelden, die eigenen virtuellen Computer aus dem Proxmox-Cluster sehen, antippen – der Bildschirm (SPICE) erscheint mit Ton und USB direkt in der App.

Was die App kann:

- **Eine Anmeldung:** nur das Rosenweg-Konto, danach 30 Tage still beim Start.
- **Meine Computer:** zeigt nur die Computer, die Proxmox der Person erlaubt.
- **Bildschirm:** Bild, Maus, Tastatur (Schweizer Belegung macht der Gast), Ton, Mikrofon auf Wunsch.
- **USB:** Geräte einzeln per Schalter durchreichen, nie automatisch.
- **Im Haus und unterwegs gleich:** eigener Tunnel im Prozess, ohne VPN-Dialog und ohne Systemrechte.
- **Stationen:** ersetzt dort das Programm „Maschinen“ (os-stationen spielt das Paket `rosenweg-vm` ein und lässt „Maschinen“ als Rückfall stehen).

## Plattformen

| Plattform | Stand | Bezug |
|---|---|---|
| Linux (Debian 13, amd64) | Paket `rosenweg-vm` (.deb) gebaut | Stationen: über os-stationen; sonst [rosenweg4303.ch/apps](https://www.rosenweg4303.ch/apps) |
| macOS (arm64, ab macOS 26) | DMG gebaut, ad hoc signiert | [rosenweg4303.ch/apps](https://www.rosenweg4303.ch/apps) |
| Windows | noch nicht gebaut (Plan: spice-glib aus MSYS2, USB über UsbDk) | – |
| Android | Tunnel baut; SPICE-Stapel fürs NDK fehlt noch | – |
| iOS / iPadOS | Tunnel baut; ohne USB (iOS erlaubt es nicht) | – |

| | Linux | Windows | macOS | Android | iOS |
|---|---|---|---|---|---|
| Ton | PipeWire/Pulse/ALSA | WASAPI | CoreAudio | AAudio/OpenSL | CoreAudio |
| USB | ja (Rechte über udev) | ja (UsbDk) | nur Geräte ohne Systemtreiber | ja (USB-Host) | nein |
| Anmeldung | localhost | localhost | localhost | eigenes Schema | eigenes Schema |

Mehr: [docs/plattformen.md](docs/plattformen.md) – Stand, Aufwand, Signatur und Eigenheiten je Plattform.

## Rechte

Die App entscheidet nichts selbst. Der vm-gateway fragt Proxmox **für die angemeldete Person** (`<person>@authentik`) und den einzelnen Computer.

| Proxmox-Recht der Person | erlaubt in der App |
|---|---|
| `VM.Audit` | Computer in der Liste sehen |
| `VM.Console` | Bildschirm öffnen |
| `VM.PowerMgmt` | ausgeschalteten Computer einschalten |

Weitere Grenzen: höchstens 5 Geräte je Person; der Benutzername in Authentik (`preferred_username`) muss dem im Proxmox-Realm `authentik` entsprechen.

## Bedienung

| Was | So geht’s |
|---|---|
| Anmelden | „Mit Rosenweg-Konto anmelden“; danach still, bis die letzte Browser-Anmeldung 30 Tage her ist |
| Computer öffnen | in „Meine Computer“ antippen |
| Ausgeschalteter Computer | antippen → „einschalten?“ |
| Wo bin ich | Chip oben rechts: „Im Haus“ oder „Unterwegs · sicher verbunden“ |
| Im Bildschirm | Leiste mit Ton, Mikrofon, USB, Strg+Alt+Entf |
| Ordner statt USB-Stick | „Ordner freigeben“ (SPICE-WebDAV, im Gast `spice-webdavd` bzw. SPICE Guest Tools) |

Das Mikrofon ist aus, bis man es einschaltet – ein Gast kann nicht ungefragt mithören. Unter macOS bietet die App USB-Geräte mit Systemtreiber (Stick, Tastatur, Maus) gar nicht an.

Mehr: [docs/anleitung.md](docs/anleitung.md).

## Ablauf und Architektur

```
Start ─► Rosenweg-Konto (Authentik rosenweg-apps, PKCE)
              ▼
         POST /api/apps/tunnel (Haupt-API, nur öffentlicher Schlüssel)
              ▼
         WireGuard im Prozess der App ──► vm-gateway
         im Haus: LAN-Endpunkt · unterwegs: öffentlicher Endpunkt
              ▼
         Gateway prüft Token + Gerät, fragt Proxmox,
         gibt nur, was Proxmox der Person erlaubt
              ▼
         „Meine Computer“ ─► SPICE durch den Gateway
              ▼
         librwspice (spice-client-glib) ─► Bild, Maus, Tastatur, Ton, USB
App zu ─► Peer abgemeldet; Absturz ─► Gateway räumt nach 3–5 Min auf
```

Die wichtigsten Entscheide:

| Thema | Entscheid |
|---|---|
| SPICE | Referenzbibliothek spice-client-glib, dynamisch gelinkt, hinter einer kleinen C-Schicht (`native/rwspice`, 15 Funktionen) |
| Bild | BGRA-Puffer in C, in Dart als `ui.Image`; später eine Texture je Plattform |
| Ton | spice-glib dekodiert, miniaudio spielt ab – kein GStreamer nötig |
| USB | spice-glib UsbDeviceManager, `auto-connect` aus |
| Netz | App spricht nie direkt mit Proxmox, nur mit dem eigenen vm-gateway; WireGuard läuft auf beiden Seiten im Prozess |
| Im Haus? | TXT-Eintrag `location.rosenweg4303.ch` beim Resolver des Geräts; nur Wegwahl, nie Sicherheit (entscheidet der WireGuard-Handshake) |
| Anmeldung | nur das Rosenweg-Konto; Tunnel-Schlüssel pro Start neu, nur im Speicher |
| Tastatur | die App schickt Scancodes, die Belegung macht der Gast |

Mehr: [docs/architektur.md](docs/architektur.md).

## vm-gateway

Der einzige Weg der App zu Proxmox: ein eigener Container, getrennt von den Wohnungs-VLANs. Der App-Tunnel endet dort in einem Netzstapel im Prozess (wireguard-go + gVisor) – ohne wg-Schnittstelle, ohne Weiterleiten. Durch den Tunnel erreicht eine App genau zwei Ports: die Schnittstelle und SPICE.

Sicherheitsregeln (alle im Test `gateway_test.go` geprüft):

| Regel | Inhalt |
|---|---|
| Zwei Ausweise | WireGuard-Absender (Gerät) und Authentik-Token (Person) müssen zusammengehören |
| Rechte aus Proxmox | je Person und Computer, höchstens 30 s zwischengespeichert |
| Eigene Liste | Knoten und Computer nie aus der Anfrage; Unbekanntes und Verbotenes sehen gleich aus (403) |
| SPICE nur mit eigenem Ticket | nur ein Ziel, das der Gateway kurz vorher für genau diesen Peer geholt hat |
| Minimales Token | Rolle `VMGateway`: `VM.Audit`, `VM.Console`, `VM.PowerMgmt`, `Sys.Audit` – sonst nichts |
| Protokoll | eine JSON-Zeile pro Aktion im Journal, nie Tokens oder Schlüssel |
| Kurzlebige Peers | App zu → abgemeldet; Absturz → nach 3 bzw. 5 Minuten weg |

Die Firewall im Container (nftables) lässt hinein nur den WireGuard-Port und die Steuerung von der Haupt-API zu, hinaus nur Proxmox, Authentik und DNS.

Mehr: [gateway/README.md](gateway/README.md) – Einrichten, Firewall, Prüfen.

## Aufbau

| Ordner | Was | Sprache |
|---|---|---|
| `lib/` | App: Ablauf, Oberfläche, Anmeldung, Gateway-Client, FFI | Dart/Flutter |
| `native/rwspice/` | dünne C-Schicht über spice-client-glib (Bild, Eingaben, Ton über miniaudio, USB) | C |
| `native/rwtunnel/` | WireGuard im Prozess, lokaler CONNECT-Proxy und Weiterleitung | Go |
| `gateway/` | vm-gateway: Tunnel-Ende, Rechteprüfung, Proxmox, SPICE-Weiterreichung; Unit, Setup | Go |
| `integration_test/` | Ende-zu-Ende gegen einen lokalen SPICE-Testserver | Dart |
| `linux/paket/` | Debian-Paket `rosenweg-vm` (`bauen.sh`, Bau im Container) | Shell |
| `macos/installer/` | Release-App und DMG (`bauen.sh`) | Shell/Python |
| `assets/logo/` | Logo (Turm, Weg und Rose mit Monitor, aus dem Baukasten von rosenweg-basis), `erzeugen.sh` | SVG |
| `.github/workflows/` | `linux.yml`, `macos.yml` | |
| `docs/` | Entscheide, Plattformen, Einrichtung, Entwicklung, CI, Anleitung | |

## Bauen und testen

Entwickelt wird auf macOS: Flutter (stable), Xcode, MacPorts mit `spice-gtk`; Go wird lokal nach `.werkzeuge/go` geladen.

```bash
native/rwtunnel/bauen.sh macos      # librwtunnel.dylib
native/rwspice/bauen.sh macos       # librwspice.dylib gegen /opt/local
flutter run -d macos --dart-define=RW_NATIVE_DIR=$PWD/native
```

| Ziel | Befehl |
|---|---|
| Tunnel testen | `(cd native/rwtunnel && go test ./tunnel/)` |
| Gateway Ende zu Ende | `(cd gateway && go test .)` |
| Ganze App gegen SPICE-Testserver | `flutter test integration_test -d macos --dart-define=RW_TEST_SPICE=127.0.0.1:5912 …` |
| Debian-Paket | `linux/paket/bauen.sh` (nur auf Debian 13/amd64) oder `linux/paket/im-container.sh` |
| macOS-DMG | `macos/installer/bauen.sh` → `build/macos-installer/` |
| Tastaturbelegungen der Gäste | `python3 tool/belegungen_erzeugen.py` |

Mehr: [docs/entwicklung.md](docs/entwicklung.md).

## CI und Release

| Workflow | Runner | Ergebnis |
|---|---|---|
| `linux.yml` | eigener Runner, Gruppe `rosenweg-privat` | Go-Tests, `flutter analyze`/`test`, Linux-Bündel, `.deb`, vm-gateway |
| `macos.yml` | GitHub-Runner `macos-26`, nur bei Tags oder von Hand | DMG |

**Neue Version:** `version` in `pubspec.yaml` anheben, Tag `v<version>` pushen (z. B. `v1.0.1`). Beide Workflows legen ihr Paket ins GitHub-Release und schicken es an **[rosenweg4303.ch/apps](https://www.rosenweg4303.ch/apps)** (Anmeldung per GitHub-OIDC, kein gespeichertes Geheimnis).

Go 1.27.4 und Flutter 3.47.5 lädt der Linux-Lauf mit fester Prüfsumme in einen Cache, nichts systemweit. Fehlen Systempakete, bricht er mit der Liste ab. Ein Windows-Runner ist geplant.

Mehr: [docs/ci.md](docs/ci.md).

## Einrichtung ausserhalb der App

| Wo | Was |
|---|---|
| Authentik | Anwendung `rosenweg-apps`: Rücksprung `^http://localhost:[0-9]+/anmeldung$` (Regex) und `ch.rosenweg4303.vm:/anmeldung` (strikt); Refresh-Token mindestens 30 Tage |
| vm-gateway | eigener Container (Debian 13, unprivilegiert), `setup.sh`, Proxmox-Benutzer `vm-gateway@pve` mit Rolle `VMGateway` und Token mit Rechte-Trennung, UDP-Weiterleitung am Router |
| Interner DNS | TXT `location.rosenweg4303.ch` = `Rosenweg GBT`, nur intern |
| Haupt-API (Rosenweg/Website) | `POST /api/apps/tunnel`, `DELETE /api/apps/tunnel/:geraet` |
| Proxmox je Computer | Anzeige SPICE (`vga: qxl`), Ton `ich9-intel-hda,driver=spice`, `usb0: spice`; im Gast `spice-vdagent` bzw. SPICE Guest Tools |
| GitHub | Repo in die Runner-Gruppe `rosenweg-privat` |

Mehr: [docs/authentik-und-server.md](docs/authentik-und-server.md).

## Konfiguration

Nur Namen, nie Werte.

| Wo | Variablen |
|---|---|
| vm-gateway (`/etc/vm-gateway/env`) | `PVE_TOKEN`, `PVE_HOSTS`, `PVE_REALM`, `PVE_CA`, `PVE_SPICE_PORT`, `PVE_BENUTZER_CLAIM`, `AUTHENTIK_USERINFO`, `GW_STEUER_TOKEN`, `GW_STEUER_BIND`, `GW_ENDPOINT_INTERN`, `GW_ENDPOINT_EXTERN`, `GW_WG_PORT`, `GW_NETZ`, `GW_SCHLUESSEL`, `GW_MAX_JE_PERSON`, `GW_OHNE_HANDSHAKE`, `GW_STILL` |
| Haupt-API | `VM_GATEWAY_URL`, `VM_GATEWAY_TOKEN` |
| GitHub-Secrets (macOS, optional, nicht angelegt) | `MACOS_ZERTIFIKAT_P12`, `MACOS_ZERTIFIKAT_PASSWORT`, `NOTAR_KEY_P8`, `NOTAR_KEY_ID`, `NOTAR_ISSUER` – ohne sie ist das DMG ad hoc signiert |
| Bau macOS (lokal) | `RW_SIGNIER_ID`, `RW_NOTAR_PROFIL` bzw. `RW_NOTAR_KEY`, `RW_NOTAR_KEY_ID`, `RW_NOTAR_ISSUER` |
| Entwicklung | `--dart-define=RW_NATIVE_DIR=…`, `--dart-define=RW_TEST_SPICE=…` (Testcomputer ohne Anmeldung) |

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Fremdbibliotheken (spice-glib, GLib, usbredir, libusb unter LGPL, dynamisch gelinkt; miniaudio, wireguard-go, gVisor) in [LIZENZEN.md](LIZENZEN.md).
