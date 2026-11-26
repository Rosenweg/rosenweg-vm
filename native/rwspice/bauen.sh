#!/bin/bash
# Baut librwspice gegen eine vorhandene spice-client-glib.
#   ./bauen.sh macos   -> build/macos/librwspice.dylib (gegen MacPorts unter /opt/local)
#   ./bauen.sh linux   -> build/linux/librwspice.so    (Debian 13: apt install libspice-client-glib-2.0-dev)
#   ./bauen.sh windows -> build/windows/rwspice.dll    (MSYS2 UCRT64: pacman -S mingw-w64-ucrt-x86_64-{gcc,pkgconf,spice-gtk})
#
#   ./bauen.sh android <abi> -> build/android/<abi>/librwspice.so (vorher
#                               native/spice-stapel/bauen.sh android <abi>)
#   ./bauen.sh ios           -> build/ios-native/RwNative.framework (rwspice +
#                               rwtunnel; vorher native/spice-stapel/ios.sh
#                               und native/rwtunnel/bauen.sh ios)
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
ios)
    umg="../spice-stapel/build/arbeit/ios-arm64/umgebung.sh"
    [ -f "$umg" ] || { echo "Zuerst native/spice-stapel/ios.sh" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$umg"
    tunnel="../rwtunnel/build/ios/librwtunnel.a"
    [ -f "$tunnel" ] || { echo "Zuerst native/rwtunnel/bauen.sh ios" >&2; exit 1; }
    NATIV="../../build/ios-native"
    FW="$NATIV/RwNative.framework"
    rm -rf "$FW"; mkdir -p "$FW"
    # Ein Framework fuer beide eigenen Teile (die App laedt es mit
    # DynamicLibrary.open, lib/native/bibliothek.dart). spice-glib bleibt in
    # SpiceGlib.framework (austauschbar). miniaudio braucht auf iOS
    # Objective-C (AVAudioSession), darum -x objective-c.
    "$CC" -arch arm64 -isysroot "$SDK" "-miphoneos-version-min=$IOS_MIN" \
        -O2 -fPIC -dynamiclib -fvisibility=hidden "${WARN[@]}" -x objective-c \
        $("$PKGCFG" --cflags spice-client-glib-2.0) \
        "${QUELLEN[@]}" \
        -Wl,-force_load,"$tunnel" \
        -F"$NATIV" -framework SpiceGlib \
        -framework Foundation -framework CoreFoundation -framework Security \
        -framework AVFoundation -framework AudioToolbox -framework CoreAudio -lresolv \
        -install_name @rpath/RwNative.framework/RwNative -Wl,-rpath,@loader_path/.. \
        -o "$FW/RwNative"
    cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>RwNative</string>
  <key>CFBundleIdentifier</key><string>ch.rosenweg4303.vm.native</string>
  <key>CFBundleName</key><string>RwNative</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
  <key>MinimumOSVersion</key><string>$IOS_MIN</string>
</dict></plist>
EOF
    # Die App sucht diese Namen; fehlt einer, merkt es der Bau, nicht erst das Telefon
    for s in rw_spice_abi rw_spice_start rwt_start rwt_schluesselpaar; do
        nm -gU "$FW/RwNative" | grep -q " _$s\$" || { echo "Symbol $s fehlt in RwNative" >&2; exit 1; }
    done
    ;;
*) echo "Unbekanntes Ziel: $ziel" >&2; exit 2 ;;
esac
echo "fertig: $ziel"
