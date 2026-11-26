#!/bin/bash
# Baut die ausgelieferte Windows-App und den Installer (Inno Setup).
# Laeuft in der MSYS2-Shell (UCRT64) auf Windows, mit Flutter, Go und Inno
# Setup im Windows-PATH (MSYS2 mit path-type inherit bzw. MSYS2_PATH_TYPE=inherit).
#
#   windows/installer/bauen.sh [--ohne-native] [--ohne-flutter] [--ohne-installer]
#
# Ergebnis in build/windows-installer/:
#   Rosenweg Virtuelle Computer/                     Buendel (rosenweg_vm.exe + DLLs)
#   Rosenweg-Virtuelle-Computer-<v>-Windows.exe      Installer
#
# Schritte:
#   1. native Bibliotheken: rwtunnel.dll (Go, mingw), rwspice.dll (gcc gegen
#      spice-glib aus MSYS2)
#   2. flutter build windows --release
#   3. Buendel: Flutter-Ausgabe + rwspice.dll + rwtunnel.dll + alle DLLs, die
#      davon aus MSYS2 (/ucrt64/bin) gebraucht werden (ldd, rekursiv). LGPL:
#      dynamisch, austauschbar; BIBLIOTHEKEN.txt nennt Paket und Version.
#   4. Ladetest (native/rwspice/test/laden_test.c) im Buendel mit einem PATH
#      ohne MSYS2: fehlt eine DLL, bricht der Bau hier ab.
#   5. UsbDk (Red Hat/Daynix, Apache-2.0, Treiber fuer USB-Durchreichen) mit
#      fester Pruefsumme laden; der Installer bietet ihn als Option an.
#   6. Installer mit Inno Setup (rosenweg-vm.iss): Installation pro Person
#      ohne Administratorrechte; nur UsbDk fragt einmal nach Rechten.
#
# Signieren: wenn RW_SIGNTOOL_ZERT (Pfad zu .pfx) und RW_SIGNTOOL_PASSWORT
# gesetzt sind, werden rosenweg_vm.exe, die eigenen DLLs und der Installer mit
# signtool signiert (Zeitstempel), sonst bleibt alles unsigniert (SmartScreen
# warnt beim ersten Start: "Weitere Informationen" -> "Trotzdem ausfuehren").
set -euo pipefail

WURZEL="$(cd "$(dirname "$0")/../.." && pwd)"
HIER="$WURZEL/windows/installer"
AUS="$WURZEL/build/windows-installer"
NAME="Rosenweg Virtuelle Computer"
DATEINAME="Rosenweg-Virtuelle-Computer"
PREFIX="${MINGW_PREFIX:-/ucrt64}"

USBDK_URL="https://github.com/daynix/UsbDk/releases/download/v1.00-22/UsbDk_1.0.22_x64.msi"
USBDK_SHA256="91f6f695e1e13c656024e6d3b55620bf08d8835ef05ee0496935ba6bb62466a5"

NATIVE=1 FLUTTER=1 INSTALLER=1
for a in "$@"; do
    case "$a" in
    --ohne-native) NATIVE=0 ;;
    --ohne-flutter) FLUTTER=0 ;;
    --ohne-installer) INSTALLER=0 ;;
    -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $a" >&2; exit 2 ;;
    esac
done

schritt() { printf '\n== %s\n' "$*"; }
fehler() { echo "FEHLER: $*" >&2; exit 1; }

cd "$WURZEL"
VERSION="$(sed -n 's/^version: *\([0-9.]*\)+\{0,1\}\([0-9]*\).*/\1/p' pubspec.yaml)"
BAUNUMMER="$(sed -n 's/^version: *[0-9.]*+\([0-9]*\).*/\1/p' pubspec.yaml)"
[ -n "$VERSION" ] || fehler "Version aus pubspec.yaml nicht lesbar"
[ -d "$PREFIX/bin" ] || fehler "$PREFIX fehlt - in der MSYS2-Shell (UCRT64) ausfuehren"

if [ "$NATIVE" = 1 ]; then
    schritt "Native Bibliotheken"
    native/rwtunnel/bauen.sh windows
    native/rwspice/bauen.sh windows
fi

if [ "$FLUTTER" = 1 ]; then
    schritt "flutter build windows --release"
    # flutter.bat ueber cmd, die bash-Fassung von flutter laeuft unter MSYS2 nicht sauber
    cmd.exe //c "flutter build windows --release"
fi

REL="$WURZEL/build/windows/x64/runner/Release"
[ -f "$REL/rosenweg_vm.exe" ] || fehler "$REL/rosenweg_vm.exe fehlt (flutter build windows)"

schritt "Buendel"
B="$AUS/$NAME"
rm -rf "$AUS"; mkdir -p "$B"
cp -r "$REL"/. "$B"/
cp native/rwtunnel/build/windows/rwtunnel.dll native/rwspice/build/windows/rwspice.dll "$B"/

