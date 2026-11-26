#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Baut spice-client-glib samt Abhaengigkeiten fuer iOS/iPadOS (arm64, Geraet)
# und daraus SpiceGlib.framework (dynamisch, austauschbar; LGPL).
#
#   native/spice-stapel/ios.sh
#
# Danach: native/rwspice/bauen.sh ios (RwNative.framework: rwspice + rwtunnel).
#
# Ergebnis in build/ios-native/ (Xcode bettet beide Frameworks ein, siehe
# ios/Runner.xcodeproj, Phase "Embed Frameworks"):
#   SpiceGlib.framework   spice-glib + GLib/GObject/GIO + GStreamer-Kern +
#                         OpenSSL, pixman, opus, jpeg, json-glib
#   SpiceGlib-BIBLIOTHEKEN.txt
#
# Woher: wie Android (bauen.sh) das offizielle GStreamer-Binaerpaket fuer iOS
# (GLib, GStreamer-Kern, OpenSSL, pixman, opus, libjpeg-turbo, zlib, libffi,
# pcre2, iconv/intl; statisch, fest geprueft), dazu selbst gebaut
# spice-protocol und spice-gtk (nur spice-glib, ohne USB: iOS gibt Apps keinen
# Zugriff auf USB-Geraete; ohne phodav; Koroutinen ueber GThread).
#
# Laeuft auf macOS mit Xcode, meson, ninja, pkg-config, python3 (pyparsing).
set -euo pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
WURZEL="$(cd "$HIER/../.." && pwd)"
# shellcheck source=versionen.sh
. "$HIER/versionen.sh"
GST_IOS_SHA256=818dfad897b2f63162fd22d31c2d41850d619800ceea2450bdc71f27ed32042a
IOS_MIN=15.0  # = IPHONEOS_DEPLOYMENT_TARGET der App

QUELLEN="${RW_STAPEL_QUELLEN:-$HIER/build/quellen}"
ARBEIT="$HIER/build/arbeit/ios-arm64"
PREFIX="$ARBEIT/prefix"
GST="$ARBEIT/gstreamer"
AUS="$WURZEL/build/ios-native"
mkdir -p "$QUELLEN" "$ARBEIT" "$AUS"

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
CC="$(xcrun --sdk iphoneos -f clang)"
AR="$(xcrun --sdk iphoneos -f ar)"
FLAGS=(-arch arm64 -isysroot "$SDK" "-miphoneos-version-min=$IOS_MIN")

schritt() { printf '\n== [ios] %s\n' "$*"; }
holen() { # holen <datei> <url> <sha256>
    local d="$QUELLEN/$1"
    if [ ! -f "$d" ] || [ "$(shasum -a 256 "$d" | cut -d' ' -f1)" != "$3" ]; then
        curl -fsSL --retry 3 -o "$d.teil" "$2"
        mv "$d.teil" "$d"
    fi
    [ "$(shasum -a 256 "$d" | cut -d' ' -f1)" = "$3" ] || { echo "Pruefsumme falsch: $1" >&2; exit 1; }
}
auspacken() { mkdir -p "$ARBEIT/quelle"; tar -xf "$QUELLEN/$1" -C "$ARBEIT/quelle"; }

