#!/bin/bash
# Baut librwspice gegen eine vorhandene spice-client-glib.
#   ./bauen.sh macos   -> build/macos/librwspice.dylib (gegen MacPorts unter /opt/local)
#   ./bauen.sh linux   -> build/linux/librwspice.so    (Debian 13: apt install libspice-client-glib-2.0-dev)
#   ./bauen.sh windows -> build/windows/rwspice.dll    (MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-{gcc,pkgconf,spice-gtk})
#
#   ./bauen.sh android <abi> -> build/android/<abi>/librwspice.so (vorher
#                               native/spice-stapel/bauen.sh android <abi>)
#
# iOS siehe docs/plattformen.md.
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
        $($PKG_CONFIG --cflags spice-client-glib-2.0 libusb-1.0) \
        "${QUELLEN[@]}" \
        $($PKG_CONFIG --libs spice-client-glib-2.0 libusb-1.0) \
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
windows)
    # In der MSYS2-Shell (UCRT64). Reines C-ABI, passt zum MSVC-gebauten
    # Runner von Flutter; die DLLs von spice-glib kopiert
    # windows/installer/bauen.sh neben die .exe. psapi: Modulliste fuer
    # rw_spice_ordner_moeglich; ole32: WASAPI (miniaudio).
    mkdir -p build/windows
    gcc -O2 -shared "${WARN[@]}" \
        $(pkg-config --cflags spice-client-glib-2.0) \
        "${QUELLEN[@]}" \
        $(pkg-config --libs spice-client-glib-2.0) -lpsapi -lole32 \
        -static-libgcc -Wl,--out-implib,build/windows/librwspice.dll.a \
        -o build/windows/rwspice.dll
    ;;
android)
    abi="${2:-arm64-v8a}"
    umg="../spice-stapel/build/arbeit/android-$abi/umgebung.sh"
    [ -f "$umg" ] || { echo "Zuerst native/spice-stapel/bauen.sh android $abi" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$umg"
    mkdir -p "build/android/$abi"
    # spice-glib und GLib kommen aus libspiceglib.so (eigene .so, austauschbar)
    "$CC" -O2 -fPIC -shared -fvisibility=hidden "${WARN[@]}" \
        $("$PKGCFG" --cflags spice-client-glib-2.0) \
        "${QUELLEN[@]}" \
        -L"$SPICEGLIB_DIR" -lspiceglib -llog -lm -ldl $LDSEITEN -Wl,--no-undefined \
        -Wl,-soname,librwspice.so -o "build/android/$abi/librwspice.so"
    "$STRIP" --strip-unneeded "build/android/$abi/librwspice.so"
    ;;
*) echo "Unbekanntes Ziel: $ziel" >&2; exit 2 ;;
esac
echo "fertig: $ziel"
