# Plattformen: SPICE, Tunnel, Ton, USB

Stand 25.11.2026. Aufwand grob in Personentagen (PT), ohne Store-Verfahren.

## Übersicht

| | Linux (Stationen) | Windows | macOS | Android | iOS/iPadOS |
|---|---|---|---|---|---|
| spice-glib | Debian-Paket | MSYS2 (UCRT64) | MacPorts (Entw.), eigener Bau (Auslieferung) | ✓ GStreamer-Binärpaket + eigener Bau (NDK) | ✓ GStreamer-Binärpaket + eigener Bau (Xcode) |
| rwtunnel (Go) | c-shared | ✓ c-shared (mingw) | ✓ gebaut | ✓ gebaut (arm64, x86_64) | ✓ gebaut (c-archive → RwNative.framework) |
| Ton | PipeWire/Pulse/ALSA | WASAPI | ✓ CoreAudio (Wiedergabe getestet) | AAudio/OpenSL | CoreAudio + AVAudioSession |
| Mikrofon | keine Rechte | Datenschutz-Einstellung | Erlaubnis-Dialog | RECORD_AUDIO | Erlaubnis-Dialog |
| USB | ja (Rechte nötig) | ja (UsbDk-Treiber) | eingeschränkt | ja (Android-USB-Host) | **nein** |
| Anmeldung (einmal, 30 Tage) | still per Kerberos (Station), sonst localhost | still per Kerberos (Domäne), sonst localhost | localhost | Schema (rosenweg_basis) | localhost im In-App-Browser |
| DNS-Server für „im Haus“ | resolv.conf | PowerShell/ipconfig | resolv.conf/scutil | LinkProperties (rosenweg_basis) | keine (immer „Unterwegs“) |
| Stand | **.deb gebaut** (CT 141, 26.11.2026), Start unter Xvfb bis zur Anmeldung | **Installer gebaut** (CI windows-latest, 26.11.2026), Ladetest + Start im Runner, nicht an echter VM getestet | **DMG gebaut** (arm64, ab macOS 26, ad hoc) | **APK gebaut** (arm64-v8a, x86_64; Stapel in CI, APK lokal mit Rosenweg-Schlüssel), nicht auf einem Telefon getestet | **App gebaut ohne Signatur** (lokal; Stapel in CI), nicht auf einem Gerät |

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
- **Stille Anmeldung (Kerberos):** an einer Station mit Domänenanmeldung
  meldet die App beim Start ohne Knopf und ohne Browser an
  (`RosenwegKonto.stillAnmelden`, SPNEGO aus rosenweg_basis
  `StilleAnmeldung`, GSS-API per `dlopen` → `.deb` hängt von
  `libgssapi-krb5-2` ab). Kein Ticket, kein KDC erreichbar oder Authentik
  will etwas fragen → Knopf „Mit Rosenweg-Konto anmelden“ (zuerst wieder
  still, dann Browser). „Abmelden“ in der App meldet bewusst nicht sofort
  wieder still an.
- **Aufwand:** 3–5 PT (Bau auf Debian, Paket, Texture, udev, Test mit echter VM).

## Windows

Stand 26.11.2026: Installer baut in CI (`.github/workflows/windows.yml`,
GitHub-Runner `windows-latest`), Ladetest und Start der installierten App im
Runner grün. Noch nicht gegen eine echte VM probiert (kein Windows-Rechner).

- **SPICE:** MSYS2 **UCRT64** `mingw-w64-ucrt-x86_64-spice-gtk` liefert
  spice-glib mit usbredir, libusb (mit UsbDk-Unterstützung) und **phodav**
  (Ordner freigeben geht hier, anders als mit MacPorts) als DLLs — so baut auch
  virt-viewer für Windows. rwspice mit gcc aus MSYS2 als `rwspice.dll`
  (`native/rwspice/bauen.sh windows`, reines C-ABI, passt zum MSVC-gebauten
  Runner von Flutter). Wie unter macOS biegt rwspice die Suchpfade von
  GStreamer und GIO auf leere Ordner im Bündel um (`plugins/`), damit keine
  fremden Module geladen werden.
- **Tunnel:** Go als DLL über mingw (`native/rwtunnel/bauen.sh windows`, in der
  MSYS2-Shell mit deren gcc). **Kein wintun, kein Dienst, kein Admin** — der
  Tunnel läuft wie überall im Prozess (gVisor-Netzstapel), siehe
  architektur.md §5.
