#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Baut spice-client-glib samt Abhaengigkeiten fuer die Telefone.
#
#   native/spice-stapel/bauen.sh android <abi>     arm64-v8a | x86_64
#
# Danach: native/rwspice/bauen.sh android <abi> (nimmt Compiler und
# pkg-config aus build/arbeit/android-<abi>/umgebung.sh).
#
# Ergebnis in native/spice-stapel/build/android/<abi>/:
#   libspiceglib.so   spice-glib + GLib/GObject/GIO + GStreamer-Kern + OpenSSL,
#                     pixman, opus, jpeg, json-glib, usbredir, libusb – eine
#                     eigene dynamische Bibliothek, austauschbar (LGPL)
#   BIBLIOTHEKEN.txt  Name, Version und Quelle jeder enthaltenen Bibliothek
#
# Woher (Entscheid docs/plattformen.md, Android):
#   - GLib, GStreamer-Kern, OpenSSL, pixman, opus, libjpeg-turbo, zlib, libffi,
#     pcre2, iconv/intl: die offiziellen GStreamer-Binaerpakete fuer Android
#     (gstreamer.freedesktop.org, LGPL/MIT/BSD, mit cerbero gebaut, statisch).
#     Spart den groessten Teil des Stapels; Pruefsumme fest.
#   - selbst gebaut (meson/autotools mit dem NDK): libusb, usbredir, json-glib
#     (falls nicht im Paket), spice-protocol, spice-gtk (nur spice-glib,
#     ohne GTK, ohne phodav, Koroutinen ueber GThread: Bionic hat kein
#     makecontext).
#
# Laeuft auf Linux x86_64 (GitHub-Runner ubuntu-latest) oder macOS mit NDK,
# meson, ninja, pkg-config, python3 (mit pyparsing), curl, xz.
# Umgebung: ANDROID_NDK_HOME (NDK r28), RW_STAPEL_QUELLEN (Download-Cache).
set -euo pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
ziel="${1:-}"; abi="${2:-}"
[ "$ziel" = android ] || { echo "Aufruf: $0 android <arm64-v8a|x86_64>" >&2; exit 2; }

GST_VERSION=1.28.9
GST_SHA256=04ca3f41c8fc7359c4f92f3705ffee0533890b1f5ea94a49509f1ede0d241a53
SPICE_GTK=0.43;          SPICE_GTK_SHA256=cee26e5b2d22909f35b40a94398d1e863ca3962ee46494ca97aab206abc3203b
SPICE_PROTOCOL=0.14.5;   SPICE_PROTOCOL_SHA256=baf58449f6e89d19f475899ad5fb9196fdc46c03cc53233f4e39cf2978f9cff7
USBREDIR=0.15.0;         USBREDIR_SHA256=6dc2a380277688a068191245dac2ab7063a552999d8ac3ad8e841c10ff050961
LIBUSB=1.0.30;           LIBUSB_SHA256=fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf
JSON_GLIB=1.10.8;        JSON_GLIB_SHA256=55c5c141a564245b8f8fbe7698663c87a45a7333c2a2c56f06f811ab73b212dd
API=24  # = minSdk der App

case "$abi" in
arm64-v8a) GST_ABI=arm64;  TRIPEL=aarch64-linux-android; CPU=aarch64 ;;
x86_64)    GST_ABI=x86_64; TRIPEL=x86_64-linux-android;  CPU=x86_64 ;;
*) echo "Unbekannte ABI: $abi" >&2; exit 2 ;;
esac

QUELLEN="${RW_STAPEL_QUELLEN:-$HIER/build/quellen}"
ARBEIT="$HIER/build/arbeit/android-$abi"
PREFIX="$ARBEIT/prefix"
AUS="$HIER/build/android/$abi"
GST="$ARBEIT/gstreamer"
mkdir -p "$QUELLEN" "$ARBEIT" "$AUS"

