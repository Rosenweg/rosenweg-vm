#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Baut spice-client-glib samt Abhaengigkeiten fuer die Telefone.
#
#   native/spice-stapel/bauen.sh android <abi>     arm64-v8a | x86_64
#   (iOS: native/spice-stapel/ios.sh)
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
#     (falls nicht im Paket), fuer "Ordner freigeben" phodav mit libsoup 3,
#     libxml2, sqlite, nghttp2, libpsl (je nur, falls nicht im Paket),
#     spice-protocol, spice-gtk (nur spice-glib, ohne GTK, mit WebDAV,
#     Koroutinen ueber GThread: Bionic hat kein makecontext).
#
# Laeuft auf Linux x86_64 (GitHub-Runner ubuntu-latest) oder macOS mit NDK,
# meson, ninja, pkg-config, python3 (mit pyparsing), curl, xz.
# Umgebung: ANDROID_NDK_HOME (NDK r28), RW_STAPEL_QUELLEN (Download-Cache).
set -euo pipefail

HIER="$(cd "$(dirname "$0")" && pwd)"
ziel="${1:-}"; abi="${2:-}"
[ "$ziel" = android ] || { echo "Aufruf: $0 android <arm64-v8a|x86_64>" >&2; exit 2; }

# shellcheck source=versionen.sh
. "$HIER/versionen.sh"
GST_SHA256=04ca3f41c8fc7359c4f92f3705ffee0533890b1f5ea94a49509f1ede0d241a53
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
PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig:$GST/lib/pkgconfig" PKG_CONFIG_PATH= exec pkg-config --static "\$@"
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

# ── WebDAV ("Ordner freigeben"): phodav samt libsoup 3 ──────────────────
# spice-glib bringt den WebDAV-Server nur mit phodav mit. phodav braucht
# libsoup 3 und libxml2, libsoup 3 braucht sqlite, nghttp2 und libpsl. Was das
# GStreamer-Paket schon hat, wird nicht neu gebaut. Werkzeuge, Tests, Beispiele,
# Handbuch und Uebersetzungen braucht die Bibliothek nicht.
ohne_subdirs() { # ohne_subdirs <meson.build> <name...>
    local f="$1"; shift
    for n in "$@"; do
        sed -i.alt -E "/^[[:space:]]*subdir\(('${n//\//\\/}'|join_paths\('${n//\//\\/}'.*\))\)/d" "$f"
    done
    rm -f "$f.alt"
}
mkdir -p "$PREFIX/include"
if ! "$PKGCFG" --exists sqlite3; then
    schritt "sqlite $SQLITE"
    holen "sqlite-autoconf-$SQLITE_NR.tar.gz" "https://www.sqlite.org/$SQLITE_JAHR/sqlite-autoconf-$SQLITE_NR.tar.gz" "$SQLITE_SHA256"
    auspacken "sqlite-autoconf-$SQLITE_NR.tar.gz"
    q="$ARBEIT/quelle/sqlite-autoconf-$SQLITE_NR"
    # Nur die Amalgamation, ohne configure: eine Datei, eine .a
    "$CC" -O2 -fPIC -DSQLITE_THREADSAFE=1 -DSQLITE_OMIT_LOAD_EXTENSION=1 -DSQLITE_DQS=0 \
        -c "$q/sqlite3.c" -o "$q/sqlite3.o"
    rm -f "$PREFIX/lib/libsqlite3.a"
    "$AR" rcs "$PREFIX/lib/libsqlite3.a" "$q/sqlite3.o"
    cp "$q/sqlite3.h" "$q/sqlite3ext.h" "$PREFIX/include/"
    cat > "$PREFIX/lib/pkgconfig/sqlite3.pc" <<PC
prefix=$PREFIX
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: SQLite
Description: SQL database engine
Version: $SQLITE
Libs: -L\${libdir} -lsqlite3
Libs.private: -lm
Cflags: -I\${includedir}
PC
fi
if ! "$PKGCFG" --exists libnghttp2; then
    schritt "nghttp2 $NGHTTP2"
    holen "nghttp2-$NGHTTP2.tar.xz" "https://github.com/nghttp2/nghttp2/releases/download/v$NGHTTP2/nghttp2-$NGHTTP2.tar.xz" "$NGHTTP2_SHA256"
    auspacken "nghttp2-$NGHTTP2.tar.xz"
    (cd "$ARBEIT/quelle/nghttp2-$NGHTTP2" \
        && ./configure -q --host="$TRIPEL" --prefix="$PREFIX" --enable-lib-only --enable-static --disable-shared \
             CC="$CC" CXX="$CXX" AR="$AR" RANLIB="$TC/bin/llvm-ranlib" CFLAGS="-O2 -fPIC" CXXFLAGS="-O2 -fPIC" \
        && make -s -j"$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)" && make -s install)
