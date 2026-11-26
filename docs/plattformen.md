# Plattformen: SPICE, Tunnel, Ton, USB

Stand 25.11.2026. Aufwand grob in Personentagen (PT), ohne Store-Verfahren.

## Übersicht

| | Linux (Stationen) | Windows | macOS | Android | iOS/iPadOS |
|---|---|---|---|---|---|
| spice-glib | Debian-Paket | MSYS2 (mingw64) | MacPorts (Entw.), eigener Bau (Auslieferung) | eigener Bau (NDK) | eigener Bau (Xcode) |
| rwtunnel (Go) | c-shared | c-shared (mingw) | ✓ gebaut | ✓ gebaut (arm64, x86_64) | ✓ gebaut (c-archive) |
| Ton | PipeWire/Pulse/ALSA | WASAPI | ✓ CoreAudio (Wiedergabe getestet) | AAudio/OpenSL | CoreAudio + AVAudioSession |
| Mikrofon | keine Rechte | Datenschutz-Einstellung | Erlaubnis-Dialog | RECORD_AUDIO | Erlaubnis-Dialog |
| USB | ja (Rechte nötig) | ja (UsbDk-Treiber) | eingeschränkt | ja (Android-USB-Host) | **nein** |
| Anmeldung (einmal, 30 Tage) | localhost | localhost | localhost | eigenes Schema | eigenes Schema |
| DNS-Server für „im Haus“ | resolv.conf | PowerShell/ipconfig | resolv.conf/scutil | LinkProperties (Kanal) | offen (libresolv) |
| Stand | **.deb gebaut** (CT 141, 26.11.2026), Start unter Xvfb bis zur Anmeldung | nicht gebaut | **läuft** | Tunnel baut | Tunnel baut |

## Linux (zuerst, Stationen; Debian 13)

- **SPICE:** `libspice-client-glib-2.0-8` aus Debian (Bau:
  `libspice-client-glib-2.0-dev`). `native/rwspice/bauen.sh linux`. Die GTK-
  Hauptschleife von Flutter dreht den GLib-Kontext; rwspice startet keinen
  eigenen Thread.
- **Ton:** miniaudio wählt PipeWire/PulseAudio/ALSA selbst; keine Rechte.
- **USB:** spice-glib braucht Schreibrecht auf `/dev/bus/usb/*`. Zwei Wege:
  Debian-Paket `spice-client-glib-usb-acl-helper` (polkit fragt bzw. erlaubt
  aktiven Sitzungen) oder eine udev-Regel in der Stationsrolle, die der
  angemeldeten Sitzung (`uaccess`) die Geräte gibt. Auf Stationen: Regel.
- **Tunnel:** auch im Haus, dann zum LAN-Endpunkt des Gateways (kein
  Umweg ins Internet); ohne Rechte, im Prozess.
- **Einbindung:** `linux/CMakeLists.txt` legt `librwspice.so` und
  `librwtunnel.so` nach `lib/` im Bündel.
- **Debian-Paket `rosenweg-vm`** (`linux/paket/bauen.sh`, im Bau-Container
  `linux/paket/im-container.sh`): Bündel unter `/opt/rosenweg-vm`, Start
  `/usr/bin/rosenweg-vm`, Starter `ch.rosenweg4303.vm.desktop` (= GTK-
  Anwendungskennung, damit Leiste und Fenster zusammenfinden), Symbol
  `rosenweg-vm` in hicolor 16–512 px und als SVG. `Depends` rechnet
  `dpkg-shlibdeps` aus (u. a. `libspice-client-glib-2.0-8`, `libgtk-3-0t64`,
  `libsecret-1-0`); nichts davon liegt im Paket (LGPL, Updates über apt).
  Version aus `pubspec.yaml`: `1.0.0+1` → `1.0.0-1`. Für ein neues Paket die
  Baunummer anheben. Gebaut wird nur auf Debian 13/amd64, sonst stimmen die
  Paketnamen (t64) nicht. Das Paket ist lintian-sauber; was zur Art des
  Pakets gehört (/opt, Flutter-Engine), steht begründet in den Overrides.
- **Stationen:** os-stationen holt das .deb mit Prüfsumme vom PXE-Server
  (`pakete/rosenweg-vm/`) und ersetzt damit das Programm „Maschinen“
  (`roles/desktop/parts/85-vm-konsolen.sh`). Die udev-Regel für USB setzt die
  Rolle, nicht das Paket.
