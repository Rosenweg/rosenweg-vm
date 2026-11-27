#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# ============================================================================
# linux/paket/im-container.sh — das Paket im Bau-Container bauen
# ============================================================================
#   linux/paket/im-container.sh [knoten] [ct]
#   RW_BAU_KNOTEN=root@<knoten> linux/paket/im-container.sh                 (Knoten aus der Umgebung)
#   linux/paket/im-container.sh root@<knoten> 141
#
#   Fuer den Proxmox-Knoten mit dem Bau-Container gibt es keine Vorgabe (oeffentl.
#   Repo): als erstes Argument oder in RW_BAU_KNOTEN (z. B. in ~/.profile);
#   der Container in RW_BAU_CT oder als zweites Argument (Vorgabe 141).
#
# Der Bau-Container (CT 141, Debian 13) hat keinen SSH-Zugang von aussen und
# keinen Zugang zu GitHub. Darum geht der Quellstand als Archiv über den
# Knoten hinein ('pct push') und das .deb auf demselben Weg zurück.
#
# Mitgeschickt wird der Arbeitsstand, auch Ungespeichertes und neue Dateien
# (über einen eigenen Index, .gitignore gilt), damit man eine Änderung bauen
# kann, bevor man sie committet. Im
# Paket steht dann '<commit>+geaendert', damit niemand so ein Paket für
# einen sauberen Stand hält.
#
# Go, Flutter und der Pub-Cache bleiben im Container unter
# /root/.cache/rosenweg-vm-ci liegen; ab dem zweiten Lauf wird nichts mehr
# geladen.
# ============================================================================
# SC2029: die Befehle für den Knoten sollen hier ausgewertet werden.
# shellcheck disable=SC2029
set -euo pipefail

KNOTEN="${1:-${RW_BAU_KNOTEN:-}}"
CTID="${2:-${RW_BAU_CT:-141}}"
[ -n "$KNOTEN" ] || { echo "FEHLER: Knoten fehlt - als erstes Argument (root@<knoten>) oder in RW_BAU_KNOTEN." >&2; exit 2; }
HIER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WURZEL="$(cd "$HIER/../.." && pwd)"
cd "$WURZEL"

STAND="$(git rev-parse --short=12 HEAD)"
# Eigener Index statt 'git stash create': der nähme neue, noch nicht
# hinzugefügte Dateien nicht mit. Der echte Index bleibt unberührt.
INDEX="$(mktemp "${TMPDIR:-/tmp}/rosenweg-vm-index.XXXXXX")"
cp "$(git rev-parse --git-path index)" "$INDEX"
GIT_INDEX_FILE="$INDEX" git add -A
BAUM="$(GIT_INDEX_FILE="$INDEX" git write-tree)"
rm -f "$INDEX"
[ "$BAUM" = "$(git rev-parse 'HEAD^{tree}')" ] || STAND="$STAND+geaendert"
EPOCH="$(git log -1 --format=%ct)"

ZW="/tmp/rosenweg-vm-bau.$$"
ARCHIV="$(mktemp "${TMPDIR:-/tmp}/rosenweg-vm-quelle.XXXXXX")"
trap 'rm -f "$ARCHIV"' EXIT
git archive --format=tar.gz -o "$ARCHIV" "$BAUM"

ssh "$KNOTEN" "rm -rf $ZW && mkdir -p $ZW"
scp -q "$ARCHIV" "$KNOTEN:$ZW/quelle.tar.gz"
ssh "$KNOTEN" "pct exec $CTID -- rm -rf /root/bau/rosenweg-vm \
    && pct exec $CTID -- mkdir -p /root/bau/rosenweg-vm \
    && pct push $CTID $ZW/quelle.tar.gz /root/bau/rosenweg-vm.tar.gz \
    && pct exec $CTID -- tar -xzf /root/bau/rosenweg-vm.tar.gz -C /root/bau/rosenweg-vm \
    && pct exec $CTID -- env RVM_STAND=$STAND SOURCE_DATE_EPOCH=$EPOCH \
         bash /root/bau/rosenweg-vm/linux/paket/bauen.sh"

DATEI="$(ssh "$KNOTEN" "pct exec $CTID -- cat /root/bau/rosenweg-vm/linux/paket/out/DATEI")"
mkdir -p "$HIER/out"
ssh "$KNOTEN" "pct pull $CTID /root/bau/rosenweg-vm/linux/paket/out/$DATEI $ZW/$DATEI"
scp -q "$KNOTEN:$ZW/$DATEI" "$HIER/out/$DATEI"
ssh "$KNOTEN" "rm -rf $ZW"

echo
echo "Zurückgeholt: $HIER/out/$DATEI"
cd "$HIER/out"
shasum -a 256 "$DATEI" 2>/dev/null || sha256sum "$DATEI"
