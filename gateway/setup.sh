#!/bin/bash
# Richtet vm-gateway auf einem frischen Debian-CT ein (als root IM Container).
#   ./setup.sh <pfad/zu/vm-gateway-linux-amd64>
# Legt /etc/vm-gateway/env beim ersten Mal mit Zufalls-Steuertoken an; die
# Proxmox- und Endpunkt-Angaben muessen danach von Hand eingetragen werden
# (README.md, "Einrichten"). Ein zweiter Lauf ersetzt nur das Programm.
set -euo pipefail
bin="${1:?Pfad zum Programm fehlt}"
id vm-gateway >/dev/null 2>&1 || useradd --system --home-dir /nonexistent --shell /usr/sbin/nologin vm-gateway
install -d -m 0755 /opt/vm-gateway
install -m 0755 "$bin" /opt/vm-gateway/vm-gateway.neu
mv /opt/vm-gateway/vm-gateway.neu /opt/vm-gateway/vm-gateway
install -m 0644 "$(dirname "$0")/vm-gateway.service" /etc/systemd/system/vm-gateway.service
install -d -m 0750 -o root -g vm-gateway /etc/vm-gateway
if [ ! -f /etc/vm-gateway/env ]; then
    umask 077
    cat > /etc/vm-gateway/env <<EOT
# vm-gateway — siehe README.md. Geheim: GW_STEUER_TOKEN, PVE_TOKEN.
GW_WG_PORT=51831
GW_ENDPOINT_EXTERN=kooperation.rosenweg4303.ch:51831
GW_ENDPOINT_INTERN=
GW_NETZ=10.243.43.0/24
GW_STEUER_BIND=
GW_STEUER_TOKEN=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 43)
ROSENWEG_API_ME=
PVE_HOSTS=pve1.rosenweg4303.ch,pve2.rosenweg4303.ch,pve3.rosenweg4303.ch
PVE_TOKEN=
PVE_REALM=authentik
PVE_BENUTZER_CLAIM=preferred_username
EOT
    chgrp vm-gateway /etc/vm-gateway/env
    chmod 0640 /etc/vm-gateway/env
    echo "Neu: /etc/vm-gateway/env — GW_ENDPOINT_INTERN, GW_STEUER_BIND, ROSENWEG_API_ME und PVE_TOKEN eintragen, dann:"
    echo "  systemctl enable --now vm-gateway"
fi
# Firewall: Adressen des Hauses getrennt von nftables.conf (oeffentliches Repo)
if [ ! -f /etc/vm-gateway/nft-adressen.conf ] && [ -f "$(dirname "$0")/nft-adressen.beispiel.conf" ]; then
    install -m 0644 "$(dirname "$0")/nft-adressen.beispiel.conf" /etc/vm-gateway/nft-adressen.conf
    echo "Neu: /etc/vm-gateway/nft-adressen.conf — echte Adressen eintragen (README.md, Firewall)."
fi
systemctl daemon-reload
systemctl is-enabled --quiet vm-gateway 2>/dev/null && systemctl restart vm-gateway
echo fertig
