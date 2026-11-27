# Anleitung

Rosenweg Virtuelle Computer zeigt die eigenen virtuellen Computer aus dem
Proxmox-Cluster des Rosenwegs und öffnet ihren Bildschirm direkt in der App.

## Benutzen

1. App starten und einmal **Mit Rosenweg-Konto anmelden**. War die letzte
   Anmeldung im Browser höchstens 30 Tage her, geht das still.
2. In der Liste **Meine Computer** erscheinen nur die Computer, die für das
   eigene Konto freigegeben sind.
3. Computer antippen: Bildschirm mit Ton, Maus, Tastatur und USB-Geräten.
4. Funktioniert im Haus und unterwegs gleich – die Verbindung baut die App
   selbst auf, ohne eigenes VPN.

## Installation und Stand

| Plattform | Stand | Bezug |
|---|---|---|
| Linux (Debian 13, amd64) | Paket `rosenweg-vm` (.deb) | Stationen: über os-stationen; sonst [www.rosenweg4303.ch/apps](https://www.rosenweg4303.ch/apps) |
| macOS (arm64, ab macOS 26) | DMG-Installer | [www.rosenweg4303.ch/apps](https://www.rosenweg4303.ch/apps) |
| Windows, Android, iOS | noch nicht gebaut | Stand je Plattform in [docs/plattformen.md](plattformen.md) |

Auf den Stationen ersetzt die App das Programm „Maschinen“
(`os-stationen/roles/desktop/files/vm-konsolen.py`): os-stationen spielt das
Paket `rosenweg-vm` ein und lässt „Maschinen“ stehen, wenn das nicht geht.
