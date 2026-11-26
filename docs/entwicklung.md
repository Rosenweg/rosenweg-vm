# Entwicklung (macOS als Entwicklungsziel)

## Voraussetzungen

- Flutter (stable), Xcode
- MacPorts mit `spice-gtk` (liefert spice-client-glib, usbredir, libusb)
- Go: wird **lokal** nach `.werkzeuge/go` geladen (nicht systemweit):
  ```bash
  mkdir -p .werkzeuge && curl -sO https://dl.google.com/go/go1.27.4.darwin-arm64.tar.gz
  shasum -a 256 go1.27.4.darwin-arm64.tar.gz   # 91a44a2b8a71…bb4
  tar -xzf go1.27.4.darwin-arm64.tar.gz -C .werkzeuge
  ```

## Bauen

```bash
native/rwtunnel/bauen.sh macos      # librwtunnel.dylib (arm64+x86_64)
native/rwspice/bauen.sh macos       # librwspice.dylib gegen /opt/local
flutter run -d macos --dart-define=RW_NATIVE_DIR=$PWD/native
```

Weitere Ziele: `native/rwtunnel/bauen.sh android|ios|linux|windows`.

## Tastaturbelegungen der Gaeste

`lib/spice/belegungen.g.dart` wird aus xkeyboard-config erzeugt (MacPorts:
`xkeyboard-config`, `libxkbcommon` mit `xkbcli`, `xorg-libX11` fuer
keysymdef.h und Compose):

```bash
python3 tool/belegungen_erzeugen.py      # Liste der Belegungen oben im Skript
```

## Testen ohne Hausnetz

```bash
# Tunnel: zwei WireGuard-Enden im Prozess, Proxy, Weiterleitung, SPICE
(cd native/rwtunnel && ../../.werkzeuge/go/bin/go test ./tunnel/)
# Gateway Ende zu Ende: nachgebautes Authentik und Proxmox, App-Seite des
# Tunnels, Rechte, Geraetebindung, SPICE nur mit eigenem Ticket, Ablauf
(cd gateway && ../.werkzeuge/go/bin/go test .)

# SPICE-Testserver (spice-server aus den Quellen, Testprogramme):
git clone --depth 1 --branch v0.16.0 --recurse-submodules \
    https://gitlab.freedesktop.org/spice/spice.git spice-src
python3 -m venv venv && venv/bin/pip install pyparsing six
# macOS hat kein librt: in spice-src/meson.build ['rt','m'] -> ['m'] fuer darwin
PATH=$PWD/venv/bin:/opt/local/bin:$PATH PKG_CONFIG_PATH=/opt/local/lib/pkgconfig \
    meson setup bau spice-src -Dgstreamer=no -Dlz4=false -Dsasl=false \
    -Dsmartcard=disabled -Dmanual=false -Dtests=true
ninja -C bau
bau/server/tests/test-display-no-ssl &      # Bild auf 127.0.0.1:5912
bau/server/tests/test-playback &            # Ton auf 127.0.0.1:5701

# C-Schicht allein:
clang native/rwspice/test/rwspice_test.c -Lnative/rwspice/build/macos -lrwspice \
    -Wl,-rpath,$PWD/native/rwspice/build/macos -o /tmp/rwspice_test
/tmp/rwspice_test 127.0.0.1 5912 /tmp/bild.ppm

# Durch die Proxy-Kette (wie unterwegs, ohne WireGuard):
native/rwtunnel/build/proxytest 127.0.0.1:5912   # gibt http://rw:…@127.0.0.1:… aus
/tmp/rwspice_test pvespiceproxy:t:100:pve1 5912 /tmp/bild.ppm 10 http://rw:…@127.0.0.1:…

# Ganze App:
flutter test integration_test -d macos \
    --dart-define=RW_NATIVE_DIR=$PWD/native --dart-define=RW_TEST_SPICE=127.0.0.1:5912
```

`RW_TEST_SPICE` zeigt in der Liste einen „Testcomputer (lokal)“ ohne
Anmeldung; nur für die Entwicklung.

Foto nur des App-Fensters (nicht des ganzen Bildschirms):
```bash
swift -e 'import CoreGraphics; for w in CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as! [[String:Any]] where (w["kCGWindowOwnerName"] as? String ?? "").contains("Rosenweg") { print(w["kCGWindowNumber"]!) }'
screencapture -x -o -l <Nummer> /tmp/fenster.png
```

## Gegen das Haus ausprobieren

Erst nach der Einrichtung (docs/authentik-und-server.md: Authentik-Eintrag,
vm-gateway-CT, API-Branch `vm-app-tunnel` ausgerollt):
`flutter run -d macos --dart-define=RW_NATIVE_DIR=$PWD/native`. Einmal
„Mit Rosenweg-Konto anmelden“, danach die Liste — im Haus über den
LAN-Endpunkt des Gateways, sonst über den öffentlichen.
