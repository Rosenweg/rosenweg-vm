<p align="center"><img src="assets/logo/rosenweg-vm-512.png" width="96" alt="Logo"></p>
<h1 align="center">Rosenweg Virtuelle Computer</h1>
<p align="center">Die eigenen virtuellen Computer des Rosenwegs öffnen – mit Ton und USB, im Haus und unterwegs.</p>
<p align="center"><a href="https://www.rosenweg4303.ch/apps">Herunterladen</a> · <a href="docs/anleitung.md">Anleitung</a> · <a href="docs/entwicklung.md">Für Entwickler</a></p>

## Was die App kann

- Einmal mit dem Rosenweg-Konto anmelden, danach 30 Tage ohne Nachfrage.
- Zeigt nur die eigenen virtuellen Computer – antippen, fertig.
- Bildschirm mit Ton, Maus, Tastatur und USB-Geräten direkt in der App.
- Im Haus und unterwegs gleich, ohne separates VPN.
- Ersetzt auf den Stationen das Programm „Maschinen“.

## Plattformen

Linux (Debian-Paket) und macOS; Windows, Android und iOS folgen.

## Entwickeln

Flutter-App mit C-Schicht über spice-client-glib, WireGuard-Tunnel in Go und
eigenem vm-gateway. Aufbau, Bau, Versionen und CI stehen in
[docs/entwicklung.md](docs/entwicklung.md), die Entscheide in
[docs/architektur.md](docs/architektur.md).

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Fremdbibliotheken (spice-glib
und GLib unter LGPL, dynamisch gelinkt) in [LIZENZEN.md](LIZENZEN.md).
