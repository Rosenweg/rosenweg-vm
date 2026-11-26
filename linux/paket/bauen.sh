#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# linux/paket/bauen.sh — Rosenweg Virtuelle Computer als Debian-Paket
# ============================================================================
# Für die Stationen von Rosenweg OS (Debian 13, amd64). Dort ersetzt das Paket
# das Python/GTK-Programm „Maschinen" (os-stationen, roles/desktop).
#
#   linux/paket/bauen.sh              alles: Werkzeuge, native Bibliotheken,
#                                     flutter build linux, Paket
#   linux/paket/bauen.sh --nur-paket  nur das Paket aus dem fertigen Bündel
#                                     build/linux/x64/release/bundle (so ruft
#                                     es der CI-Lauf nach seinem eigenen Bau)
#   linux/paket/im-container.sh       im Bau-Container CT 141, siehe dort
#
# Ergebnis: linux/paket/out/rosenweg-vm_<version>_amd64.deb und die
# Prüfsumme dafür (für os-stationen, pakete/rosenweg-vm/paket.conf).
#
# Warum der Paketbau HIER liegt und nicht in os-stationen: das Paket ist die
# Linux-Auslieferung der App, nicht ein Stationsdetail. Was hineingehört
# (Bündel, Symbole, Starter, Abhängigkeiten), ändert sich mit der App, und der
# CI-Lauf dieses Repos soll dasselbe .deb bauen können. os-stationen kennt nur
# die fertige Datei und ihre Prüfsumme — wie beim slick-greeter-Paket.
#
# LGPL: spice-glib, GLib, GTK, libusb, usbredir, libsecret kommen aus Debian
# (Depends, berechnet mit dpkg-shlibdeps) und werden NICHT mitgeliefert. So
# bleiben sie austauschbar, und Sicherheitsupdates kommen über apt.
# ============================================================================
set -euo pipefail

HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WURZEL="$(cd "$HIER/../.." && pwd)"
cd "$WURZEL"

die() { echo "FEHLER: $*" >&2; exit 1; }
# Der Bau-Container hat keine en_US-Locale; ohne das füllen Perl (lintian,
# dpkg-shlibdeps) die Ausgabe mit Warnungen, zwischen denen Echtes untergeht.
export LC_ALL=C.UTF-8
log() { echo "== $*"; }

NUR_PAKET=0
[ "${1:-}" = "--nur-paket" ] && NUR_PAKET=1

PAKET=rosenweg-vm
ZIEL=/opt/rosenweg-vm
BUENDEL="$WURZEL/build/linux/x64/release/bundle"

# --- Version aus dem App-Stand -----------------------------------------------
# pubspec 'version: 1.0.0+1' -> Debian '1.0.0-1': der Teil vor dem '+' ist die
# Version der App, die Baunummer wird zur Paketrevision. Wer ein neues Paket
# verteilen will, hebt die Baunummer in pubspec.yaml an — dann steigt auch
# die Debian-Version, und apt sieht es als Update.
APP_VERSION="$(sed -n 's/^version:[[:space:]]*\([0-9][0-9.]*\)+\([0-9]\+\).*/\1-\2/p' pubspec.yaml)"
[ -n "$APP_VERSION" ] || die "Keine Version 'x.y.z+n' in pubspec.yaml."
ARCH=amd64
DATEI="${PAKET}_${APP_VERSION}_${ARCH}.deb"

# Woher der Stand kommt: im Git-Baum aus git, im Container (git archive, ohne
# .git) aus der Umgebung, die im-container.sh setzt.
if [ -z "${RVM_STAND:-}" ] && git -C "$WURZEL" rev-parse --git-dir >/dev/null 2>&1; then
    RVM_STAND="$(git -C "$WURZEL" rev-parse --short=12 HEAD)"
    git -C "$WURZEL" diff --quiet HEAD -- 2>/dev/null || RVM_STAND="$RVM_STAND+geaendert"
    : "${SOURCE_DATE_EPOCH:=$(git -C "$WURZEL" log -1 --format=%ct)}"
fi
RVM_STAND="${RVM_STAND:-unbekannt}"
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date +%s)}"

