#!/bin/bash
# Baut librwspice gegen eine vorhandene spice-client-glib.
#   ./bauen.sh macos   -> build/macos/librwspice.dylib (gegen MacPorts unter /opt/local)
#   ./bauen.sh linux   -> build/linux/librwspice.so    (Debian 13: apt install libspice-client-glib-2.0-dev)
#
# Windows (MSYS2/mingw64: mingw-w64-x86_64-spice-gtk) und Android (eigener
# Bau von glib/spice-glib mit dem NDK) siehe docs/plattformen.md.
#
# spice-glib wird dynamisch gelinkt (LGPL, siehe rwspice.h).
set -euo pipefail
cd "$(dirname "$0")"
ziel="${1:-macos}"
QUELLEN=(rwspice.c)
WARN=(-Wall -Wextra -Wno-unused-parameter -Wno-deprecated-declarations)

case "$ziel" in
macos)
    export PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-/opt/local/lib/pkgconfig}"
    PKG_CONFIG="${PKG_CONFIG:-/opt/local/bin/pkg-config}"
    mkdir -p build/macos
    # miniaudio braucht auf Apple die Audio-Frameworks; das Laden zur Laufzeit
    # (dlopen) ist dort der Standard von miniaudio, darum nur Grundgeruest.
    clang -O2 -fPIC -dynamiclib -fvisibility=hidden "${WARN[@]}" \
        -mmacosx-version-min=13.0 \
        $($PKG_CONFIG --cflags spice-client-glib-2.0) \
        "${QUELLEN[@]}" \
        $($PKG_CONFIG --libs spice-client-glib-2.0) \
        -framework CoreFoundation -framework CoreAudio -framework AudioToolbox \
        -install_name @rpath/librwspice.dylib \
        -o build/macos/librwspice.dylib
    ;;
linux)
    mkdir -p build/linux
    cc -O2 -fPIC -shared -fvisibility=hidden "${WARN[@]}" \
        $(pkg-config --cflags spice-client-glib-2.0) \
        "${QUELLEN[@]}" \
        $(pkg-config --libs spice-client-glib-2.0) -ldl -lpthread -lm \
        -Wl,-soname,librwspice.so -o build/linux/librwspice.so
    ;;
*) echo "Unbekanntes Ziel: $ziel" >&2; exit 2 ;;
esac
echo "fertig: $ziel"
