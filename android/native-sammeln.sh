#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Stellt die nativen Bibliotheken fuer die APK zusammen:
#   build/android-jniLibs/<abi>/{librwtunnel,librwspice,libspiceglib}.so
# (android/app/build.gradle.kts nimmt den Ordner als jniLibs).
#
#   android/native-sammeln.sh [--bauen]
#
# --bauen: vorher rwtunnel (Go), den SPICE-Stapel und rwspice bauen
# (native/spice-stapel/bauen.sh, laedt ~1 GB GStreamer-Paket). Ohne: nur
# kopieren, was schon gebaut ist (z. B. aus dem CI-Artefakt).
set -euo pipefail
WURZEL="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WURZEL"
ABIS=(arm64-v8a x86_64)
if [ "${1:-}" = --bauen ]; then
    native/rwtunnel/bauen.sh android
    for abi in "${ABIS[@]}"; do
        native/spice-stapel/bauen.sh android "$abi"
        native/rwspice/bauen.sh android "$abi"
    done
fi
for abi in "${ABIS[@]}"; do
    z="build/android-jniLibs/$abi"; mkdir -p "$z"
    for q in "native/rwtunnel/build/android/$abi/librwtunnel.so" \
             "native/rwspice/build/android/$abi/librwspice.so" \
             "native/spice-stapel/build/android/$abi/libspiceglib.so"; do
        if [ -f "$q" ]; then cp "$q" "$z/"; else echo "fehlt: $q" >&2; fi
    done
    ls -la "$z"
done
