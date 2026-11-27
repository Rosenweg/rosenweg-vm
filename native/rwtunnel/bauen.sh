#!/bin/bash
# Baut librwtunnel fuer das Zielsystem.
#   ./bauen.sh macos        -> build/macos/librwtunnel.dylib (arm64 + x86_64)
#   ./bauen.sh linux        -> build/linux/librwtunnel.so   (auf Linux ausfuehren)
#   ./bauen.sh windows      -> build/windows/rwtunnel.dll   (braucht mingw-w64)
#   ./bauen.sh android      -> build/android/<abi>/librwtunnel.so (NDK)
#   ./bauen.sh android-jni  -> build/android-jni/<abi>/librwtunnel_jni.so (NDK, Java/JNI fuer
#                              die Fernwartung in Rosenweg Geraet, siehe jni/main.go)
#   ./bauen.sh ios          -> build/ios/librwtunnel.a      (c-archive)
#
# Go kommt aus .werkzeuge/go, falls vorhanden (lokal heruntergeladen, nicht
# systemweit installiert), sonst aus dem PATH.
set -euo pipefail
cd "$(dirname "$0")"
WURZEL="$(cd ../.. && pwd)"
if [ -x "$WURZEL/.werkzeuge/go/bin/go" ]; then
    export PATH="$WURZEL/.werkzeuge/go/bin:$PATH"
    export GOPATH="$WURZEL/.werkzeuge/gopath" GOMODCACHE="$WURZEL/.werkzeuge/gopath/pkg/mod"
fi
export GOTOOLCHAIN=local GOFLAGS=-modcacherw CGO_ENABLED=1
# -s -w: ohne Symboltabelle, deutlich kleiner; -trimpath: keine lokalen Pfade in der Datei.
FLAGS=(-trimpath -ldflags "-s -w")

ziel="${1:-macos}"
case "$ziel" in
macos)
    mkdir -p build/macos
    # 13.0: Mindeststand von Go 1.27 auf macOS.
    export MACOSX_DEPLOYMENT_TARGET=13.0
    GOARCH=arm64 go build "${FLAGS[@]}" -buildmode=c-shared -o build/macos/arm64.dylib ./capi
    GOARCH=amd64 go build "${FLAGS[@]}" -buildmode=c-shared -o build/macos/amd64.dylib ./capi
    lipo -create -output build/macos/librwtunnel.dylib build/macos/arm64.dylib build/macos/amd64.dylib
    install_name_tool -id @rpath/librwtunnel.dylib build/macos/librwtunnel.dylib
    cp build/macos/arm64.h build/macos/librwtunnel.h
    rm -f build/macos/{arm64,amd64}.{dylib,h}
    ;;
linux)
    mkdir -p build/linux
    go build "${FLAGS[@]}" -buildmode=c-shared -o build/linux/librwtunnel.so ./capi
    ;;
windows)
    mkdir -p build/windows
    # Kreuzbau mit mingw-w64 (Linux/macOS) oder in der MSYS2-Shell (gcc).
    GOOS=windows GOARCH=amd64 CC="${CC:-$(command -v x86_64-w64-mingw32-gcc || echo gcc)}" \
        go build "${FLAGS[@]}" -buildmode=c-shared -o build/windows/rwtunnel.dll ./capi
    ;;
android)
    : "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/28.2.13676358}"
    tc="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$(uname -s | tr A-Z a-z)-x86_64/bin"
    for paar in "arm64-v8a arm64 aarch64-linux-android" "x86_64 amd64 x86_64-linux-android"; do
        set -- $paar
        mkdir -p "build/android/$1"
        GOOS=android GOARCH="$2" CC="$tc/${3}24-clang" \
            go build "${FLAGS[@]}" -buildmode=c-shared -o "build/android/$1/librwtunnel.so" ./capi
    done
    ;;
android-jni)
    : "${ANDROID_NDK_HOME:=$HOME/Library/Android/sdk/ndk/28.2.13676358}"
    tc="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/$(uname -s | tr A-Z a-z)-x86_64/bin"
    for paar in "arm64-v8a arm64 aarch64-linux-android" "x86_64 amd64 x86_64-linux-android"; do
        set -- $paar
        mkdir -p "build/android-jni/$1"
        # 21 = minSdk von Rosenweg Geraet; Go selbst braucht auf Android mindestens das.
        GOOS=android GOARCH="$2" CC="$tc/${3}21-clang" \
            go build "${FLAGS[@]}" -buildmode=c-shared -o "build/android-jni/$1/librwtunnel_jni.so" ./jni
        rm -f "build/android-jni/$1/librwtunnel_jni.h"
    done
    ;;
ios)
    mkdir -p build/ios
    GOOS=ios GOARCH=arm64 CC="$(xcrun --sdk iphoneos -f clang)" \
        CGO_CFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=13.0" \
        CGO_LDFLAGS="-isysroot $(xcrun --sdk iphoneos --show-sdk-path) -miphoneos-version-min=13.0" \
        go build "${FLAGS[@]}" -buildmode=c-archive -o build/ios/librwtunnel.a ./capi
    ;;
*) echo "Unbekanntes Ziel: $ziel" >&2; exit 2 ;;
esac
echo "fertig: $ziel"
