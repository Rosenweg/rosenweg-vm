#!/bin/bash
# Baut die ausgelieferte macOS-App und das DMG.
#
#   macos/installer/bauen.sh [--ohne-native] [--ohne-flutter] [--ohne-dmg]
#
# Ergebnis in build/macos-installer/:
#   Rosenweg Virtuelle Computer.app      vollstaendig, ohne Entwicklerumgebung
#   Rosenweg-Virtuelle-Computer-<v>.dmg  Installer (Hintergrund, Programme-Verknuepfung)
#
# Schritte:
#   1. native Bibliotheken (rwtunnel, rwspice) bauen
#   2. flutter build macos --release
#   3. librwtunnel, librwspice und alle abhaengigen dylibs (MacPorts unter
#      /opt/local, ebenso Homebrew) nach Contents/Frameworks kopieren und deren
#      Pfade auf @rpath umschreiben
#   4. Architektur: universal, wenn alle Bibliotheken x86_64 mitbringen,
#      sonst alles auf arm64 verduennen (MacPorts baut nur arm64)
#   5. signieren: mit "Developer ID Application", wenn vorhanden (Hardened
#      Runtime, Zeitstempel), sonst ad hoc
#   6. DMG (dmgbuild), signieren, notarisieren und heften, wenn moeglich
#
# Umgebung (alles optional):
#   RW_SIGNIER_ID     codesign-Identitaet; leer = erste "Developer ID
#                     Application" im Schluesselbund, sonst "-" (ad hoc)
#   RW_NOTAR_PROFIL   notarytool-Schluesselbundprofil (xcrun notarytool
#                     store-credentials <name> …); Standard: rosenweg-notar,
#                     falls vorhanden
#   RW_NOTAR_KEY, RW_NOTAR_KEY_ID, RW_NOTAR_ISSUER
#                     statt Profil: App-Store-Connect-API-Schluessel (.p8-Datei,
#                     Key-ID, Issuer-ID) - so im GitHub-Workflow
#   RW_PREFIX         woher die Bibliotheken kommen (Standard /opt/local); nur
#                     fuer die Pruefung "nichts zeigt mehr nach aussen"
#
# Laeuft mit dem bash 3.2 von macOS (keine assoziativen Felder).
set -euo pipefail

WURZEL="$(cd "$(dirname "$0")/../.." && pwd)"
HIER="$WURZEL/macos/installer"
AUS="$WURZEL/build/macos-installer"
NAME="Rosenweg Virtuelle Computer"
DATEINAME="Rosenweg-Virtuelle-Computer"
RW_PREFIX="${RW_PREFIX:-/opt/local}"

NATIVE=1 FLUTTER=1 DMG=1
for a in "$@"; do
    case "$a" in
    --ohne-native) NATIVE=0 ;;
    --ohne-flutter) FLUTTER=0 ;;
    --ohne-dmg) DMG=0 ;;
    -h|--help) sed -n '2,33p' "$0"; exit 0 ;;
    *) echo "Unbekannte Option: $a" >&2; exit 2 ;;
    esac
done

schritt() { printf '\n== %s\n' "$*"; }
fehler() { echo "FEHLER: $*" >&2; exit 1; }

cd "$WURZEL"
VERSION="$(sed -n 's/^version: *\([0-9.]*\)+\{0,1\}\([0-9]*\).*/\1/p' pubspec.yaml)"
[ -n "$VERSION" ] || fehler "Version aus pubspec.yaml nicht lesbar"

# ── 1. native Bibliotheken ─────────────────────────────────────────────
if [ "$NATIVE" = 1 ]; then
    schritt "native Bibliotheken"
    native/rwtunnel/bauen.sh macos
    native/rwspice/bauen.sh macos
fi
for f in native/rwtunnel/build/macos/librwtunnel.dylib native/rwspice/build/macos/librwspice.dylib; do
    [ -f "$f" ] || fehler "$f fehlt (ohne --ohne-native bauen)"
done