# --- Nur auf Debian 13 / amd64 -----------------------------------------------
# Die Abhängigkeiten rechnet dpkg-shlibdeps aus den Bibliotheken DIESES
# Systems. Auf einem anderen Debian stünden andere Paketnamen (etwa ohne die
# t64-Endung von Trixie) im Paket, und apt fände sie auf den Stationen nicht.
CODENAME="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
[ "$CODENAME" = trixie ] || die "Gebaut wird auf Debian 13 (trixie), nicht auf ${CODENAME:-?}."
[ "$(dpkg --print-architecture)" = "$ARCH" ] || die "Nur $ARCH."

# --- Systempakete ------------------------------------------------------------
# Dieselbe Liste wie im CI-Lauf (.github/workflows/linux.yml), dazu das
# Werkzeug fürs Paket: librsvg2-bin (Symbole aus dem SVG), dpkg-dev
# (dpkg-shlibdeps), binutils (strip), patchelf, file, lintian (Probe).
NOETIG="dpkg-dev binutils patchelf librsvg2-bin file lintian"
[ "$NUR_PAKET" -eq 1 ] || NOETIG="$NOETIG clang cmake ninja-build pkg-config xz-utils curl unzip git
        ca-certificates libgtk-3-dev liblzma-dev libstdc++-14-dev
        libspice-client-glib-2.0-dev libusb-1.0-0-dev libsecret-1-dev libjsoncpp-dev"
fehlt=""
for p in $NOETIG; do dpkg -s "$p" >/dev/null 2>&1 || fehlt="$fehlt $p"; done
if [ -n "$fehlt" ]; then
    if [ "$(id -u)" -eq 0 ]; then
        log "Installiere:$fehlt"
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        # shellcheck disable=SC2086  # Liste, bewusst getrennt
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends $fehlt >/dev/null
    else
        die "Es fehlen:$fehlt (als root ausführen oder von Hand installieren)."
    fi
fi

# --- App bauen ---------------------------------------------------------------
if [ "$NUR_PAKET" -eq 0 ]; then
    # Go und Flutter in genau den Versionen und mit den Prüfsummen aus dem
    # CI-Lauf. Gelesen aus linux.yml statt abgeschrieben: zwei Stellen mit
    # Versionsnummern laufen sonst früher oder später auseinander.
    WF="$WURZEL/.github/workflows/linux.yml"
    wert() { sed -n "s/^  $1: \"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$WF"; }
    GO_VERSION="$(wert GO_VERSION)"; GO_SHA256="$(wert GO_SHA256)"
    FLUTTER_VERSION="$(wert FLUTTER_VERSION)"; FLUTTER_SHA256="$(wert FLUTTER_SHA256)"
    [ -n "$GO_VERSION" ] && [ -n "$FLUTTER_VERSION" ] || die "Versionen nicht in $WF gefunden."

    C="${RVM_CACHE:-$HOME/.cache/rosenweg-vm-ci}"; mkdir -p "$C"
    if [ ! -x "$C/go-$GO_VERSION/bin/go" ]; then
        log "Lade Go $GO_VERSION"
        curl -fsSL -o "$C/go.tgz" "https://dl.google.com/go/go$GO_VERSION.linux-amd64.tar.gz"
        echo "$GO_SHA256  $C/go.tgz" | sha256sum -c --quiet -
        mkdir -p "$C/go-$GO_VERSION"
        tar -xzf "$C/go.tgz" -C "$C/go-$GO_VERSION" --strip-components=1 --no-same-owner
        rm "$C/go.tgz"
    fi
    if [ ! -x "$C/flutter-$FLUTTER_VERSION/bin/flutter" ]; then
        log "Lade Flutter $FLUTTER_VERSION"
        curl -fsSL -o "$C/flutter.txz" "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux/flutter_linux_$FLUTTER_VERSION-stable.tar.xz"
        echo "$FLUTTER_SHA256  $C/flutter.txz" | sha256sum -c --quiet -
        mkdir -p "$C/flutter-$FLUTTER_VERSION"
        # --no-same-owner: als root ausgepackt gehörten die Dateien sonst der
        # Kennung aus dem Archiv, und git (das Flutter für seine eigene
        # Version fragt) verweigerte den Baum als „dubious ownership".
        tar -xJf "$C/flutter.txz" -C "$C/flutter-$FLUTTER_VERSION" --strip-components=1 --no-same-owner
        rm "$C/flutter.txz"
    fi
    export PATH="$C/go-$GO_VERSION/bin:$C/flutter-$FLUTTER_VERSION/bin:$PATH"
    export GOPATH="$C/gopath" GOMODCACHE="$C/gopath/pkg/mod" GOTOOLCHAIN=local
    export PUB_CACHE="$C/pub-cache"
    # Im Bau-Container läuft das als root; Flutter warnt dann nur.
    export FLUTTER_SUPPRESS_ANALYTICS=true CI=true

    log "Native Bibliotheken"
    native/rwtunnel/bauen.sh linux
    native/rwspice/bauen.sh linux

    log "flutter build linux"
    flutter config --no-analytics --enable-linux-desktop >/dev/null
    flutter pub get >/dev/null
    flutter build linux --release