- **Bündel und Installer:** `windows/installer/bauen.sh` (MSYS2-Shell):
  Flutter-Ausgabe + `rwspice.dll` + `rwtunnel.dll` + alle DLLs, die davon aus
  `/ucrt64/bin` gebraucht werden (rekursiv über `ldd`, 48 Stück), Lizenzen
  unter `Lizenzen/` (LICENSE, LIZENZEN.md, miniaudio, `BIBLIOTHEKEN.txt` mit
  MSYS2-Paket und Version je DLL). Danach ein **Ladetest**
  (`native/rwspice/test/laden_test.c`) mit einem PATH ohne MSYS2: fehlt eine
  DLL im Bündel, bricht der Bau ab. Installer mit **Inno Setup**
  (`windows/installer/rosenweg-vm.iss`) →
  `build/windows-installer/Rosenweg-Virtuelle-Computer-<v>-Windows.exe`
  (~30 MB). Entscheid Inno Setup statt MSIX: MSIX lässt sich ohne vertrauens-
  würdige Signatur gar nicht installieren und kennt keine optionale Treiber-
  installation; Inno Setup installiert **pro Person ohne Administrator-
  rechte** nach `%LOCALAPPDATA%\Programs`, Update an Ort und Stelle (gleiche
  AppId), sauber deinstallierbar, `/VERYSILENT` für Verteilung.
- **USB:** spice-glib nutzt libusb mit **UsbDk** (Red Hat/Daynix, Apache-2.0).
  Der Installer bietet UsbDk 1.0.22 als Option an (feste Prüfsumme); nur dieser
  Schritt fragt einmal nach Administratorrechten (UAC). Ohne UsbDk bleibt die
  USB-Liste leer, alles andere geht.
- **Ton/Mikrofon:** WASAPI über miniaudio; Mikrofon braucht die Freigabe in
  den Windows-Datenschutzeinstellungen.
- **Logo:** `windows/runner/resources/app_icon.ico` aus dem Baukasten
  (`assets/logo/erzeugen.sh`), Programm- und Produktname in `Runner.rc`.
- **Signatur:** ohne Code-Signing-Zertifikat warnt SmartScreen beim ersten
  Start („Weitere Informationen" → „Trotzdem ausführen"). Mit Secrets
  `WINDOWS_ZERTIFIKAT_PFX` (base64) und `WINDOWS_ZERTIFIKAT_PASSWORT` signiert
  der Lauf Programm, eigene DLLs und Installer (signtool, Zeitstempel).
  Sinnvoll: ein OV-Zertifikat (SmartScreen-Ruf baut sich langsam auf) oder
  Azure Trusted Signing.
- **Veröffentlichen:** bei Tag `v*` ins GitHub-Release und auf /apps
  (`.exe` = Plattform windows), wie .deb und .dmg.
- **Offen:** Test an echter VM (Bild, Ton, USB mit UsbDk, Ordner). Stille
  Anmeldung per Kerberos (SSPI, `secur32.dll`, NTLM wird verworfen) ist
  eingebaut wie unter Linux, an einem Rechner der Domäne noch nicht getestet.

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
  `~/Library/Containers/ch.rosenweg4303.vm/Data/Library/Logs/rosenweg-vm/app.log` (bis 1.1.0 `…/Logs/Rosenweg Virtuelle Computer/`).
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
  Artefakt, bei Tags als Release und auf www.rosenweg4303.ch/apps (wie das
  .deb aus `linux.yml`; Anmeldung per GitHub-OIDC, kein Geheimnis). Signieren/Notarisieren nur mit den
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

Stand 26.11.2026: SPICE-Stapel baut in CI (`.github/workflows/android.yml`,
Job `stapel`, je ABI ~5 min), die APK mit allen drei Bibliotheken je ABI
lokal (mit dem Rosenweg-Schlüssel signiert, 16-KB-Seiten). Nicht auf einem
Telefon ausprobiert.

- **SPICE – Entscheid: dieselbe C-Schicht wie überall** (rwspice über
  spice-glib), nicht eine zweite SPICE-Implementierung. Geprüft und
  verworfen:
  - *aSPICE/Opaque (iiordanov/remote-desktop-clients, GPL-3)*: lizenzrechtlich
    passend (die App ist GPL-3.0-or-later), bringt aber auch nur spice-gtk
    über JNI mit (eigene cerbero-Rezepte) — kein Java-SPICE, das sich als
    Bibliothek einbinden liesse, und die Bedienung (Bild, Tastatur, USB,
    Ordner) hätte eine zweite, Android-eigene Fassung.
  - *spice-html5 über WebSocket am Gateway*: kein USB, kein Mikrofon, Ton und
    Bild deutlich schwächer, eigener Weg im Gateway — nein.
