#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Logo „Rosenweg Virtuelle Computer“ aus dem Logo-Baukasten von rosenweg-basis (Stil A2): Wappen
# (Turm, Weg, Rose) und rechts unten die Plakette mit dem Monitor; Grund in der
# Gruppenfarbe Bewohner (Rosenweg-Rot #D62828), wie in werkzeug/logo/flutter-apps.txt.
# Erzeugt alle Plattform-Symbole (Android adaptive + monochrom, iOS, macOS samt
# .icns und DMG-Hintergrund, Windows .ico, assets/logo/rosenweg-vm-192.png fuer /apps);
# die Linux-Symbole rechnet linux/paket/bauen.sh beim Bau aus denselben SVGs.
# Aufruf aus dem Repo-Wurzelverzeichnis:
#   sh assets/logo/erzeugen.sh [pfad/zu/rosenweg-basis]
set -eu
BASIS="${1:-../rosenweg-basis}"
sh "$BASIS/werkzeug/logo/app-symbole.sh" . rosenweg-vm "Rosenweg Virtuelle Computer" \
  "$BASIS/werkzeug/logo/zeichen/monitor.svg" bewohner
