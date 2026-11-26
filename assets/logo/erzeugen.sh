#!/bin/sh
# Erzeugt alle Plattform-Icons aus den SVG-Quellen in assets/logo/.
# Benoetigt: rsvg-convert (librsvg) und magick (ImageMagick 7).
# Aufruf aus dem Repo-Wurzelverzeichnis: sh assets/logo/erzeugen.sh
set -eu
L=assets/logo
r() { rsvg-convert -w "$2" -h "$2" "$1" -o "$3"; }

# macOS
M=macos/Runner/Assets.xcassets/AppIcon.appiconset
for s in 16 32 64 128 256 512 1024; do r $L/rosenweg-vm-macos.svg $s $M/app_icon_$s.png; done

# iOS (ohne Alpha-Kanal, vollflaechig; iOS rundet selbst)
I=ios/Runner/Assets.xcassets/AppIcon.appiconset
ios() { r $L/rosenweg-vm-vollflaeche.svg "$2" /tmp/rvm-ios.png
        magick /tmp/rvm-ios.png -background '#D32F2F' -alpha remove -alpha off "$I/$1"; }
ios Icon-App-20x20@1x.png 20;  ios Icon-App-20x20@2x.png 40;  ios Icon-App-20x20@3x.png 60
ios Icon-App-29x29@1x.png 29;  ios Icon-App-29x29@2x.png 58;  ios Icon-App-29x29@3x.png 87
ios Icon-App-40x40@1x.png 40;  ios Icon-App-40x40@2x.png 80;  ios Icon-App-40x40@3x.png 120
ios Icon-App-60x60@2x.png 120; ios Icon-App-60x60@3x.png 180
ios Icon-App-76x76@1x.png 76;  ios Icon-App-76x76@2x.png 152
ios Icon-App-83.5x83.5@2x.png 167; ios Icon-App-1024x1024@1x.png 1024
rm -f /tmp/rvm-ios.png

# Android: klassisches Icon (48 dp) und adaptive icon (108 dp)
A=android/app/src/main/res
for d in mdpi:1 hdpi:1.5 xhdpi:2 xxhdpi:3 xxxhdpi:4; do
  n=${d%%:*}; f=${d##*:}
  mkdir -p $A/mipmap-$n
  r $L/rosenweg-vm.svg $(echo "48*$f/1" | bc) $A/mipmap-$n/ic_launcher.png
  r $L/rosenweg-vm-vordergrund.svg $(echo "108*$f/1" | bc) $A/mipmap-$n/ic_launcher_foreground.png
  r $L/rosenweg-vm-monochrom.svg $(echo "108*$f/1" | bc) $A/mipmap-$n/ic_launcher_monochrome.png
done

# Windows
W=windows/runner/resources/app_icon.ico
T=$(mktemp -d)
for s in 16 24 32 48 64 128 256; do r $L/rosenweg-vm.svg $s $T/$s.png; done
magick $T/16.png $T/24.png $T/32.png $T/48.png $T/64.png $T/128.png $T/256.png $W
rm -rf "$T"

# Linux / allgemein: PNG neben dem SVG
r $L/rosenweg-vm.svg 512 $L/rosenweg-vm-512.png
