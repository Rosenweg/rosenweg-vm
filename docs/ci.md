# CI

**Grundsatz (öffentliches Repo):** alle Jobs laufen auf von GitHub gehosteten
Runnern (`ubuntu-latest`, `windows-latest`, `macos-latest`), **nie** auf einem
eigenen Runner, auch nicht für Releases. Ein PR aus einem Fork darf keinen
Code im Servernetz ausführen. Öffentlich kosten die Minuten nichts, darum
laufen auch Windows, macOS und iOS bei jedem PR und Push auf `main`; in einem
privaten Repo nur bei Tags `v*` und von Hand (`gh workflow run <datei> --ref <zweig>`).

**Secrets nur bei Push/Tag:** Die Signier-Schritte (`ANDROID_KEYSTORE_*`,
`WINDOWS_ZERTIFIKAT_*`, `MACOS_*`/`NOTAR_*`) laufen nur bei Push auf `main`
oder Tag `v*` (`SIGNIEREN` im Workflow); bei einem PR gibt es immer die
Debug-Signatur bzw. einen unsignierten/ad-hoc-signierten Bau. Fork-PRs
bekommen ohnehin keine Secrets. Kein `pull_request_target`.

**Rechte:** jeder Workflow setzt `permissions: contents: read`;
`contents: write` und `id-token: write` (OIDC für /apps) haben nur die Jobs
`veroeffentlichen` (und `apps.yml`), die nur bei Tags laufen.

**Caches:** `actions/cache` statt eines dauerhaften Ordners auf dem Runner.
Die Schlüssel enthalten Versionen und Prüfsummen; geladen wird weiterhin mit
`sha256sum -c`. Ein PR schreibt nur in seinen eigenen Cache-Bereich, nie in
den von `main`.

**Basis:** `rosenweg_basis` kommt aus dem öffentlichen Repo
Rosenweg/rosenweg-basis; `pub get` braucht keinen Token.

## Linux (`.github/workflows/linux.yml`)

`ubuntu-latest` im Container **`debian:13`** (wie die Stationen: das .deb
rechnet `dpkg-shlibdeps` gegen Debian 13).

Was der Lauf braucht:
- **Systempakete** über `apt-get` im Container:
  `clang gcc cmake ninja-build pkg-config xz-utils curl unzip git libgtk-3-dev
  liblzma-dev libstdc++-14-dev libspice-client-glib-2.0-dev libsecret-1-dev
  libjsoncpp-dev`, für das .deb dazu `dpkg-dev binutils patchelf
  librsvg2-bin file lintian`.
- **Go 1.27.4 und Flutter 3.47.5** mit fester Prüfsumme nach
  `~/.cache/rosenweg-vm-ci`, zwischen Läufen im `actions/cache`.

Was er tut: Go-Tests (Tunnel mit echtem WireGuard-Handshake, Gateway Ende zu
Ende), `librwtunnel.so` und `librwspice.so` bauen, `flutter analyze`, `flutter
test`, `flutter build linux --release`, Gateway bauen. Daraus entstehen die
Artefakte `rosenweg-vm-linux-x64.tar.gz` (App samt beider Bibliotheken,
LICENSE, LIZENZEN.md), das Debian-Paket `rosenweg-vm_<version>_amd64.deb`
(`linux/paket/bauen.sh --nur-paket`) und `vm-gateway` mit Unit und
Setup-Skript. Bei Tags: Release und /apps (Job `veroeffentlichen`).

Lokal baut man das .deb im Bau-Container (CT 141, Debian 13):
`linux/paket/im-container.sh <knoten>` oder mit `RW_BAU_KNOTEN` in der
Umgebung. Das schickt den Arbeitsstand als Archiv über den Knoten hinein und
holt das Paket zurück nach `linux/paket/out/`.

Nicht im Lauf: der Integrationstest gegen einen SPICE-Testserver. Dafür
bräuchte es ein Display (Xvfb) und spice-server; das kommt, sobald ein erstes
Debian-Paket der App entsteht.

## Windows (`.github/workflows/windows.yml`)

`windows-latest`. Ablauf: MSYS2 UCRT64 mit spice-gtk, Go-Tests des Tunnels,
`rwtunnel.dll`/`rwspice.dll`, `flutter test`, `flutter build windows`,
`windows/installer/bauen.sh` (Bündel, Ladetest ohne MSYS2 im PATH, UsbDk mit
Prüfsumme, Inno Setup), dann **Rauchtest**: Installer still pro Person
ausführen, App 20 s laufen lassen, Logdatei prüfen. Artefakt
`rosenweg-vm-windows` (Installer). Bei Tags: Release und /apps (eigener Job).

Signieren nur bei Push/Tag mit den Secrets `WINDOWS_ZERTIFIKAT_PFX`,
`WINDOWS_ZERTIFIKAT_PASSWORT` (nicht angelegt).

## macOS (`.github/workflows/macos.yml`)

`macos-latest` (arm64). spice-gtk, spice-protocol, libusb und pkgconf kommen
aus **Homebrew** (Flaschen, auf dem Runner schneller als MacPorts; lokal wird
weiter mit MacPorts entwickelt). `macos/installer/bauen.sh` bekommt
`RW_PREFIX=$(brew --prefix)` und bündelt die dylibs von dort; die Herkunft
steht als „Homebrew <formel> <version>“ in `BIBLIOTHEKEN.txt`. Artefakt DMG,
bei Tags Release und /apps (eigener Job).

## Android (`.github/workflows/android.yml`)

`ubuntu-latest`. Flutter, JDK 21, Android-SDK (cmdline-tools 19.0) mit NDK
28.2 und Go mit fester Prüfsumme (nicht das vorinstallierte SDK des Runners)
in `~/.cache/rosenweg-flutter-ci` und `~/.cache/rosenweg-vm-ci`, beide im
`actions/cache`. Job **stapel** (Matrix arm64-v8a, x86_64):
meson/ninja/pyparsing über `apt-get`,
`native/spice-stapel/bauen.sh android <abi>` (Quellarchive inkl. ~1 GB
GStreamer-Paket in `~/.cache/rosenweg-vm-ci/spice-stapel-quellen`),
`native/rwspice/bauen.sh android <abi>`, Prüfung der Abhängigkeiten und der
16-KB-Ausrichtung. Braucht keine Secrets.

Job **apk**: `librwtunnel.so`, Sammeln nach `build/android-jniLibs`,
`flutter analyze/test`, `flutter build apk`. Signatur mit dem
Rosenweg-Schlüssel nur bei Push auf `main`/Tag `v*` und mit den Secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`; sonst Debug-Signatur (nicht an /apps).

## iOS (`.github/workflows/ios.yml`)

`macos-latest`. Job **native**: meson/ninja/pyparsing in einem venv, glib
(Werkzeuge) aus Homebrew, `native/spice-stapel/ios.sh` (Quellen im
`actions/cache`), `native/rwtunnel/bauen.sh ios`, `native/rwspice/bauen.sh
ios`, Prüfung der Abhängigkeiten (nur System und die beiden Frameworks);
Artefakt `ios-native`. Job **app**: `flutter build ios --release
--no-codesign`, daraus eine **unsignierte** .ipa als Artefakt. Nicht an /apps.

## Nachträglich an /apps (`.github/workflows/apps.yml`)

Von Hand für einen Tag, z. B. für ein lokal gebautes DMG:
`gh workflow run apps.yml --ref v1.2.3 -f muster='*.dmg'`. Läuft über
Rosenweg/Website `apps-release.yml` auf `ubuntu-latest`.
