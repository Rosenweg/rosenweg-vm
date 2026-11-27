# Rosenweg Virtuelle Computer

Eine App für Windows, macOS, Linux, Android und iOS: einmal anmelden (wie in
allen Rosenweg-Apps: Rosenweg-Karte, Anmelde-QR, „Mit dem Handy anmelden“ oder
Rosenweg-Konto; an Stationen und in der Windows-Domäne still per Kerberos),
die eigenen virtuellen Computer aus dem Proxmox-Cluster sehen, antippen,
Bildschirm (SPICE) mit Ton und USB in der App. Die App aktualisiert sich
selbst (Updater aus `rosenweg_basis`; aus auf Rosenweg-Stationen, dort bringt
os-stationen das Paket).

Ersetzt später auf den Stationen das Python/GTK-Programm „Maschinen“
(`os-stationen/roles/desktop/files/vm-konsolen.py`).

```
Start ─► Anmeldetor aus rosenweg_basis (RosenwegSitzung):
         gespeichert (Konto ≤ 30 Tage, Karten-/QR-/Handy-Sitzung) → still per
         Kerberos → sonst Anmeldeschirm (Karte, QR, Handy, Konto)
         Token: Authentik (Konto/Kerberos) oder rw_app_… (Karte/QR/Handy)
              ▼
         POST /api/apps/tunnel (Haupt-API, nur öffentlicher Schlüssel)
              ▼
         WireGuard im Prozess der App ──► vm-gateway (eigener CT)
         im Haus: LAN-Endpunkt · unterwegs: öffentlicher Endpunkt
              ▼
         Gateway prüft Token + Gerät, fragt Proxmox mit eigenem Token,
         gibt nur, was Proxmox <person>@authentik erlaubt
              ▼
         Liste „Meine Computer“ ─► SPICE durch den Gateway ─► pve:3128
              ▼
         librwspice (spice-client-glib) ─► Bild, Maus, Tastatur, Ton, USB
App zu ─► Peer abgemeldet (Schlüssel ungültig); Absturz ─► Gateway räumt nach 3–5 Min auf
```

## Aufbau

| Ordner | Was | Sprache |
|---|---|---|
| `lib/` | App: Ablauf, Oberfläche, Anmeldung, Gateway-Client, FFI | Dart/Flutter |
| `native/rwspice/` | dünne C-Schicht über spice-client-glib (Bild, Eingaben, Ton über miniaudio, USB) | C |
| `native/rwtunnel/` | WireGuard im Prozess, lokaler CONNECT-Proxy und Weiterleitung | Go |
| `gateway/` | vm-gateway: Tunnel-Ende, Rechteprüfung, Proxmox, SPICE-Weiterreichung; Unit, Setup | Go |
| `integration_test/` | Ende-zu-Ende gegen einen lokalen SPICE-Testserver | Dart |
| `.github/workflows/` | Linux-Bau auf dem eigenen Runner | |
| `docs/` | Entscheide, Plattformen, Einrichtung, Entwicklung, CI | |

Mehr: [docs/architektur.md](docs/architektur.md),
[gateway/README.md](gateway/README.md),
[docs/plattformen.md](docs/plattformen.md),
[docs/authentik-und-server.md](docs/authentik-und-server.md),
[docs/entwicklung.md](docs/entwicklung.md), [docs/ci.md](docs/ci.md).

## Lizenz

GPL-3.0-or-later, siehe [LICENSE](LICENSE). Fremdbibliotheken (spice-glib
und GLib unter LGPL, dynamisch gelinkt) in [LIZENZEN.md](LIZENZEN.md).