- **Bau:** `native/spice-stapel/bauen.sh android <abi>` nimmt für GLib,
  GStreamer-Kern (von spice-glib verlangt), OpenSSL, pixman, opus,
  libjpeg-turbo, json-glib, zlib, libffi, pcre2, iconv/intl das **offizielle
  GStreamer-Binärpaket für Android** (1.28.9, feste Prüfsumme; LGPL/MIT/BSD)
  und baut mit dem NDK (r28, API 24) nur **libusb 1.0.30, usbredir 0.15.0,
  spice-protocol 0.14.5 und spice-gtk 0.43** (nur spice-glib: ohne GTK, ohne
  phodav, Koroutinen über GThread, weil Bionic kein `makecontext` hat).
  Daraus **`libspiceglib.so`** (alle LGPL-Teile in einer eigenen, austauschbaren
  .so, ~16 MB) und `librwspice.so` dagegen (`native/rwspice/bauen.sh android
  <abi>`). Der CI-Lauf prüft, dass beide nur Android-Systembibliotheken
  brauchen und auf 16-KB-Seiten ausgerichtet sind.
- **APK:** `android/native-sammeln.sh` legt `librwtunnel.so`, `librwspice.so`,
  `libspiceglib.so` nach `build/android-jniLibs/<abi>/` (Gradle nimmt den
  Ordner als jniLibs). Nur **arm64-v8a** (Telefone) und **x86_64** (Emulator):
  `flutter build apk --release --target-platform android-arm64,android-x64`;
  armeabi-v7a/x86-Reste von Plugins schliesst Gradle aus (`packaging.jniLibs`).
  ~89 MB (zwei ABIs; ein App-Bundle oder `--split-per-abi` halbiert das).
- **Tunnel:** ✓ `librwtunnel.so` (Go c-shared). **Kein VpnService**, kein
  VPN-Dialog, keine Rechte; der Tunnel lebt nur, solange die App läuft
  (architektur.md §5). gomobile braucht es nicht, die C-Schnittstelle ist
  dieselbe wie auf den Desktops.
- **Anmeldung:** über **rosenweg_basis** (v0.2.0) wie die übrigen
  Rosenweg-Apps: Schema `ch.rosenweg4303.vm:/anmeldung`, die
  Rücksprung-Activity und die DNS-Server des aktiven Netzes bringt das Plugin
  der Basis mit (eigener Kanal in `MainActivity.kt` entfällt). Auf den
  Desktops derselbe Anmeldeweg der Basis (localhost). In Authentik
  (rosenweg-apps) muss `ch.rosenweg4303.vm:/anmeldung` als strikte
  Weiterleitung eingetragen sein.
- **Geteilte Telefone:** noch **nicht**. Dort gibt Rosenweg Gerät kein Token
  heraus (`portal_anfrage`, eine Anfrage je Token an die Haupt-API); die App
  braucht aber ein Token für `POST /api/apps/tunnel` und für jede Anfrage an
  den Gateway. Dafür bräuchte es einen Anlage-Token-Weg für den Gateway
  (PBX-API/Gateway) — eigener Schritt.
- **Ton:** AAudio/OpenSL ES über miniaudio. Mikrofon: Laufzeit-Erlaubnis
  `RECORD_AUDIO` fehlt noch (Manifest + Abfrage beim Einschalten).
- **USB:** spice-gtk 0.43 hat den Android-Weg schon eingebaut
  (`LIBUSB_OPTION_NO_DEVICE_DISCOVERY`,
  `spice_usb_device_manager_allocate_device_for_file_descriptor` →
  `libusb_wrap_sys_device`). Fehlt: `UsbManager.requestPermission` +
  Dateideskriptor in Kotlin und eine Funktion in rwspice dafür. Bis dahin
  bleibt die USB-Liste leer.