# ── 2. Flutter ─────────────────────────────────────────────────────────
if [ "$FLUTTER" = 1 ]; then
    schritt "flutter build macos --release"
    flutter build macos --release
fi
QUELLE="build/macos/Build/Products/Release/$NAME.app"
[ -d "$QUELLE" ] || fehler "$QUELLE fehlt"

schritt "Buendel zusammenstellen"
rm -rf "$AUS"
mkdir -p "$AUS"
APP="$AUS/$NAME.app"
ditto "$QUELLE" "$APP"
FW="$APP/Contents/Frameworks"
mkdir -p "$FW"

# ── 3. Bibliotheken buendeln ───────────────────────────────────────────
# Alles, was nicht zum System gehoert (/System, /usr/lib) und noch nicht
# relativ (@…) ist, kommt nach Frameworks/ und wird als @rpath/<name>
# eingetragen. Jede kopierte Bibliothek sucht selbst neben sich
# (@loader_path); die App hat @executable_path/../Frameworks schon.
abhaengigkeiten() { # abhaengigkeiten <dylib> -> Pfade (ohne eigene Kennung)
    local eigene
    eigene="$(otool -D "$1" | sed -n '2p')"
    otool -L "$1" | sed -n 's/^[[:space:]]\{1,\}\(.*\) (compat.*/\1/p' | sort -u | grep -vxF "${eigene:-//}" || true
}
fremd() { case "$1" in /System/*|/usr/lib/*|@*) return 1 ;; *) return 0 ;; esac; }

cp native/rwtunnel/build/macos/librwtunnel.dylib native/rwspice/build/macos/librwspice.dylib "$FW/"
WARTEN="$FW/librwtunnel.dylib
$FW/librwspice.dylib"
GEBUENDELT=""
while [ -n "$WARTEN" ]; do
    f="$(printf '%s\n' "$WARTEN" | head -n1)"
    WARTEN="$(printf '%s\n' "$WARTEN" | sed '1d')"
    chmod u+w "$f"
    for d in $(abhaengigkeiten "$f"); do
        case "$d" in
        @rpath/*)
            [ -f "$FW/${d#@rpath/}" ] || fehler "$(basename "$f") braucht $d, das nicht im Buendel liegt" ;;
        esac
        fremd "$d" || continue
        n="$(basename "$d")"
        if [ ! -f "$FW/$n" ]; then
            [ -f "$d" ] || fehler "$d (von $(basename "$f")) fehlt"
            cp -L "$d" "$FW/$n"
            chmod u+w "$FW/$n"
            GEBUENDELT="$GEBUENDELT $d"
            WARTEN="$(printf '%s\n%s' "$WARTEN" "$FW/$n" | sed '/^$/d')"
        fi
        install_name_tool -change "$d" "@rpath/$n" "$f" 2>/dev/null
    done
    n="$(basename "$f")"
    install_name_tool -id "@rpath/$n" "$f" 2>/dev/null
    # Fremde rpaths (Bau-Rechner) entfernen, @loader_path eintragen.
    for r in $(otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}'); do
        [ "$r" = "@loader_path" ] || install_name_tool -delete_rpath "$r" "$f" 2>/dev/null
    done
    otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -qx '@loader_path' \
        || install_name_tool -add_rpath @loader_path "$f" 2>/dev/null
done
echo "gebuendelt: $(echo $GEBUENDELT | wc -w | tr -d ' ') Bibliotheken aus dem System, dazu librwtunnel, librwspice"

# GStreamer und GIO suchen Module unter Contents/PlugIns (siehe buendel_pfade
# in rwspice.c); dort liegt bewusst nichts, damit nichts vom Bau-Rechner
# nachgeladen wird. rwspice braucht keine GStreamer-Plugins.

# Herkunft fuer die Lizenzpflichten (LGPL: welche Version, woher).
LIZ="$APP/Contents/Resources/Lizenzen"
mkdir -p "$LIZ"
cp LICENSE LIZENZEN.md native/rwspice/drittanbieter/LICENSE-miniaudio "$LIZ/"
{
    echo "Mitgelieferte Bibliotheken in Contents/Frameworks (Quelle beim Bau):"
    echo
    REG="$RW_PREFIX/var/macports/registry/registry.db"
    for d in $GEBUENDELT; do
        port=""
        if [ -f "$REG" ] && command -v sqlite3 >/dev/null; then
            port="$(sqlite3 "$REG" "select p.name||' '||p.version||'_'||p.revision from files f join ports p on f.id=p.id where f.actual_path='$(realpath "$d")' or f.path='$d' limit 1" 2>/dev/null || true)"
        fi
        printf '%-34s %s\n' "$(basename "$d")" "${port:+MacPorts $port}${port:-$d}"
    done
    echo
    echo "Quelltext: https://github.com/macports/macports-ports (Portfiles mit Quell-URLs);"
    echo "auf Anfrage liefert das Haus den Quelltext der ausgelieferten Fassung (siehe LIZENZEN.md)."
} > "$LIZ/BIBLIOTHEKEN.txt"

# ── 4. Architektur ─────────────────────────────────────────────────────
macho() { # alle Mach-O-Dateien im Buendel
    find "$APP" -type f \( -perm -u+x -o -name '*.dylib' \) -print0 | while IFS= read -r -d '' f; do
        lipo -archs "$f" >/dev/null 2>&1 && printf '%s\n' "$f"
    done
}
UNIVERSAL=1
for f in "$FW"/*.dylib; do
    case " $(lipo -archs "$f") " in *" x86_64 "*) ;; *) UNIVERSAL=0; echo "nur $(lipo -archs "$f"): $(basename "$f")"; break ;; esac
done
if [ "$UNIVERSAL" = 1 ]; then
    ARCH="arm64 x86_64"
else
    ARCH="arm64"
    schritt "auf arm64 verduennen (spice-Stapel ohne x86_64)"
    macho | while IFS= read -r f; do
        a="$(lipo -archs "$f")"
        [ "$a" = "arm64" ] && continue
        case " $a " in *" arm64 "*) lipo -thin arm64 "$f" -output "$f.duenn" && mv "$f.duenn" "$f" ;;
        *) fehler "$f hat kein arm64 ($a)" ;; esac
    done
fi

# Mindestversion = hoechste minos aller Bibliotheken (MacPorts baut fuer das
# System, auf dem es laeuft). Sonst startet die App auf aelterem macOS und
# stuerzt erst beim Laden von spice-glib ab.
MINOS="$(macho | while IFS= read -r f; do vtool -arch arm64 -show-build "$f" 2>/dev/null | awk '/minos/{print $2; exit}'; done | sort -t. -k1,1n -k2,2n | tail -n1)"
PL="$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion ${MINOS:-13.0}" "$PL"
[ "$ARCH" = "arm64" ] && /usr/libexec/PlistBuddy -c "Add :LSArchitecturePriority array" -c "Add :LSArchitecturePriority:0 string arm64" "$PL" 2>/dev/null || true
echo "Architektur: $ARCH, macOS ab ${MINOS:-13.0}"

# Pruefung: nichts zeigt mehr auf den Bau-Rechner.
schritt "Pfade pruefen"
schlecht=0
while IFS= read -r f; do
    if otool -L "$f" | sed '1d' | grep -E "^[[:space:]]+($RW_PREFIX|/opt/homebrew|/usr/local)/" >/dev/null; then
        echo "zeigt nach aussen: $f"; otool -L "$f" | grep -E "($RW_PREFIX|/opt/homebrew|/usr/local)/"; schlecht=1
    fi
    # rpaths nur bei den eigenen Bibliotheken pruefen: die Flutter-Engine
    # bringt ab Werk ein /usr/local/lib mit (nicht unser Bau, dort liegt nichts).
    case "$f" in "$FW"/*.dylib) ;; *) continue ;; esac
    if otool -l "$f" | awk '/cmd LC_RPATH/{getline; getline; print $2}' | grep -E "^($RW_PREFIX|/opt/homebrew|/usr/local|/Users)" >/dev/null; then
        echo "rpath nach aussen: $f"; schlecht=1
    fi
done < <(macho)
[ "$schlecht" = 0 ] || fehler "Buendel nicht in sich geschlossen"
echo "ok: nur @rpath, @executable_path, @loader_path, /System, /usr/lib"

# ── 5. Signieren ───────────────────────────────────────────────────────
schritt "Signieren"
if [ -z "${RW_SIGNIER_ID:-}" ]; then
    RW_SIGNIER_ID="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n1)"
    RW_SIGNIER_ID="${RW_SIGNIER_ID:--}"
fi
ENT="$WURZEL/macos/Runner/Release.entitlements"
if [ "$RW_SIGNIER_ID" = "-" ]; then
    echo "keine Developer-ID-Identitaet: ad hoc (Gatekeeper fragt beim ersten Start)"
    SIG=(--force --sign - --timestamp=none)
else
    echo "Identitaet: $RW_SIGNIER_ID (Hardened Runtime)"
    SIG=(--force --sign "$RW_SIGNIER_ID" --timestamp --options runtime)
fi
# Von innen nach aussen: Bibliotheken, Frameworks, App.
signieren() { codesign "${SIG[@]}" "$@" 2>&1 | grep -v "replacing existing signature" || true; }
for f in "$FW"/*.dylib "$FW"/*.framework; do signieren "$f"; done
signieren --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
if [ "$RW_SIGNIER_ID" != "-" ]; then
    spctl --assess --type execute --verbose "$APP" || echo "(Gatekeeper lehnt vor der Notarisierung ab; das ist erwartet)"
fi

[ "$DMG" = 1 ] || { echo "fertig: $APP"; exit 0; }

# ── 6. DMG ─────────────────────────────────────────────────────────────
schritt "DMG"
VENV="$WURZEL/build/dmgbuild-venv"
if [ ! -x "$VENV/bin/dmgbuild" ]; then
    python3 -m venv "$VENV"
    "$VENV/bin/pip" install -q --disable-pip-version-check "dmgbuild==1.6.7"
fi
tiffutil -cathidpicheck "$HIER/hintergrund.png" "$HIER/hintergrund@2x.png" -out "$AUS/hintergrund.tiff" >/dev/null
SYMBOL="$APP/Contents/Resources/AppIcon.icns"
[ -f "$SYMBOL" ] || fehler "$SYMBOL fehlt"
DMG_DATEI="$AUS/$DATEINAME-$VERSION.dmg"
"$VENV/bin/dmgbuild" -s "$HIER/dmg-einstellungen.py" \
    -D app="$APP" -D hintergrund="$AUS/hintergrund.tiff" -D symbol="$SYMBOL" \
    "$NAME" "$DMG_DATEI"

if [ "$RW_SIGNIER_ID" != "-" ]; then
    codesign --force --sign "$RW_SIGNIER_ID" --timestamp "$DMG_DATEI"
    NOTAR=()
    if [ -n "${RW_NOTAR_KEY:-}" ] && [ -n "${RW_NOTAR_KEY_ID:-}" ] && [ -n "${RW_NOTAR_ISSUER:-}" ]; then
        NOTAR=(--key "$RW_NOTAR_KEY" --key-id "$RW_NOTAR_KEY_ID" --issuer "$RW_NOTAR_ISSUER")
    else
        P="${RW_NOTAR_PROFIL:-rosenweg-notar}"
        if xcrun notarytool history --keychain-profile "$P" >/dev/null 2>&1; then
            NOTAR=(--keychain-profile "$P")
        fi
    fi
    if [ ${#NOTAR[@]} -gt 0 ]; then
        schritt "Notarisieren (dauert einige Minuten)"
        xcrun notarytool submit "$DMG_DATEI" "${NOTAR[@]}" --wait
        xcrun stapler staple "$DMG_DATEI"
        spctl --assess --type open --context context:primary-signature --verbose "$DMG_DATEI"
    else
        echo "kein notarytool-Profil: DMG signiert, aber nicht notarisiert"
    fi
fi
echo
echo "fertig: $DMG_DATEI"