# ── GStreamer-Binaerpaket (Installer-Paket, nur ausgepackt) ─────────────
schritt "GStreamer $GST_VERSION (Binaerpaket iOS)"
GST_DATEI="gstreamer-1.0-devel-$GST_VERSION-ios-universal.pkg"
holen "$GST_DATEI" "https://gstreamer.freedesktop.org/data/pkg/ios/$GST_VERSION/$GST_DATEI" "$GST_IOS_SHA256"
if [ ! -f "$GST/.fertig" ]; then
    rm -rf "$ARBEIT/gst-pkg" "$GST"
    pkgutil --expand-full "$QUELLEN/$GST_DATEI" "$ARBEIT/gst-pkg"
    # Die Teilpakete legen ihre Dateien unter .../Payload ab; das Framework
    # mit lib/pkgconfig suchen.
    pc="$(find "$ARBEIT/gst-pkg" -path '*/lib/pkgconfig/glib-2.0.pc' | head -n1)"
    [ -n "$pc" ] || { echo "glib-2.0.pc nicht im GStreamer-Paket:"; find "$ARBEIT/gst-pkg" -maxdepth 6 | head -50; exit 1; }
    wurzel="$(dirname "$(dirname "$(dirname "$pc")")")"
    echo "GStreamer-Wurzel im Paket: ${wurzel#"$ARBEIT/gst-pkg/"}"
    # Alle Teilpakete zusammenfuehren (Kopfdateien/Bibliotheken koennen in
    # verschiedenen Payloads liegen)
    mkdir -p "$GST"
    rel="${wurzel#"$ARBEIT/gst-pkg/"}"; rel="${rel#*/Payload}"
    for p in "$ARBEIT"/gst-pkg/*/Payload; do
        [ -d "$p$rel" ] && ditto "$p$rel" "$GST"
    done
    for pc in "$GST"/lib/pkgconfig/*.pc; do
        sed -i '' -e "s|^prefix=.*|prefix=$GST|" "$pc"
    done
    rm -rf "$ARBEIT/gst-pkg"
    touch "$GST/.fertig"
fi
echo "GStreamer-Paket: $(ls "$GST"/lib/pkgconfig | wc -l | tr -d ' ') pkg-config-Eintraege"
lipo -info "$GST/lib/libglib-2.0.a" || true

PKGCFG="$ARBEIT/pkg-config"
cat > "$PKGCFG" <<EOF
#!/bin/sh
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$GST/lib/pkgconfig" PKG_CONFIG_PATH= exec pkg-config --static "\$@"
EOF
chmod +x "$PKGCFG"
KREUZ="$ARBEIT/kreuz.ini"
cat > "$KREUZ" <<EOF
[binaries]
c = '$CC'
objc = '$CC'
ar = '$AR'
strip = '$(xcrun --sdk iphoneos -f strip)'
pkg-config = '$PKGCFG'

[built-in options]
c_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$IOS_MIN', '-fPIC', '-I$PREFIX/include']
c_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$IOS_MIN', '-L$PREFIX/lib']
objc_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$IOS_MIN']
objc_link_args = ['-arch', 'arm64', '-isysroot', '$SDK', '-miphoneos-version-min=$IOS_MIN']
default_library = 'static'
prefix = '$PREFIX'
libdir = 'lib'
buildtype = 'release'
wrap_mode = 'nodownload'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'arm64'
endian = 'little'
EOF
meson_bau() {
    local q="$1"; shift
    rm -rf "$q/_bau"
    meson setup "$q/_bau" "$q" --cross-file "$KREUZ" "$@"
    ninja -C "$q/_bau"
    ninja -C "$q/_bau" install >/dev/null
}

if ! "$PKGCFG" --exists json-glib-1.0; then
    schritt "json-glib $JSON_GLIB"
    holen "json-glib-$JSON_GLIB.tar.xz" "https://download.gnome.org/sources/json-glib/${JSON_GLIB%.*}/json-glib-$JSON_GLIB.tar.xz" "$JSON_GLIB_SHA256"
    auspacken "json-glib-$JSON_GLIB.tar.xz"
    meson_bau "$ARBEIT/quelle/json-glib-$JSON_GLIB" -Dintrospection=disabled -Ddocumentation=disabled \
        -Dman=false -Dtests=false -Dconformance=false -Dnls=disabled -Dinstalled_tests=false
fi

if ! "$PKGCFG" --exists "spice-protocol >= $SPICE_PROTOCOL"; then
    schritt "spice-protocol $SPICE_PROTOCOL"
    holen "spice-protocol-$SPICE_PROTOCOL.tar.xz" "https://www.spice-space.org/download/releases/spice-protocol-$SPICE_PROTOCOL.tar.xz" "$SPICE_PROTOCOL_SHA256"
    auspacken "spice-protocol-$SPICE_PROTOCOL.tar.xz"
    meson_bau "$ARBEIT/quelle/spice-protocol-$SPICE_PROTOCOL"
fi

if [ ! -f "$PREFIX/lib/libspice-client-glib-2.0.a" ]; then
    schritt "spice-gtk $SPICE_GTK (spice-client-glib, ohne USB)"
    holen "spice-gtk-$SPICE_GTK.tar.xz" "https://www.spice-space.org/download/gtk/spice-gtk-$SPICE_GTK.tar.xz" "$SPICE_GTK_SHA256"
    auspacken "spice-gtk-$SPICE_GTK.tar.xz"
    q="$ARBEIT/quelle/spice-gtk-$SPICE_GTK"
    sed -i '' -E "/^subdir\('(tools|tests|man|po|vapi|data)'\)/d; /^    subdir\('doc'\)/d" "$q/meson.build"
    meson_bau "$q" \
        -Dgtk=disabled -Dwebdav=disabled -Dusbredir=disabled -Dpolkit=disabled \
        -Dlibcap-ng=disabled -Dcoroutine=gthread -Dintrospection=disabled -Dvapi=disabled \
        -Dlz4=disabled -Dsasl=disabled -Dsmartcard=disabled -Dopus=enabled -Dgtk_doc=disabled \
        -Degl=disabled -Dwayland-protocols=disabled -Dbuiltin-mjpeg=true -Dpie=false \
        -Dspice-common:tests=false -Dspice-common:manual=false -Dspice-common:python-checks=false
fi

# ── SpiceGlib.framework ─────────────────────────────────────────────────
schritt "SpiceGlib.framework"
FW="$AUS/SpiceGlib.framework"
rm -rf "$FW"; mkdir -p "$FW"
# GLib, GObject, GIO und spice-glib ganz (rwspice ruft sie direkt), der Rest
# soweit gebraucht.
ganz=()
for a in "$PREFIX/lib/libspice-client-glib-2.0.a" "$GST/lib/libglib-2.0.a" "$GST/lib/libgobject-2.0.a" "$GST/lib/libgio-2.0.a"; do
    ganz+=("-Wl,-force_load,$a")
done
# shellcheck disable=SC2046
"$CC" "${FLAGS[@]}" -dynamiclib -o "$FW/SpiceGlib" \
    -install_name @rpath/SpiceGlib.framework/SpiceGlib \
    "${ganz[@]}" $("$PKGCFG" --libs spice-client-glib-2.0) \
    -framework Foundation -framework CoreFoundation -framework Security -lresolv -liconv -lz -lc++
cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>SpiceGlib</string>
  <key>CFBundleIdentifier</key><string>ch.rosenweg4303.vm.spiceglib</string>
  <key>CFBundleName</key><string>SpiceGlib</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>$SPICE_GTK</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict></plist>
EOF

cat > "$ARBEIT/umgebung.sh" <<EOF
CC='$CC'
PKGCFG='$PKGCFG'
SDK='$SDK'
IOS_MIN='$IOS_MIN'
EOF

{
    echo "SpiceGlib.framework (iOS arm64) enthaelt (statisch zusammengefuegt, als Ganzes austauschbar):"
    echo "  spice-gtk $SPICE_GTK (spice-client-glib), spice-protocol $SPICE_PROTOCOL  https://www.spice-space.org/"
    [ -d "$PREFIX/include/json-glib-1.0" ] && echo "  json-glib $JSON_GLIB  https://download.gnome.org/sources/json-glib/"
    echo "  aus dem GStreamer-Binaerpaket $GST_VERSION (https://gstreamer.freedesktop.org/data/pkg/ios/$GST_VERSION/):"
    for m in glib-2.0 gstreamer-1.0 openssl pixman-1 opus libjpeg zlib libffi libpcre2-8; do
        "$PKGCFG" --exists "$m" && printf '    %-14s %s\n' "$m" "$("$PKGCFG" --modversion "$m")"
    done
} > "$AUS/SpiceGlib-BIBLIOTHEKEN.txt"
cat "$AUS/SpiceGlib-BIBLIOTHEKEN.txt"
ls -la "$FW"
echo "fertig: ios"
