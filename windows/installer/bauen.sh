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
#      Dazu die Microsoft-C++-Laufzeit (msvcp140.dll, vcruntime140.dll,
#      vcruntime140_1.dll) app-lokal: rosenweg_vm.exe, flutter_windows.dll und
#      die Plugin-DLLs sind mit MSVC gebaut, Windows bringt sie nicht mit.
#   4. Abhaengigkeiten (objdump): jede DLL, die eine .exe/.dll im Buendel
#      importiert, liegt im Buendel oder gehoert zu Windows (System32,
#      API-Sets). Die MSVC-Laufzeit zaehlt NICHT zu Windows, auch wenn sie auf
#      dem Bau-Rechner installiert ist (Fehler in 1.2.0: Start auf win11-1
#      scheiterte an VCRUNTIME140.dll).
#      Ladetest (native/rwspice/test/laden_test.c) im Buendel mit einem PATH
#      ohne MSYS2: fehlt eine DLL, bricht der Bau hier ab.
#   5. UsbDk (Red Hat/Daynix, Apache-2.0, Treiber fuer USB-Durchreichen) mit
#      fester Pruefsumme laden; der Installer bietet ihn als Option an.
#   6. Installer mit Inno Setup (rosenweg-vm.iss): Installation pro Person
#      ohne Administratorrechte; nur UsbDk fragt einmal nach Rechten.
#
# MSVC-Laufzeit: Ordner Microsoft.VC14x.CRT aus RW_VC_CRT, sonst aus
# VCToolsRedistDir (Developer-Shell), sonst ueber vswhere (juengste Fassung).
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

# Microsoft-C++-Laufzeit app-lokal (Microsoft erlaubt die Weitergabe als
# "Distributable Code", siehe LIZENZEN.md). vc_redist.x64.exe kaeme nicht in
# Frage: es braucht Administratorrechte, die Installation pro Person nicht.
vc_crt_ordner() {
    local d="${RW_VC_CRT:-}" vw vs
    if [ -n "$d" ]; then cygpath -u "$d"; return; fi
    if [ -n "${VCToolsRedistDir:-}" ]; then
        d="$(cygpath -u "$VCToolsRedistDir")"
    else
        vw="/c/Program Files (x86)/Microsoft Visual Studio/Installer/vswhere.exe"
        [ -x "$vw" ] || return 0
        vs="$("$vw" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 \
            -property installationPath | tr -d '\r')"
        [ -n "$vs" ] || return 0
        d="$(cygpath -u "$vs")/VC/Redist/MSVC"
    fi
    # .../MSVC/<Version>/x64/Microsoft.VC14x.CRT, juengste Fassung
    local k
    for k in "$d"/x64/Microsoft.VC14*.CRT "$d"/*/x64/Microsoft.VC14*.CRT; do
        if [ -d "$k" ]; then printf '%s\n' "$k"; fi
    done | sort -V | tail -n 1
}
# Alle DLL-Namen, die .exe/.dll im Buendel importieren (klein geschrieben)
importe() {
    local f
    for f in "$B"/*.exe "$B"/*.dll; do objdump -p "$f"; done \
        | sed -n 's/^[[:space:]]*DLL Name: *//p' | tr -d '\r' | tr '[:upper:]' '[:lower:]' | sort -u
}
ist_msvc_laufzeit() {
    case "$1" in msvcp*.dll | vcruntime*.dll | concrt*.dll | vccorlib*.dll | vcomp*.dll) return 0 ;; esac
    return 1
}
CRT="$(vc_crt_ordner)"
[ -n "$CRT" ] && [ -f "$CRT/vcruntime140.dll" ] \
    || fehler "MSVC-Laufzeit (Microsoft.VC14x.CRT) nicht gefunden; RW_VC_CRT setzen"
echo "MSVC-Laufzeit aus $CRT"
# Bis nichts mehr dazukommt (msvcp140.dll braucht selbst vcruntime140.dll)
for _ in 1 2 3 4; do
    neu=0
    for d in $(importe); do
        ist_msvc_laufzeit "$d" || continue
        [ -f "$B/$d" ] && continue
        [ -f "$CRT/$d" ] || fehler "$d fehlt in $CRT"
        cp "$CRT/$d" "$B/$d"; echo "  $d"; neu=1
    done
    if [ "$neu" = 0 ]; then break; fi
done

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
    echo
    echo "Microsoft Visual C++ Laufzeit $(basename "$(dirname "$(dirname "$CRT")")") (Redistributable, app-lokal)"
    echo "Lizenz: Microsoft-Software-Lizenzbedingungen fuer Visual Studio, Abschnitt Distributable Code"
    for d in "$B"/*.dll; do
        if ist_msvc_laufzeit "$(basename "$d" | tr '[:upper:]' '[:lower:]')"; then
            echo "$(basename "$d")  Microsoft Visual C++ Redistributable"
        fi
    done
} > "$L/BIBLIOTHEKEN.txt"

schritt "Abhaengigkeiten im Buendel"
# Bewusste Ausnahmen (je mit Grund):
#   jvm.dll  nur von dartjni.dll (Dart-Paket jni, Java-Bruecke, kommt transitiv
#            mit); die App nutzt es auf Windows nie, dartjni.dll wird nur per
#            FFI auf Anfrage geladen bzw. laedt jvm.dll verzoegert
AUSNAHMEN=" jvm.dll "
fehlt=""
for d in $(importe); do
    [ -f "$B/$d" ] && continue
    case "$d" in api-ms-win-* | ext-ms-win-*) continue ;; esac
    case "$AUSNAHMEN" in *" $d "*) echo "  Ausnahme: $d"; continue ;; esac
    # MSVC-Laufzeit gilt nie als Teil von Windows (nur auf dem Bau-Rechner da)
    if ! ist_msvc_laufzeit "$d" && [ -f "/c/Windows/System32/$d" ]; then continue; fi
    fehlt="$fehlt $d"
done
[ -z "$fehlt" ] || fehler "nicht im Buendel und nicht Teil von Windows:$fehlt"
echo "$(importe | wc -l) importierte DLLs, alle im Buendel oder Teil von Windows"

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