- **Schlüsselbund:** `flutter_secure_storage` braucht unter Linux einen
  Secret-Service-Dienst (gnome-keyring, KeePassXC). Die Stationen haben keinen.
  Fehlt er, behält die App ihre Werte nur bis Programmende. Die stille
  Anmeldung über die Browser-Sitzung (30 Tage) geht trotzdem, nur die
  Geräte-Kennung ist bei jedem Start neu.
- **Aufwand:** 3–5 PT (Bau auf Debian, Paket, Texture, udev, Test mit echter VM).

## Windows

- **SPICE:** MSYS2 `mingw-w64-x86_64-spice-gtk` liefert spice-glib mit usbredir
  und allen Abhängigkeiten als DLLs (so baut auch virt-viewer für Windows).
  rwspice mit mingw-gcc als DLL (reines C-ABI, passt zum MSVC-gebauten Runner).
  Alle DLLs neben die .exe (LGPL: dynamisch, austauschbar).
- **Ton/Mikrofon:** WASAPI über miniaudio; Mikrofon braucht die Freigabe in
  den Windows-Datenschutzeinstellungen (Apps dürfen auf das Mikrofon zugreifen).
- **USB:** spice-glib nutzt unter Windows libusb mit **UsbDk** (Red Hat,
  Apache-2.0), wie virt-viewer. UsbDk ist ein Treiber und braucht **einmal
  Administratorrechte** zur Installation (MSI); danach keine Rechte mehr.
- **Tunnel:** Go als DLL über mingw (`bauen.sh windows`). Kein wintun, kein Dienst.
- **Aufwand:** 5–8 PT (Stapel, Bündeln, UsbDk-Installer, Test).

## macOS

- **Entwicklung (läuft):** spice-glib aus MacPorts (`/opt/local`), Debug-Bau
  ohne Sandbox, `--dart-define=RW_NATIVE_DIR=…/native`.
- **Auslieferung:** Bibliotheken nach `Contents/Frameworks` bündeln
  (Installationsnamen auf `@rpath` umschreiben, jede signieren), Sandbox an
  (`Release.entitlements`: network.client/server, audio-input, usb),
  notarisieren. Eigener Bau des Stapels statt MacPorts, siehe iOS (UTM).
- **USB:** libusb kann unter macOS Geräte, die ein Systemtreiber hält
  (Tastatur, Maus, USB-Stick), nicht übernehmen — dafür bräuchte es root oder
  die Apple-Berechtigung `com.apple.vm.device-access` (nur auf Antrag).
  Herstellereigene Geräte ohne Systemtreiber (Dongles, manche Seriell-Adapter,
  Messgeräte) gehen.
  **Die App bietet solche Geräte deshalb gar nicht an** (Test 26.11.2026:
  ein Versuch mit einem USB-Stick setzte ihn zurück, macOS meldete „nicht
  korrekt ausgeworfen“). Erkannt an den zwischengespeicherten Deskriptoren,
  ohne das Gerät zu öffnen: Interface-Klasse Massenspeicher, HID, Audio,
  CDC/Daten, Video, Hub, Funk. Sie stehen grau im USB-Menü mit dem Hinweis
  auf „Ordner freigeben“. Unter Windows und Linux bleibt alles wie gehabt.
- **Aufwand:** 3–5 PT (Bündeln, Signieren, Notarisieren).

## Android

- **SPICE:** der grösste Brocken. Für das NDK zu bauen: GLib (+ libffi, pcre2,
  libiconv, gettext), OpenSSL, pixman, opus, libjpeg-turbo, json-glib, libusb,
  usbredir, spice-glib (spice-gtk mit `-Dgtk=disabled`, ohne GStreamer).
  Vorbild: aSPICE/bVNC (iiordanov/remote-desktop-clients) baut genau diesen
  Stapel mit cerbero (GStreamer-SDK-Bauwerkzeug) für Android. Deren Skripte
  nur als Vorlage lesen (bVNC ist GPL-3, die App soll nicht GPL werden).
  Alternative Abkürzung: die offiziellen GStreamer-Android-Binärpakete
  enthalten GLib, OpenSSL, opus, jpeg (LGPL) — darauf nur libusb, usbredir und
  spice-glib selbst bauen.