fi
if ! "$PKGCFG" --exists libpsl; then
    schritt "libpsl $LIBPSL"
    holen "libpsl-$LIBPSL.tar.gz" "https://github.com/rockdaboot/libpsl/releases/download/$LIBPSL/libpsl-$LIBPSL.tar.gz" "$LIBPSL_SHA256"
    auspacken "libpsl-$LIBPSL.tar.gz"
    q="$ARBEIT/quelle/libpsl-$LIBPSL"
    ohne_subdirs "$q/meson.build" tools docs
    # Ohne eingebaute Liste und ohne IDNA: libsoup braucht libpsl nur fuer
    # Cookies, die es hier nicht gibt.
    meson_bau "$q" -Druntime=no -Dbuiltin=false -Dtests=false -Ddocs=false
fi
if ! "$PKGCFG" --exists libxml-2.0; then
    schritt "libxml2 $LIBXML2"
    holen "libxml2-$LIBXML2.tar.xz" "https://download.gnome.org/sources/libxml2/${LIBXML2%.*}/libxml2-$LIBXML2.tar.xz" "$LIBXML2_SHA256"
    auspacken "libxml2-$LIBXML2.tar.xz"
    q="$ARBEIT/quelle/libxml2-$LIBXML2"
    ohne_subdirs "$q/meson.build" example doc python
    meson_bau "$q" -Diconv=disabled -Dicu=disabled -Dlzma=disabled -Dzlib=disabled -Dpython=disabled \
        -Dreadline=disabled -Dhistory=disabled -Dhttp=disabled -Dmodules=disabled
fi
if ! "$PKGCFG" --exists libsoup-3.0; then
    schritt "libsoup $LIBSOUP"
    holen "libsoup-$LIBSOUP.tar.xz" "https://download.gnome.org/sources/libsoup/${LIBSOUP%.*}/libsoup-$LIBSOUP.tar.xz" "$LIBSOUP_SHA256"
    auspacken "libsoup-$LIBSOUP.tar.xz"
    q="$ARBEIT/quelle/libsoup-$LIBSOUP"
    ohne_subdirs "$q/meson.build" po examples fuzzing docs/reference
    meson_bau "$q" -Dgssapi=disabled -Dntlm=disabled -Dbrotli=disabled -Dtls_check=false \
        -Dintrospection=disabled -Dvapi=disabled -Ddocs=disabled -Dtests=false -Dautobahn=disabled \
        -Dsysprof=disabled -Dpkcs11_tests=disabled
fi
if ! "$PKGCFG" --exists libphodav-3.0; then
    schritt "phodav $PHODAV"
    holen "phodav-$PHODAV.tar.xz" "https://download.gnome.org/sources/phodav/$PHODAV/phodav-$PHODAV.tar.xz" "$PHODAV_SHA256"
    auspacken "phodav-$PHODAV.tar.xz"
    q="$ARBEIT/quelle/phodav-$PHODAV"
    ohne_subdirs "$q/meson.build" po bin doc data tests
    meson_bau "$q" -Davahi=disabled -Dgtk_doc=disabled
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
        -Dgtk=disabled -Dwebdav=enabled -Dusbredir=enabled -Dpolkit=disabled \
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
    for m in "libphodav-3.0 https://download.gnome.org/sources/phodav/" "libsoup-3.0 https://download.gnome.org/sources/libsoup/" \
             "libxml-2.0 https://download.gnome.org/sources/libxml2/" "libnghttp2 https://github.com/nghttp2/nghttp2" \
             "libpsl https://github.com/rockdaboot/libpsl" "sqlite3 https://www.sqlite.org/"; do
        # shellcheck disable=SC2086
        set -- $m
        [ -f "$PREFIX/lib/pkgconfig/$1.pc" ] && printf '  %s %s  %s\n' "$1" "$("$PKGCFG" --modversion "$1")" "$2"
    done
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
