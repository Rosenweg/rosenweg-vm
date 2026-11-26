# Lizenzen

**Rosenweg Virtuelle Computer** (App, `native/rwspice`, `native/rwtunnel`,
`gateway`) steht unter der **GNU General Public License, Version 3 oder
später** (GPL-3.0-or-later), siehe [LICENSE](LICENSE). Jede Quelldatei trägt
die Kennung `SPDX-License-Identifier: GPL-3.0-or-later`.

## Mitgelieferte und gelinkte Fremdbibliotheken

| Bibliothek | Lizenz | Wie eingebunden | Pflichten |
|---|---|---|---|
| spice-gtk / spice-client-glib | LGPL-2.1-or-later | **dynamisch** (librwspice → libspice-client-glib) | Quelltext der verwendeten Version anbieten; austauschbar lassen (keine statische Einbindung) |
| GLib, GIO, GObject | LGPL-2.1-or-later | dynamisch (über spice-glib) | wie oben |
| usbredir (usbredirparser/-host) | LGPL-2.1-or-later | dynamisch (über spice-glib) | wie oben |
| libusb | LGPL-2.1-or-later | dynamisch (über spice-glib) | wie oben |
| pixman, opus, libjpeg-turbo, OpenSSL 3 | MIT / BSD / IJG / Apache-2.0 | dynamisch (über spice-glib) | Lizenztext beilegen |
| GStreamer (nur wo spice-glib damit gebaut ist, z. B. MacPorts/Debian) | LGPL-2.1-or-later | dynamisch | wie spice-glib; die App selbst braucht GStreamer nicht |
| miniaudio 0.11.26 | Public Domain oder MIT-0 (Wahl) | als Quelltext in `native/rwspice/drittanbieter/` | keine; Lizenztext liegt bei |
| wireguard-go | MIT | statisch (Go) in `librwtunnel` und `vm-gateway` | Lizenztext beilegen |
| gVisor (netstack) | Apache-2.0 | statisch (Go) | Lizenz- und NOTICE-Text beilegen; mit GPL-3 vereinbar |
| golang.org/x/crypto, x/net, x/sys | BSD-3-Clause | statisch (Go) | Lizenztext beilegen |
| Flutter, Dart-Pakete (ffi, crypto, url_launcher, flutter_secure_storage) | BSD-3-Clause | statisch/eingebettet | Lizenztext beilegen (Flutter erzeugt die Liste selbst: `showLicensePage`) |

## Warum dynamisch und warum GPL

- Die LGPL verlangt, dass man die Bibliothek gegen eine eigene Fassung
  tauschen kann. Darum ist spice-glib nie statisch eingebaut, auch nicht auf
  Android (`.so`) und iOS (eigene dynamische Frameworks).
- GPL-3.0-or-later für unseren Code passt zu allen obigen Lizenzen (LGPL,
  MIT, BSD, Apache-2.0) und zur Linie der Rosenweg-Apps (Fossify-Forks, GPL).
- **App Store (iOS):** Die Bedingungen von Apple gelten als schwer vereinbar
  mit der GPL. Weil das Haus die Rechte an diesem Code hat, kann es selbst
  verteilen. Bei Beiträgen Dritter bräuchte es deren Zustimmung — vor einer
  App-Store-Veröffentlichung klären. Ad-hoc, TestFlight und MDM sind
  unproblematisch.

## Auslieferung

Jedem Paket (deb, MSI, dmg, apk) liegen bei: `LICENSE`, diese Datei und die
Lizenztexte der Bibliotheken. Zu den LGPL-Bibliotheken das schriftliche
Angebot, den Quelltext der ausgelieferten Version zu liefern, oder gleich der
Verweis auf den Quelltext (Debian-Quellpaket, MSYS2-PKGBUILD, eigener Bau mit
Tag).

macOS: im App-Bündel unter `Contents/Resources/Lizenzen/` (LICENSE,
diese Datei, miniaudio, `BIBLIOTHEKEN.txt` mit Name und MacPorts-Version
jeder mitgelieferten Bibliothek aus `Contents/Frameworks`).

## xkeyboard-config (Daten)

`lib/spice/belegungen.g.dart` ist aus den Symboldateien von xkeyboard-config
und der Compose-Tabelle von libX11 erzeugt (MIT/X11-Lizenzen,
https://gitlab.freedesktop.org/xkeyboard-config/xkeyboard-config).
