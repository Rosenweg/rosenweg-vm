# CI

## Linux (`.github/workflows/linux.yml`)

Läuft auf dem eigenen Runner der Organisation: Gruppe **`rosenweg-privat`**,
Labels `self-hosted, Linux, X64` (heute `rosenweg-runner-1`, CT 140 auf pve2,
Debian).

**Einmalig nötig (nicht gemacht):** In den Organisationseinstellungen das Repo
`rosenweg-vm` zur Runner-Gruppe `rosenweg-privat` hinzufügen. Heute stehen dort
nur documents, netbox-collector, os-stationen und rosenweg-messenger. Ohne
diesen Eintrag wartet der Lauf auf einen Runner.

Was der Lauf braucht:
- **Systempakete** über das eingeschränkte `apt-get` (nur wenn sie fehlen):
  `clang cmake ninja-build pkg-config xz-utils curl unzip git libgtk-3-dev
  liblzma-dev libstdc++-14-dev libspice-client-glib-2.0-dev libsecret-1-dev
  libjsoncpp-dev`, für das .deb dazu `dpkg-dev binutils patchelf
  librsvg2-bin file lintian`. Ist `sudo -n apt-get` für eines davon nicht erlaubt, bricht
  der Lauf mit der Liste der fehlenden Pakete ab. Dann die Pakete einmal von
  Hand auf CT 140 installieren oder die sudo-Regel erweitern.
- **Go 1.27.4 und Flutter 3.47.5** werden mit fester Prüfsumme nach
  `~/.cache/rosenweg-vm-ci` geladen, einmal pro Version. Nichts systemweit.

Was er tut: Go-Tests (Tunnel mit echtem WireGuard-Handshake, Gateway Ende zu
Ende), `librwtunnel.so` und `librwspice.so` bauen, `flutter analyze`, `flutter
test`, `flutter build linux --release`, Gateway bauen. Daraus entstehen die
Artefakte `rosenweg-vm-linux-x64.tar.gz` (App samt beider Bibliotheken,
LICENSE, LIZENZEN.md), das Debian-Paket `rosenweg-vm_<version>_amd64.deb`
(`linux/paket/bauen.sh --nur-paket`) und `vm-gateway` mit Unit und
Setup-Skript.

Solange der Runner das Repo nicht bedienen darf, baut man das .deb im
Bau-Container CT 141 (Debian 13, pve3): `linux/paket/im-container.sh`. Das
schickt den Arbeitsstand als Archiv über den Knoten hinein und holt das
Paket zurück nach `linux/paket/out/`; Go und Flutter bleiben dort im Cache.

Nicht im Lauf: der Integrationstest gegen einen SPICE-Testserver. Dafür
bräuchte es ein Display (Xvfb) und spice-server; das kommt, sobald ein erstes
Debian-Paket der App entsteht.

## Windows (`.github/workflows/windows.yml`)

GitHub-Runner `windows-latest` (kein eigener Windows-Runner nötig; Minuten
zählen doppelt, darum nur bei Änderungen an `windows/`, `native/`, `lib/`,
`pubspec.*`, von Hand oder bei Tags). Ablauf: MSYS2 UCRT64 mit spice-gtk,
Go-Tests des Tunnels, `rwtunnel.dll`/`rwspice.dll`, `flutter test`, `flutter
build windows`, `windows/installer/bauen.sh` (Bündel, Ladetest ohne MSYS2 im
PATH, UsbDk mit Prüfsumme, Inno Setup), dann **Rauchtest**: Installer still
pro Person ausführen, App 20 s laufen lassen, Logdatei prüfen. Artefakt
`rosenweg-vm-windows` (Installer). Bei Tags: Release und /apps.

Signieren nur mit den Secrets `WINDOWS_ZERTIFIKAT_PFX`,
`WINDOWS_ZERTIFIKAT_PASSWORT` (nicht angelegt).

## Android (`.github/workflows/android.yml`)

GitHub-Runner `ubuntu-latest`. Job **stapel** (Matrix arm64-v8a, x86_64):
meson/ninja/pyparsing aus apt, NDK 28.2 über sdkmanager,
`native/spice-stapel/bauen.sh android <abi>` (Quellarchive inkl. ~1 GB
GStreamer-Paket im Actions-Cache), `native/rwspice/bauen.sh android <abi>`,
Prüfung der Abhängigkeiten und der 16-KB-Ausrichtung. Braucht keine Secrets.

Job **apk**: `librwtunnel.so`, Sammeln nach `build/android-jniLibs`,
`flutter analyze/test`, `flutter build apk`. Braucht **`BASIS_TOKEN`** (oder
`BASIS_DEPLOY_KEY`) für die private Basis — wie rosenweg-salz; ohne bricht der
Job mit Meldung ab. Signatur mit dem Rosenweg-Schlüssel nur mit den Secrets
`ANDROID_KEYSTORE_BASE64`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS`,
`ANDROID_KEY_PASSWORD`; sonst Debug-Signatur.

## Zugang zur Basis (alle Flutter-Läufe)

Seit rosenweg-vm `rosenweg_basis` nutzt, holen alle Läufe (Linux, macOS,
Windows, Android, iOS) die private Basis über `.github/actions/basis-zugang`
mit dem Secret **`BASIS_TOKEN`** (fein granulierter Token, nur
Rosenweg/rosenweg-basis, Contents read-only) oder `BASIS_DEPLOY_KEY`.