- **Signatur:** lokal mit dem Rosenweg-Schlüssel (Umgebungsvariablen
  `SIGNING_*` aus `keystore.properties`); in CI nur, wenn die Secrets
  `ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
  `ANDROID_KEY_PASSWORD` gesetzt sind (sonst Debug-Signatur, nicht an /apps).
  Bei Tags mit Rosenweg-Signatur: Release und /apps (Paket
  `ch.rosenweg4303.vm`).
- **Offen:** Test auf Telefon und Tablet (Touch: Tippen = Klick, Bildschirm-
  tastatur, Zoom), Mikrofon-Erlaubnis, USB, geteilte Telefone.

## iOS / iPadOS

Stand 26.11.2026: `flutter build ios --release --no-codesign` baut lokal mit
beiden Frameworks im Bündel (`Runner.app/Frameworks/{SpiceGlib,RwNative}.framework`);
CI-Workflow `.github/workflows/ios.yml`. **Ohne Apple Developer Program nur
unsigniert** — auf keinem Gerät installierbar, nicht getestet.

- **SPICE – Entscheid wie Android:** dieselbe C-Schicht über spice-glib.
  UTM (Apache-2.0) baut den ganzen Stapel selbst (Stunden); statt dessen das
  **offizielle GStreamer-Binärpaket für iOS** (1.28.9, feste Prüfsumme). Es
  enthält eine einzige zusammengefügte statische Bibliothek (arm64 +
  x86_64-Simulator) und flache Kopfdateien, aber keine `.pc`-Dateien:
  `native/spice-stapel/ios.sh` löst arm64 heraus, schreibt `.pc`-Dateien für
  die Module, die spice-glib verlangt (Versionen aus den Kopfdateien), baut
  spice-protocol und spice-gtk 0.43 (nur spice-glib, **ohne USB**, ohne phodav,
  GThread-Koroutinen; `drm_fourcc.h` als Ein-Zeilen-Ersatz) und linkt daraus
  **`SpiceGlib.framework`** (dynamisch, austauschbar, ~17 MB): spice-glib ganz,
  aus dem GStreamer-Archiv nur, was gebraucht wird, dazu jedes GLib-Symbol,
  das rwspice selbst ruft (aus `rwspice.c` ermittelt).
- **Tunnel – Entscheid: keine Network Extension.** rwtunnel (Go c-archive)
  liegt mit rwspice (als Objective-C übersetzt, weil miniaudio dort
  AVAudioSession braucht) in **`RwNative.framework`**
  (`native/rwspice/bauen.sh ios`). WireGuard läuft wie überall im Prozess;
  eine NetworkExtension bräuchte das Developer Program, ein eigenes
  App-Extension-Ziel und eine Berechtigung, und brächte nichts: geht die App
  in den Hintergrund, endet die Sitzung ohnehin.
- **Einbinden:** beide Frameworks stehen im Xcode-Projekt in der Phase „Embed
  Frameworks“ (Pfad `../build/ios-native/`, also vor `flutter build ios`
  bauen); die App lädt `RwNative.framework` mit `DynamicLibrary.open`
  (`lib/native/bibliothek.dart`), das zieht SpiceGlib über `@rpath` nach.
- **Anmeldung:** localhost-Rücksprung wie auf dem Desktop (Anmeldeweg der
  Basis), aber die Seite öffnet im **Browserfenster der App**
  (SFSafariViewController, `LaunchMode.inAppBrowserView`): die App bleibt im
  Vordergrund, ihr Port nimmt den Rücksprung an; danach schliesst sie das
  Fenster. Kein neuer Eintrag in Authentik nötig. (Safari ausserhalb ginge
  nicht: die App wäre angehalten.) Die Authentik-Sitzung aus Safari kennt das
  Fenster nicht; die Person meldet sich einmal an, danach 30 Tage still.
- **Netz:** `NSLocalNetworkUsageDescription` eingetragen (LAN-Endpunkt im
  Haus). Die DNS-Server liest die App auf iOS noch nicht, darum immer
  „Unterwegs“ (sicher, nur der längere Weg).
- **Ton:** CoreAudio über miniaudio; Mikrofon-Erlaubnis
  `NSMicrophoneUsageDescription` (eingetragen).
- **USB:** **geht nicht** (iOS gibt Apps keinen Zugriff auf beliebige
  USB-Geräte); spice-glib ohne usbredir, die Liste bleibt leer.
- **Was es für Geräte braucht:** Apple Developer Program (99 USD/Jahr), daraus
  Zertifikat + Provisioning Profile (Ad hoc mit Geräte-UDIDs, TestFlight oder
  App Store). Vor App Store: GPL-Frage klären (LIZENZEN.md).
- **Offen:** Test auf iPhone/iPad, DNS für „im Haus“ (`res_9_getservers`),
  Simulator-Bau (dafür bräuchte es die x86_64/arm64-sim-Teile als xcframework).

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
