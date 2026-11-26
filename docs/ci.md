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
  libjsoncpp-dev`. Ist `sudo -n apt-get` für eines davon nicht erlaubt, bricht
  der Lauf mit der Liste der fehlenden Pakete ab. Dann die Pakete einmal von
  Hand auf CT 140 installieren oder die sudo-Regel erweitern.
- **Go 1.27.4 und Flutter 3.47.5** werden mit fester Prüfsumme nach
  `~/.cache/rosenweg-vm-ci` geladen, einmal pro Version. Nichts systemweit.

Was er tut: Go-Tests (Tunnel mit echtem WireGuard-Handshake, Gateway Ende zu
Ende), `librwtunnel.so` und `librwspice.so` bauen, `flutter analyze`, `flutter
test`, `flutter build linux --release`, Gateway bauen. Daraus entstehen die
Artefakte `rosenweg-vm-linux-x64.tar.gz` (App samt beider Bibliotheken,
LICENSE, LIZENZEN.md) und `vm-gateway` mit Unit und Setup-Skript.

Nicht im Lauf: der Integrationstest gegen einen SPICE-Testserver. Dafür
bräuchte es ein Display (Xvfb) und spice-server; das kommt, sobald ein erstes
Debian-Paket der App entsteht.

## Windows (später, nur Planung)

Eine Windows-VM als zweiter Runner (Label z. B. `self-hosted, Windows, X64`,
ebenfalls Gruppe `rosenweg-privat`):

| Was | Warum |
|---|---|
| Windows 11 oder Server 2022, 4 vCPU, 8 GB RAM, 80 GB | Flutter + Visual Studio + MSYS2 |
| GitHub Actions Runner als Dienst unter einem eigenen Konto ohne Admin | wie CT 140 |
| Visual Studio 2022 Build Tools mit „Desktopentwicklung mit C++“ | `flutter build windows` |
| Flutter 3.47.5 (im Lauf geladen, wie unter Linux) | |
| MSYS2 mit `mingw-w64-x86_64-spice-gtk`, `mingw-w64-x86_64-gcc`, `mingw-w64-x86_64-go` | spice-glib-DLLs, librwspice/librwtunnel mit mingw |
| WiX Toolset oder Inno Setup | Installer, der auch UsbDk mitbringt |
| UsbDk-MSI (Red Hat, Apache-2.0) im Installer, nicht auf dem Runner | USB-Durchreichen braucht den Treiber nur beim Nutzer |
| Code-Signatur-Zertifikat (optional) | sonst warnt SmartScreen |

Ablauf wie unter Linux: Go-Tests, DLLs bauen, `flutter build windows`,
DLLs aus MSYS2 neben die .exe kopieren (ein `ldd`-Durchgang listet sie),
Installer bauen, Artefakt hochladen. Aufwand für Runner und Workflow: etwa 2 PT.
