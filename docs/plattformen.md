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
| Stand | **.deb gebaut** (CT 141, 26.11.2026), Start unter Xvfb bis zur Anmeldung | nicht gebaut | **DMG gebaut** (arm64, ab macOS 26, ad hoc) | Tunnel baut | Tunnel baut |

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
- **Auslieferung (DMG, gebaut 26.11.2026):** `macos/installer/bauen.sh`
  baut beide nativen Bibliotheken, `flutter build macos --release`, kopiert
  librwtunnel, librwspice und alle davon gebrauchten dylibs aus MacPorts
  (27 Stück: spice-glib, GLib, GStreamer-Kern, OpenSSL, usbredir, libusb, …)
  nach `Contents/Frameworks`, schreibt alle Pfade auf `@rpath/<name>` um
  (jede Bibliothek mit rpath `@loader_path`), prüft, dass nichts mehr nach
  `/opt/local`, `/opt/homebrew` oder `/usr/local` zeigt, signiert von innen
  nach aussen und macht mit `dmgbuild` das DMG (Hintergrund
  `macos/installer/hintergrund.svg` → PNG 1x/2x, Programme-Verknüpfung,
  Volume-Symbol = App-Symbol, Layout in `dmg-einstellungen.py`). Ergebnis:
  `build/macos-installer/Rosenweg-Virtuelle-Computer-<version>.dmg`.
  Die App findet die Bibliotheken über `Contents/Frameworks`
  (`lib/native/bibliothek.dart`), `RW_NATIVE_DIR` braucht es nicht.
  Optionen: `--ohne-native`, `--ohne-flutter`, `--ohne-dmg`.
- **Sandbox:** der ausgelieferte Bau läuft mit `Release.entitlements`
  (Sandbox, network.client/server, audio-input, usb, user-selected
  read-write). Getestet: Anmeldung aus dem Schlüsselbund, Tunnel, „im
  Haus“-Erkennung, SPICE-Bild. Protokoll liegt dann unter
  `~/Library/Containers/ch.rosenweg4303.vm/Data/Library/Logs/Rosenweg Virtuelle Computer/app.log`.
- **GStreamer:** spice-glib aus MacPorts ist dagegen gelinkt, darum liegen
  die Kernbibliotheken bei. Plugins nicht: Ton macht rwspice selbst
  (miniaudio/CoreAudio), Bild-Streams dekodiert spice-glib ohne Plugins
  (MJPEG) und bietet dem Server nur das an. rwspice biegt im Bündel die
  Suchpfade von GStreamer und GIO auf `Contents/PlugIns/…` um (leer), damit
  auf einem Mac mit MacPorts keine fremden Module geladen werden
  (`buendel_pfade` in `rwspice.c`).
- **Architektur: nur arm64, ab macOS 26.** MacPorts baut den Stapel nur für
  die eigene Architektur und für das eigene System (minos 26.0). Ein
  Universal-Bau bräuchte `+universal` für den ganzen Stapel (glib,
  gstreamer, openssl, spice-gtk …, Stunden Bauzeit, alles neu); librwtunnel
  wäre schon universal. Das Skript prüft das selbst: bringen alle
  Bibliotheken x86_64 mit, bleibt die App universal, sonst wird alles auf
  arm64 verdünnt. `LSMinimumSystemVersion` setzt es auf die höchste
  Mindestversion der Bibliotheken, damit ältere Macs eine klare Meldung
  bekommen statt eines Absturzes. Für ältere macOS-Versionen: den Stapel
  selbst bauen (siehe iOS/UTM) oder auf einem Mac mit älterem System bauen.
- **Signieren:** `RW_SIGNIER_ID` oder automatisch die erste „Developer ID
  Application“ im Schlüsselbund, dann mit Hardened Runtime und Zeitstempel;
  ohne Zertifikat ad hoc. Notarisieren, wenn ein notarytool-Profil da ist
  (`xcrun notarytool store-credentials rosenweg-notar …`, Name über
  `RW_NOTAR_PROFIL`) oder ein API-Schlüssel (`RW_NOTAR_KEY`,
  `RW_NOTAR_KEY_ID`, `RW_NOTAR_ISSUER`); danach `stapler staple` aufs DMG.
  Stand 26.11.2026: auf dem Entwicklungs-Mac liegt nur ein „Apple
  Development“-Zertifikat (darf nicht verteilen) → ad hoc. Für eine
  Verteilung ohne Gatekeeper-Warnung braucht es das Apple Developer Program
  (99 USD/Jahr), daraus ein „Developer ID Application“-Zertifikat und für
  notarytool ein App-spezifisches Passwort oder einen App-Store-Connect-API-
  Schlüssel. Danach genügt ein erneuter Lauf von `bauen.sh`.
- **Ad-hoc-signierte App öffnen:** aus dem Internet geladen (Quarantäne)
  meldet macOS „kann nicht überprüft werden“. Einmal Rechtsklick → Öffnen →
  Öffnen; ab macOS 15 stattdessen Systemeinstellungen → Datenschutz &
  Sicherheit → „Dennoch öffnen“. Oder im Terminal
  `xattr -dr com.apple.quarantine "/Applications/Rosenweg Virtuelle Computer.app"`.
  Ausserdem fragt der Schlüsselbund nach jedem neuen Bau einmal nach dem
  Zugriff auf den Eintrag `flutter_secure_storage_service` (Signatur ohne
  Team-ID ändert sich mit jedem Bau): „Immer erlauben“. Mit Developer ID
  entfällt beides.
- **Ersetzen einer älteren Fassung:** gleiche Bundle-ID
  (`ch.rosenweg4303.vm`) und gleicher Name; Anmeldung und Geräte-Kennung
  liegen im Anmelde-Schlüsselbund und bleiben. App beenden, neue Fassung
  nach `/Applications` ziehen („Ersetzen“). Liegt sie im Dock, nach dem
  Ersetzen `killall Dock`, damit das neue Symbol erscheint.
- **CI:** `.github/workflows/macos.yml` (von Hand oder bei Tag `v*`, GitHub-
  Runner `macos-26`): MacPorts + spice-gtk, dann `bauen.sh`; DMG als
  Artefakt, bei Tags als Release. Signieren/Notarisieren nur mit den
  Secrets `MACOS_ZERTIFIKAT_P12`, `MACOS_ZERTIFIKAT_PASSWORT`,
  `NOTAR_KEY_P8`, `NOTAR_KEY_ID`, `NOTAR_ISSUER` (nicht angelegt).
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
- **Offen:** Developer ID + Notarisierung; eigener Stapel mit phodav
  (Ordner freigeben) und für ältere macOS/Intel.

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