: "${ANDROID_NDK_HOME:=${ANDROID_NDK_LATEST_HOME:-$HOME/Library/Android/sdk/ndk/28.2.13676358}}"
host="$(uname -s | tr A-Z a-z)-x86_64"
TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$host"
[ -x "$TC/bin/clang" ] || { echo "NDK fehlt: $TC" >&2; exit 1; }
CC="$TC/bin/${TRIPEL}${API}-clang"
CXX="$TC/bin/${TRIPEL}${API}-clang++"
AR="$TC/bin/llvm-ar"
# 16-KB-Seiten (Android 15+), Pflicht fuer neue Apps
LDSEITEN="-Wl,-z,max-page-size=16384"

schritt() { printf '\n== [%s] %s\n' "$abi" "$*"; }
summe() { if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi | cut -d' ' -f1; }
holen() { # holen <datei> <url> <sha256>
    local d="$QUELLEN/$1"
    if [ ! -f "$d" ] || [ "$(summe "$d")" != "$3" ]; then
        curl -fsSL --retry 3 -o "$d.teil" "$2"
        mv "$d.teil" "$d"
    fi
    [ "$(summe "$d")" = "$3" ] || { echo "Pruefsumme falsch: $1" >&2; exit 1; }
}
auspacken() { # auspacken <datei> -> Ordner unter $ARBEIT/quelle
    mkdir -p "$ARBEIT/quelle"
    tar -xf "$QUELLEN/$1" -C "$ARBEIT/quelle"
}