fi

[ -x "$BUENDEL/rosenweg_vm" ] || die "$BUENDEL/rosenweg_vm fehlt — erst bauen (ohne --nur-paket)."
for b in librwspice.so librwtunnel.so; do
    [ -r "$BUENDEL/lib/$b" ] || die "$BUENDEL/lib/$b fehlt — native/*/bauen.sh linux vor flutter build."
done

# --- Paketbaum ---------------------------------------------------------------
# Unter debian/<paket>, damit dpkg-shlibdeps die Bibliotheken im Bündel als
# „eigene" erkennt und nur nach den fremden fragt.
log "Paket $DATEI"
ARBEIT="$HIER/arbeit"
BAUM="$ARBEIT/debian/$PAKET"
rm -rf "$ARBEIT" "$HIER/out"
mkdir -p "$BAUM$ZIEL" "$HIER/out"

cp -a "$BUENDEL/." "$BAUM$ZIEL/"
# Lizenzen gehören nach /usr/share/doc (dort sucht man sie); der CI-Lauf legt
# sie für sein tar.gz zusätzlich ins Bündel.
rm -f "$BAUM$ZIEL/LICENSE" "$BAUM$ZIEL/LIZENZEN.md"

install -D -m 0755 "$HIER/rosenweg-vm" "$BAUM/usr/bin/rosenweg-vm"
install -D -m 0644 "$HIER/ch.rosenweg4303.vm.desktop" \
    "$BAUM/usr/share/applications/ch.rosenweg4303.vm.desktop"

# Symbole: dieselbe Regel wie assets/logo/erzeugen.sh — bis 108 px die
# vereinfachte Fassung (*-klein.svg), darüber der Wappen-Turm. Aus dem SVG
# gerechnet statt eingecheckt: für Linux gibt es sonst keinen Abnehmer.
L="$WURZEL/assets/logo"
for s in 16 22 24 32 48 64 96 128 256 512; do
    q="$L/rosenweg-vm.svg"; [ "$s" -le 108 ] && q="$L/rosenweg-vm-klein.svg"
    d="$BAUM/usr/share/icons/hicolor/${s}x${s}/apps"
    mkdir -p "$d"
    rsvg-convert -w "$s" -h "$s" "$q" -o "$d/rosenweg-vm.png"
done
install -D -m 0644 "$L/rosenweg-vm.svg" "$BAUM/usr/share/icons/hicolor/scalable/apps/rosenweg-vm.svg"