# Alle DLLs aus MSYS2, die rwspice.dll/rwtunnel.dll (direkt oder ueber andere)
# brauchen. ldd von MSYS2 loest rekursiv auf und nennt den Pfad; Windows-
# eigene DLLs (/c/Windows/...) bleiben weg.
ldd "$B/rwspice.dll" "$B/rwtunnel.dll" \
    | awk -v p="$PREFIX/bin/" 'index($3, p) == 1 { print $3 }' | sort -u > "$AUS/dlls.txt"
[ -s "$AUS/dlls.txt" ] || fehler "ldd fand keine DLLs aus $PREFIX/bin"
while read -r d; do cp "$d" "$B"/; done < "$AUS/dlls.txt"
echo "$(wc -l < "$AUS/dlls.txt") DLLs aus MSYS2"

# Leere Plugin-Ordner (rwspice biegt GStreamer/GIO dorthin, siehe buendel_pfade)
mkdir -p "$B/plugins/gstreamer-1.0" "$B/plugins/gio-modules"

# Lizenzen: eigene, miniaudio, UsbDk-Hinweis, Liste der Bibliotheken mit Paket
L="$B/Lizenzen"; mkdir -p "$L"
cp LICENSE LIZENZEN.md "$L"/
cp native/rwspice/drittanbieter/LICENSE-miniaudio "$L"/
{
    echo "Mitgelieferte Bibliotheken (MSYS2 UCRT64, dynamisch gelinkt)"
    echo "Quelltext: https://packages.msys2.org/ (PKGBUILD je Paket, Quellarchive)"
    echo
    # "…/x.dll is owned by <paket> <version>" (ein Aufruf fuer alle)
    # shellcheck disable=SC2046
    pacman -Qo $(cat "$AUS/dlls.txt") 2>/dev/null \
        | sed -n 's|^.*/\([^/ ]*\) is owned by \(.*\)$|\1  \2|p' | sort
} > "$L/BIBLIOTHEKEN.txt"

schritt "Ladetest im Buendel"
gcc -O1 -o "$AUS/laden_test.exe" native/rwspice/test/laden_test.c
# PATH ohne MSYS2: nur das Buendel und Windows selbst
BW="$(cygpath -w "$B")"
( export PATH="/c/Windows/System32:/c/Windows"; "$AUS/laden_test.exe" "$BW" ) \
    || fehler "Ladetest gescheitert - fehlt eine DLL im Buendel?"
rm -f "$AUS/laden_test.exe"

signieren() {
    [ -n "${RW_SIGNTOOL_ZERT:-}" ] || return 0
    signtool.exe sign //f "$(cygpath -w "$RW_SIGNTOOL_ZERT")" //p "$RW_SIGNTOOL_PASSWORT" \
        //fd sha256 //tr http://timestamp.digicert.com //td sha256 "$@"
}
if [ -n "${RW_SIGNTOOL_ZERT:-}" ]; then
    schritt "Signieren (Programm, eigene DLLs)"
    signieren "$(cygpath -w "$B/rosenweg_vm.exe")" "$(cygpath -w "$B/rwspice.dll")" "$(cygpath -w "$B/rwtunnel.dll")"
fi

[ "$INSTALLER" = 1 ] || { echo "fertig (ohne Installer): $B"; exit 0; }

schritt "UsbDk"
U="$AUS/UsbDk_x64.msi"
curl -fsSL -o "$U" "$USBDK_URL"
echo "$USBDK_SHA256  $U" | sha256sum -c -

schritt "Installer (Inno Setup)"
ISCC="$(command -v ISCC.exe || command -v iscc || true)"
[ -n "$ISCC" ] || for k in "/c/Program Files (x86)/Inno Setup 6/ISCC.exe" "/c/Program Files/Inno Setup 6/ISCC.exe"; do
    [ -x "$k" ] && ISCC="$k" && break
done
[ -n "$ISCC" ] || fehler "Inno Setup (ISCC.exe) nicht gefunden"
"$ISCC" //Qp \
    "//DVersion=$VERSION" "//DBaunummer=${BAUNUMMER:-0}" \
    "//DBuendel=$(cygpath -w "$B")" "//DUsbDk=$(cygpath -w "$U")" \
    "//DSymbol=$(cygpath -w "$WURZEL/windows/runner/resources/app_icon.ico")" \
    "//O$(cygpath -w "$AUS")" "//F$DATEINAME-$VERSION-Windows" \
    "$(cygpath -w "$HIER/rosenweg-vm.iss")"
SETUP="$AUS/$DATEINAME-$VERSION-Windows.exe"
[ -f "$SETUP" ] || fehler "Installer fehlt: $SETUP"
signieren "$(cygpath -w "$SETUP")"
rm -f "$U" "$AUS/dlls.txt"
ls -la "$SETUP"
sha256sum "$SETUP"