# ── GStreamer-Binaerpaket (nur die eine ABI auspacken) ──────────────────
schritt "GStreamer $GST_VERSION (Binaerpaket)"
GST_DATEI="gstreamer-1.0-android-universal-$GST_VERSION.tar.xz"
holen "$GST_DATEI" "https://gstreamer.freedesktop.org/data/pkg/android/$GST_VERSION/$GST_DATEI" "$GST_SHA256"
if [ ! -f "$GST/.fertig" ]; then
    rm -rf "$GST" "$ARBEIT/gst-roh"; mkdir -p "$ARBEIT/gst-roh"
    tar -xJf "$QUELLEN/$GST_DATEI" -C "$ARBEIT/gst-roh" --wildcards "$GST_ABI/*" "./$GST_ABI/*" 2>/dev/null \
        || tar -xJf "$QUELLEN/$GST_DATEI" -C "$ARBEIT/gst-roh" "$GST_ABI"
    mv "$ARBEIT/gst-roh/$GST_ABI" "$GST"; rm -rf "$ARBEIT/gst-roh"
    # .pc-Dateien zeigen auf den Bau-Rechner von cerbero
    for pc in "$GST"/lib/pkgconfig/*.pc; do
        sed -i.alt -e "s|^prefix=.*|prefix=$GST|" "$pc" && rm -f "$pc.alt"
    done
    touch "$GST/.fertig"
fi
echo "GStreamer-Paket: $(ls "$GST"/lib/pkgconfig | wc -l) pkg-config-Eintraege"

# ── Werkzeuge fuer den Kreuzbau ─────────────────────────────────────────
mkdir -p "$PREFIX/lib/pkgconfig"
PKGCFG="$ARBEIT/pkg-config"
cat > "$PKGCFG" <<EOF
#!/bin/sh
# nur die Zielbibliotheken, immer statisch (Abhaengigkeiten der .a mitnehmen)
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$GST/lib/pkgconfig" PKG_CONFIG_PATH= exec pkg-config --static "\$@"
EOF
chmod +x "$PKGCFG"
KREUZ="$ARBEIT/kreuz.ini"
cat > "$KREUZ" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$TC/bin/llvm-strip'
pkg-config = '$PKGCFG'

[built-in options]
c_args = ['-fPIC', '-I$PREFIX/include']
c_link_args = ['-L$PREFIX/lib', '$LDSEITEN']
default_library = 'static'
prefix = '$PREFIX'
libdir = 'lib'
buildtype = 'release'
wrap_mode = 'nodownload'

[host_machine]
system = 'android'
cpu_family = '$CPU'
cpu = '$CPU'
endian = 'little'
EOF
meson_bau() { # meson_bau <quellordner> <optionen...>
    local q="$1"; shift
    rm -rf "$q/_bau"
    meson setup "$q/_bau" "$q" --cross-file "$KREUZ" "$@"
    ninja -C "$q/_bau"
    ninja -C "$q/_bau" install >/dev/null
}

# ── libusb ──────────────────────────────────────────────────────────────
if [ ! -f "$PREFIX/lib/libusb-1.0.a" ]; then
    schritt "libusb $LIBUSB"
    holen "libusb-$LIBUSB.tar.bz2" "https://github.com/libusb/libusb/releases/download/v$LIBUSB/libusb-$LIBUSB.tar.bz2" "$LIBUSB_SHA256"
    auspacken "libusb-$LIBUSB.tar.bz2"
    (cd "$ARBEIT/quelle/libusb-$LIBUSB" \
        && ./configure -q --host="$TRIPEL" --prefix="$PREFIX" --enable-static --disable-shared \
             --disable-udev --disable-examples-build --disable-tests-build \
             CC="$CC" AR="$AR" RANLIB="$TC/bin/llvm-ranlib" CFLAGS="-O2 -fPIC" \
        && make -s -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" && make -s install)
fi

# ── usbredir ────────────────────────────────────────────────────────────
if [ ! -f "$PREFIX/lib/libusbredirhost.a" ]; then
    schritt "usbredir $USBREDIR"
    holen "usbredir-$USBREDIR.tar.xz" "https://www.spice-space.org/download/usbredir/usbredir-$USBREDIR.tar.xz" "$USBREDIR_SHA256"
    auspacken "usbredir-$USBREDIR.tar.xz"
    meson_bau "$ARBEIT/quelle/usbredir-$USBREDIR" -Dtools=disabled -Dfuzzing=disabled -Dtests=disabled -Dgit_werror=disabled
fi

# ── json-glib (falls das GStreamer-Paket es nicht hat) ──────────────────
if ! "$PKGCFG" --exists json-glib-1.0; then
    schritt "json-glib $JSON_GLIB"
    holen "json-glib-$JSON_GLIB.tar.xz" "https://download.gnome.org/sources/json-glib/${JSON_GLIB%.*}/json-glib-$JSON_GLIB.tar.xz" "$JSON_GLIB_SHA256"
    auspacken "json-glib-$JSON_GLIB.tar.xz"
    meson_bau "$ARBEIT/quelle/json-glib-$JSON_GLIB" -Dintrospection=disabled -Ddocumentation=disabled \
        -Dman=false -Dtests=false -Dconformance=false -Dnls=disabled -Dinstalled_tests=false
fi

# ── spice-protocol ──────────────────────────────────────────────────────
if ! "$PKGCFG" --exists "spice-protocol >= $SPICE_PROTOCOL"; then
    schritt "spice-protocol $SPICE_PROTOCOL"
    holen "spice-protocol-$SPICE_PROTOCOL.tar.xz" "https://www.spice-space.org/download/releases/spice-protocol-$SPICE_PROTOCOL.tar.xz" "$SPICE_PROTOCOL_SHA256"
    auspacken "spice-protocol-$SPICE_PROTOCOL.tar.xz"
    meson_bau "$ARBEIT/quelle/spice-protocol-$SPICE_PROTOCOL"
fi

# ── spice-gtk (nur spice-client-glib) ───────────────────────────────────
if [ ! -f "$PREFIX/lib/libspice-client-glib-2.0.a" ]; then
    schritt "spice-gtk $SPICE_GTK (spice-client-glib)"
    holen "spice-gtk-$SPICE_GTK.tar.xz" "https://www.spice-space.org/download/gtk/spice-gtk-$SPICE_GTK.tar.xz" "$SPICE_GTK_SHA256"
    auspacken "spice-gtk-$SPICE_GTK.tar.xz"
    q="$ARBEIT/quelle/spice-gtk-$SPICE_GTK"
    # Werkzeuge, Tests, Handbuch, Uebersetzungen, Vala braucht die Bibliothek nicht
    sed -i.alt -E "/^subdir\('(tools|tests|man|po|vapi|data)'\)/d; /^    subdir\('doc'\)/d" "$q/meson.build"
    meson_bau "$q" \
        -Dgtk=disabled -Dwebdav=disabled -Dusbredir=enabled -Dpolkit=disabled \
        -Dlibcap-ng=disabled -Dcoroutine=gthread -Dintrospection=disabled -Dvapi=disabled \
        -Dlz4=disabled -Dsasl=disabled -Dsmartcard=disabled -Dopus=enabled -Dgtk_doc=disabled \
        -Degl=disabled -Dwayland-protocols=disabled -Dbuiltin-mjpeg=true -Dpie=false \
        -Dspice-common:tests=false -Dspice-common:manual=false -Dspice-common:python-checks=false
fi

# ── eine dynamische Bibliothek aus allem ────────────────────────────────
schritt "libspiceglib.so"
# GLib, GObject, GIO und spice-glib ganz: rwspice ruft sie direkt. Der Rest
# nur, soweit gebraucht (pkg-config --static loest die Kette auf).
ganz=("$PREFIX/lib/libspice-client-glib-2.0.a" "$GST/lib/libglib-2.0.a" "$GST/lib/libgobject-2.0.a" "$GST/lib/libgio-2.0.a")
# shellcheck disable=SC2046
"$CC" -shared -o "$AUS/libspiceglib.so" -Wl,-soname,libspiceglib.so $LDSEITEN \
    -Wl,--whole-archive "${ganz[@]}" -Wl,--no-whole-archive \
    $("$PKGCFG" --libs spice-client-glib-2.0) -llog -lm -ldl -lz \
    -Wl,--no-undefined -Wl,--exclude-libs,libunwind.a
"$TC/bin/llvm-strip" --strip-unneeded "$AUS/libspiceglib.so"

# Fuer native/rwspice/bauen.sh android: Compiler und pkg-config dieses Stapels
cat > "$ARBEIT/umgebung.sh" <<EOF
CC='$CC'
PKGCFG='$PKGCFG'
LDSEITEN='$LDSEITEN'
STRIP='$TC/bin/llvm-strip'
SPICEGLIB_DIR='$AUS'
EOF

{
    echo "libspiceglib.so ($abi) enthaelt (statisch zusammengefuegt, als Ganzes austauschbar):"
    echo "  spice-gtk $SPICE_GTK (spice-client-glib), spice-protocol $SPICE_PROTOCOL  https://www.spice-space.org/"
    echo "  usbredir $USBREDIR  https://www.spice-space.org/download/usbredir/"
    echo "  libusb $LIBUSB  https://github.com/libusb/libusb"
    "$PKGCFG" --exists json-glib-1.0 && [ -d "$PREFIX/include/json-glib-1.0" ] \
        && echo "  json-glib $JSON_GLIB  https://download.gnome.org/sources/json-glib/"
    echo "  aus dem GStreamer-Binaerpaket $GST_VERSION (https://gstreamer.freedesktop.org/data/pkg/android/$GST_VERSION/,"
    echo "  Quellen: https://gstreamer.freedesktop.org/src/ und cerbero-Rezepte):"
    for m in glib-2.0 gstreamer-1.0 openssl pixman-1 opus libjpeg zlib libffi libpcre2-8; do
        "$PKGCFG" --exists "$m" && printf '    %-14s %s\n' "$m" "$("$PKGCFG" --modversion "$m")"
    done
} > "$AUS/BIBLIOTHEKEN.txt"
cat "$AUS/BIBLIOTHEKEN.txt"
ls -la "$AUS/libspiceglib.so"
echo "fertig: android $abi"