DOC="$BAUM/usr/share/doc/$PAKET"
install -d -m 0755 "$DOC"
{
    echo "Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/"
    echo "Upstream-Name: Rosenweg Virtuelle Computer"
    echo "Source: https://github.com/Rosenweg/rosenweg-vm"
    echo
    echo "Files: *"
    echo "Copyright: Rosenweg 4303"
    echo "License: GPL-3.0-or-later"
    echo " Der volle Text steht in /usr/share/common-licenses/GPL-3."
    echo " Fremdbibliotheken und ihre Lizenzen: /usr/share/doc/$PAKET/LIZENZEN.md"
} > "$DOC/copyright"
install -m 0644 "$WURZEL/LIZENZEN.md" "$DOC/LIZENZEN.md"
# Die Lizenzen der in libapp.so eingebauten Dart-Pakete und Flutter selbst
# liegen im Bündel (flutter_assets/NOTICES.Z) und zeigt die App unter „Über".
{
    echo "$PAKET ($APP_VERSION) trixie; urgency=medium"
    echo
    echo "  * Gebaut aus rosenweg-vm $RVM_STAND."
    echo
    echo " -- Rosenweg Technik <root@localhost>  $(LC_ALL=C date -u -R -d "@$SOURCE_DATE_EPOCH")"
} | gzip -9n > "$DOC/changelog.Debian.gz"

# Bauort aus den Plugin-Bibliotheken nehmen: Flutter trägt dort als RUNPATH
# den ephemeral-Ordner des Bauenden ein (/root/bau/…/linux/flutter/ephemeral).
# Auf der Station gibt es den nicht — oder schlimmer, jemand legt ihn an.
# '$ORIGIN' genügt: libflutter_linux_gtk.so liegt im selben lib/.
for so in "$BAUM$ZIEL"/lib/lib*_plugin.so; do
    [ -e "$so" ] || continue
    # shellcheck disable=SC2016  # $ORIGIN ist für den Lader, nicht für bash
    patchelf --set-rpath '$ORIGIN' "$so"
done
# Symbole weg aus dem, was wir selbst kompilieren (Runner, Plugins,
# librwspice). libapp.so (Dart-AOT) und libflutter_linux_gtk.so kommen
# fertig aus Flutter und bleiben, wie sie sind.
for f in "$BAUM$ZIEL/rosenweg_vm" "$BAUM$ZIEL"/lib/lib*_plugin.so "$BAUM$ZIEL/lib/librwspice.so"; do
    [ -e "$f" ] && strip --strip-unneeded --remove-section=.comment --remove-section=.note "$f"
done

