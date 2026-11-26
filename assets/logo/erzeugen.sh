#!/bin/sh
# Erzeugt alle Plattform-Icons aus den SVG-Quellen in assets/logo/.
# Benoetigt: rsvg-convert (librsvg >= 2.52, fuer feDropShadow) und magick (ImageMagick 7).
# Aufruf aus dem Repo-Wurzelverzeichnis: sh assets/logo/erzeugen.sh
#
# Die SVGs (Turm + Weg + Rose, Plakette Monitor) stammen aus dem Logo-Baukasten
# von rosenweg-basis und werden hier nicht von Hand geaendert. Neu erzeugen:
#   python3 <rosenweg-basis>/werkzeug/logo/baukasten.py --name rosenweg-vm \
#       --titel "Rosenweg Virtuelle Computer" --alle --ziel assets/logo \
#       --zeichen <rosenweg-basis>/werkzeug/logo/zeichen/monitor.svg
# (identisch mit <rosenweg-basis>/logos/rosenweg-vm/*.svg)
#
# Detailstufe nach Pixelgroesse (Regel des Baukastens):
#   bis 40 px  *-winzig.svg  Turm und Rose, ohne Weg
#   bis 108 px *-klein.svg   Turm ohne Mauerfugen, Weg breit
#   darueber   *.svg         volle Fassung
# Dieselbe Regel steht in linux/paket/bauen.sh (Linux-Symbole fuers .deb).
set -eu
L=assets/logo
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

stufe() { # stufe <quelle ohne .svg> <groesse> -> Pfad der passenden SVG
  if [ "$2" -le 40 ]; then echo "$1-winzig.svg"; elif [ "$2" -le 108 ]; then echo "$1-klein.svg"; else echo "$1.svg"; fi
}
r() { rsvg-convert -w "$2" -h "$2" "$(stufe "$1" "$2")" -o "$3"; }

# macOS: Form nach Apple-Raster (824er Feld auf 1024, Rand kommt aus -macos.svg)
# plus Schlagschatten wie in Apples Vorlage (schwarz, ca. 30 %, 10 px nach
# unten, weich; Angaben im 1024er Raster, skaliert mit). Der Schatten wird nur
# beim Rendern eingefuegt, die SVG-Quellen bleiben die des Baukastens.
M=macos/Runner/Assets.xcassets/AppIcon.appiconset
mac() {
  q=$(stufe $L/rosenweg-vm-macos "$1")
  sed -e 's|<g transform="translate(512 512) scale(0.805)|<defs><filter id="rw-schatten" x="-10%" y="-10%" width="120%" height="125%"><feDropShadow dx="0" dy="10" stdDeviation="10" flood-color="#000" flood-opacity="0.3"/></filter></defs><g filter="url(#rw-schatten)"><g transform="translate(512 512) scale(0.805)|' \
      -e 's|</svg>|</g></svg>|' "$q" > "$T/mac.svg"
  rsvg-convert -w "$1" -h "$1" "$T/mac.svg" -o "$M/app_icon_$1.png"
}
for s in 16 32 64 128 256 512 1024; do mac $s; done

# iOS (ohne Alpha-Kanal, vollflaechig; iOS rundet selbst)
I=ios/Runner/Assets.xcassets/AppIcon.appiconset
ios() { r $L/rosenweg-vm-vollflaeche "$2" "$T/ios.png"
        magick "$T/ios.png" -background '#D32F2F' -alpha remove -alpha off "$I/$1"; }
ios Icon-App-20x20@1x.png 20;  ios Icon-App-20x20@2x.png 40;  ios Icon-App-20x20@3x.png 60
ios Icon-App-29x29@1x.png 29;  ios Icon-App-29x29@2x.png 58;  ios Icon-App-29x29@3x.png 87
ios Icon-App-40x40@1x.png 40;  ios Icon-App-40x40@2x.png 80;  ios Icon-App-40x40@3x.png 120
ios Icon-App-60x60@2x.png 120; ios Icon-App-60x60@3x.png 180
ios Icon-App-76x76@1x.png 76;  ios Icon-App-76x76@2x.png 152
ios Icon-App-83.5x83.5@2x.png 167; ios Icon-App-1024x1024@1x.png 1024

# Android: klassisches Icon (48 dp) und adaptive icon (108 dp); Hintergrundfarbe
# rosenweg_icon_background steht in res/values/colors.xml.
A=android/app/src/main/res
for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  n=${d%%:*}; f=${d##*:}
  mkdir -p $A/mipmap-$n
  r $L/rosenweg-vm $(echo "48*$f/1" | bc) $A/mipmap-$n/ic_launcher.png
  r $L/rosenweg-vm-vordergrund $(echo "108*$f/1" | bc) $A/mipmap-$n/ic_launcher_foreground.png
  r $L/rosenweg-vm-monochrom $(echo "108*$f/1" | bc) $A/mipmap-$n/ic_launcher_monochrome.png
done

# Windows
W=windows/runner/resources/app_icon.ico
for s in 16 24 32 48 64 128 256; do r $L/rosenweg-vm $s "$T/w$s.png"; done
magick "$T/w16.png" "$T/w24.png" "$T/w32.png" "$T/w48.png" "$T/w64.png" "$T/w128.png" "$T/w256.png" $W

# Linux (Fenster-Symbol im Buendel, linux/CMakeLists.txt) und App-Oberflaeche
# (Anmeldeschirm, Ueber): PNG neben dem SVG
r $L/rosenweg-vm 512 $L/rosenweg-vm-512.png