- **Ton:** AAudio/OpenSL ES über miniaudio. Mikrofon: Laufzeit-Erlaubnis
  `RECORD_AUDIO`.
- **USB:** Android-USB-Host: `UsbManager.requestPermission` (Dialog je Gerät)
  → Dateideskriptor → `libusb_wrap_sys_device` (libusb ≥ 1.0.23, Option
  `LIBUSB_OPTION_NO_DEVICE_DISCOVERY`). spice-glib zählt Geräte selbst auf;
  für Android braucht es eine kleine Ergänzung in `usb-backend.c`
  („Gerät aus Deskriptor“), wie aSPICE sie hat — vor dem Bau dort prüfen.
- **Tunnel:** ✓ `librwtunnel.so` (arm64-v8a, x86_64) gebaut. Kein VpnService,
  kein VPN-Dialog; der Tunnel lebt nur, solange die App läuft.
- **Anmeldung:** Custom Tab + Schema `ch.rosenweg4303.vm:/anmeldung`
  (z. B. mit `flutter_web_auth_2`); keine zweite Anmeldung für Proxmox.
- **Aufwand:** 8–15 PT Stapel, 3–5 PT Anmeldung/USB/Erlaubnisse/Touch-Bedienung.

## iOS / iPadOS (zuletzt)

- **SPICE:** Vorbild **UTM** (Apache-2.0): baut GLib, spice-gtk (spice-glib),
  usbredir, libusb, OpenSSL für iOS und macOS mit eigenen Skripten
  (`scripts/build_dependencies.sh`). LGPL auf iOS: als dynamische Frameworks
  einbetten, damit sie austauschbar bleiben.
- **Ton:** CoreAudio über miniaudio; `AVAudioSession` Kategorie playAndRecord
  nur, wenn das Mikrofon an ist. Erlaubnis `NSMicrophoneUsageDescription`
  (eingetragen).
- **USB:** **geht nicht.** iOS gibt Apps keinen Zugriff auf beliebige
  USB-Geräte (nur MFi-Zubehör über ExternalAccessory; DriverKit auf iPadOS
  braucht Apple-Berechtigungen und ist für diesen Zweck nicht vorgesehen).
  Die USB-Taste wird dort ausgeblendet.
- **Tunnel:** ✓ `librwtunnel.a` gebaut. Läuft im Vordergrund ohne Network
  Extension; geht die App in den Hintergrund, endet die Sitzung ohnehin.
- **Aufwand:** 8–12 PT (mit UTM-Skripten als Vorlage), dazu Apple-Verteilung.

## Ordner freigeben (SPICE WebDAV)

Statt USB-Sticks durchzureichen: Knopf „Ordner freigeben“ in der
Bildschirmleiste, Ordner wählen (am Mac auch ein Stick unter `/Volumes`),
optional „nur lesen“. spice-glib setzt `shared-dir`/`share-dir-ro` und öffnet
den WebDAV-Kanal; der Ordner lebt nur für diese Sitzung.

- **Gast Linux:** Paket `spice-webdavd`; im Dateimanager erscheint „Spice
  client folder“ (bzw. `dav://localhost:9843/`).
- **Gast Windows:** in den SPICE Guest Tools („Spice webdav proxy“), danach
  als Netzlaufwerk.
- **Ohne WebDAV-Kanal** (spice-webdavd fehlt): Knopf grau, Hinweis
  „Technik: spice-webdavd installieren“.
- **Client:** spice-glib muss mit **phodav** gebaut sein. Die MacPorts-
  Fassung auf dem Entwicklungs-Mac ist es nicht (kein `libphodav` gelinkt);
  die App erkennt das (`rw_spice_ordner_moeglich`) und sagt es. Für macOS
  heisst das: spice-gtk mit phodav (libsoup 3) im eigenen Stapel bauen
  (siehe „Auslieferung“). Debian/MSYS2 liefern spice-glib mit phodav.

## Gemeinsam, noch offen

- Texture statt ui.Image: 1–2 PT je Plattform.
- Gast-Agent: Fenstergrösse folgen (`rw_spice_bildschirm_groesse` ist da),
  Zwischenablage, Mauszeiger-Kanal, mehrere Bildschirme: 3–5 PT.
- Native Assets (Dart build hooks) statt `RW_NATIVE_DIR`, damit `flutter build`
  die Bibliotheken selbst bündelt: 1–2 PT.