# Was lintian anmerkt, aber zur Art dieses Pakets gehört — mit Begründung,
# damit ein neuer Hinweis in der Ausgabe auffällt statt in der Menge
# unterzugehen.
install -d -m 0755 "$BAUM/usr/share/lintian/overrides"
cat > "$BAUM/usr/share/lintian/overrides/$PAKET" <<'EOF'
# Ein Flutter-Bündel erwartet data/ und lib/ neben der Programmdatei; nach
# /usr/lib verteilt ginge das nur mit einem Umbau des Flutter-Runners.
rosenweg-vm: dir-or-file-in-opt [opt/rosenweg-vm/*]
# Die Flutter-Engine bringt freetype und libjpeg eingebaut mit; austauschen
# lässt sich das nur mit einer selbst gebauten Engine.
rosenweg-vm: embedded-library * [opt/rosenweg-vm/lib/libflutter_linux_gtk.so]
# Dart-AOT-Code: ein ELF ohne NEEDED, von der Engine geladen.
rosenweg-vm: shared-library-lacks-prerequisites [opt/rosenweg-vm/lib/libapp.so]
# Hauspaket, verlässt das Haus nicht; eine erfundene Adresse sähe nach einer
# Anlaufstelle aus, die es nicht gibt (wie beim slick-greeter-Paket).
rosenweg-vm: bogus-mail-host *
rosenweg-vm: bogus-mail-host-in-debian-changelog *
rosenweg-vm: root-in-contact *
rosenweg-vm: initial-upload-closes-no-bugs *
# Ein Programm mit Fenster und ohne Schalter.
rosenweg-vm: no-manual-page [usr/bin/rosenweg-vm]
EOF

# Rechte vereinheitlichen: cp -a übernimmt sonst die umask des Bauenden.
find "$BAUM" -type d -exec chmod 0755 {} +
find "$BAUM" -type f -exec chmod 0644 {} +
chmod 0755 "$BAUM$ZIEL/rosenweg_vm" "$BAUM/usr/bin/rosenweg-vm"
# Bibliotheken: lintian möchte sie nicht ausführbar (shlib-with-executable-bit).

# --- Abhängigkeiten ----------------------------------------------------------
# dpkg-shlibdeps liest aus jeder ELF-Datei, welche Systembibliotheken sie
# braucht, und macht daraus Debian-Paketnamen mit Mindestversion. Von Hand
# gepflegt fehlte bald eine — und das merkte man erst auf der Station.
mkdir -p "$ARBEIT/debian"
cat > "$ARBEIT/debian/control" <<EOF
Source: $PAKET

Package: $PAKET
Architecture: $ARCH
EOF
mapfile -t ELF < <(find "$BAUM$ZIEL" -type f \( -name '*.so' -o -name rosenweg_vm \) | sort)
SHLIBS="$(cd "$ARBEIT" && dpkg-shlibdeps -O -l"$BAUM$ZIEL/lib" "${ELF[@]}" 2>"$ARBEIT/shlibdeps.log" \
          | sed -n 's/^shlibs:Depends=//p')"
[ -n "$SHLIBS" ] || { cat "$ARBEIT/shlibdeps.log" >&2; die "dpkg-shlibdeps ergab keine Abhängigkeiten."; }
grep -v '^$' "$ARBEIT/shlibdeps.log" | sed 's/^/   /' || true

# Was dpkg-shlibdeps nicht sehen kann, weil es erst zur Laufzeit geladen wird:
# - Ton: miniaudio öffnet libpulse bzw. libasound selbst (dlopen).
# - Anmeldung: url_launcher ruft xdg-open für den Browser.
# - Gespeicherte Anmeldung (flutter_secure_storage über libsecret) braucht
#   einen Secret-Service-Dienst in der Sitzung; Cinnamon bringt gnome-keyring
#   mit, darum nur empfohlen.
DEPENDS="$SHLIBS, libpulse0 | libasound2t64, xdg-utils"
RECOMMENDS="gnome-keyring"

GROESSE="$(du -sk --apparent-size "$BAUM" | cut -f1)"
install -d -m 0755 "$BAUM/DEBIAN"
cat > "$BAUM/DEBIAN/control" <<EOF
Package: $PAKET
Version: $APP_VERSION
Architecture: $ARCH
Maintainer: Rosenweg Technik <root@localhost>
Installed-Size: $GROESSE
Depends: $DEPENDS
Recommends: $RECOMMENDS
Section: net
Priority: optional
Homepage: https://github.com/Rosenweg/rosenweg-vm
Description: Rosenweg Virtuelle Computer
 Einmal mit dem Rosenweg-Konto anmelden, die eigenen virtuellen Computer aus
 dem Proxmox-Cluster sehen und öffnen: Bildschirm über SPICE mit Ton, USB und
 Ordnerfreigabe, durch einen WireGuard-Tunnel im Prozess der App.
 .
 Gebaut aus rosenweg-vm $RVM_STAND.
EOF
(cd "$BAUM" && find . -path ./DEBIAN -prune -o -type f -printf '%P\0' | sort -z \
    | xargs -0 md5sum > DEBIAN/md5sums)
chmod 0644 "$BAUM/DEBIAN/control" "$BAUM/DEBIAN/md5sums"

dpkg-deb --root-owner-group -Zxz --build "$BAUM" "$HIER/out/$DATEI" >/dev/null
echo "$DATEI" > "$HIER/out/DATEI"

# --- Probe -------------------------------------------------------------------
# lintian bricht den Bau nicht ab: einige Hinweise gehören zur Art des
# Pakets (Flutter-Bündel unter /opt, AOT-Code in libapp.so). Die stehen in
# der Ausgabe und sollen dort gelesen werden, nicht weggefiltert.
if command -v lintian >/dev/null 2>&1; then
    log "lintian"
    lintian --tag-display-limit 0 "$HIER/out/$DATEI" 2>&1 | sed 's/^/   /' || true
fi

echo
echo "Gebaut: $HIER/out/$DATEI ($(du -h "$HIER/out/$DATEI" | cut -f1))"
echo "Depends: $DEPENDS"
echo "Für os-stationen (pakete/rosenweg-vm/paket.conf):"
echo "VERSION=$APP_VERSION"
echo "SHA256_$ARCH=$(sha256sum "$HIER/out/$DATEI" | cut -d' ' -f1)"
