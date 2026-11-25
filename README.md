# Rosenweg Virtuelle Computer

Eine App für Windows, macOS, Linux, Android und iOS: anmelden mit dem
Rosenweg-Konto, die eigenen virtuellen Computer aus dem Proxmox-Cluster sehen,
antippen, Bildschirm (SPICE) in der App. Ausser Haus baut die App selbst eine
WireGuard-Verbindung ins Hausnetz auf; im Haus geht sie direkt.

Ersetzt später auf den Stationen das Python/GTK-Programm „Maschinen“
(`os-stationen/roles/desktop/files/vm-konsolen.py`).

```
Start ─► Proxmox direkt erreichbar? ── ja ─► „Im Haus“
              │ nein
              ▼
        Rosenweg-Konto (Authentik rosenweg-apps, PKCE, Refresh-Token im Schlüsselbund)
              ▼
        POST /api/apps/tunnel (nur öffentlicher Schlüssel) ─► wg-control-Peer
              ▼
        WireGuard im Prozess (wireguard-go + Netzstapel), lokaler Proxy 127.0.0.1
              ▼
Proxmox-Anmeldung (OpenID-Realm „authentik“, Browser) ─► Liste „Meine Computer“
              ▼
        spiceproxy ─► librwspice (spice-client-glib) ─► Bild, Maus, Tastatur, Ton, USB
```

## Aufbau

| Ordner | Was | Sprache |
|---|---|---|
| `lib/` | App: Ablauf, Oberfläche, Anmeldung, Proxmox, FFI | Dart/Flutter |
| `native/rwspice/` | dünne C-Schicht über spice-client-glib (Bild, Eingaben, Ton über miniaudio, USB) | C |
| `native/rwtunnel/` | WireGuard im Prozess + lokaler CONNECT-Proxy | Go |
| `integration_test/` | Ende-zu-Ende gegen einen lokalen SPICE-Testserver | Dart |
| `docs/` | Entscheide, Plattformen, Authentik, Entwicklung | |

Mehr: [docs/architektur.md](docs/architektur.md),
[docs/plattformen.md](docs/plattformen.md),
[docs/authentik-und-server.md](docs/authentik-und-server.md),
[docs/entwicklung.md](docs/entwicklung.md).

## Stand (25.11.2026)

- macOS (Entwicklungsziel): Liste → Tipp → SPICE-Bild in der App läuft gegen
  einen lokalen spice-server; Ton-Wiedergabe öffnet CoreAudio; Tunnel und
  Proxy-Kette getestet. Anmeldung und echte Proxmox-Liste sind gebaut, aber
  noch nicht gegen das Haus ausprobiert (braucht die Einträge in Authentik).
- Linux, Windows, Android, iOS: Projekt angelegt, Tunnel-Bibliothek baut für
  Android und iOS; spice-glib für diese Ziele siehe docs/plattformen.md.
