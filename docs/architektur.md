# Architekturentscheide

Stand 25.11.2026.

## Ablauf im Überblick

```
Start ─► Rosenweg-Konto (Authentik rosenweg-apps, PKCE)
         still, wenn die letzte Browser-Anmeldung ≤ 30 Tage her ist
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

## 1. SPICE: spice-client-glib, dynamisch gelinkt, hinter einer eigenen C-Schicht

**Entscheid (Stefan): SPICE direkt, nicht VNC zuerst.** Umgesetzt mit der
Referenzbibliothek `spice-client-glib-2.0` (Teil von spice-gtk, das auch
remote-viewer benutzt), nicht mit einem eigenen SPICE-Protokoll in Dart.

Warum spice-glib:
- Das Protokoll ist gross (Bildkompressionen QUIC/LZ/GLZ/JPEG, Opus-Ton,
  usbredir, TLS mit Proxmox-Ticket, Proxy). spice-glib kann das alles und ist
  dieselbe Bibliothek, mit der heute „Maschinen“ (über remote-viewer) läuft.
- Ton und USB-Durchreichen sind darin schon enthalten: wir müssen nur PCM an
  ein Audiogerät geben und USB-Geräte schalten.

Warum eine eigene C-Schicht (`native/rwspice`) statt spice-glib direkt aus Dart:
- spice-glib ist GObject mit Signalen und läuft komplett im GLib-Hauptkontext.
  Die C-Schicht reicht jeden Aufruf per Idle-Quelle in diesen Kontext und
  meldet Ereignisse über einen einzigen Callback (`NativeCallable.listener`).
- Die Schnittstelle zu Dart ist klein und flach (15 Funktionen, `rwspice.h`).
  Plattformteile (Texture, Audio) hängen an dieser Schicht, nicht an Dart.
- Lehre aus dem ersten Test: `g_main_context_invoke` führt den Aufruf sofort
  im aufrufenden Thread aus, wenn der Kontext gerade frei ist — spice-glib lief
  dann im Dart-Thread. Deshalb Idle-Quellen.

Linux: Flutters GTK-Einbettung dreht den GLib-Standardkontext bereits; dort
startet rwspice keinen eigenen Thread (`rw_spice_start(0, …)`). Sonst eigener
Thread.

**Lizenz:** spice-glib, GLib, usbredir, libusb: LGPL-2.1+. Deshalb immer
dynamisch gelinkt; librwspice ist selbst eine eigene dynamische Bibliothek.
miniaudio: Public Domain / MIT-0. wireguard-go: MIT, gVisor: Apache-2.0.

## 2. Bild: Puffer in C, heute ui.Image in Dart, später Texture

rwspice kopiert bei jedem `display-invalidate` den geänderten Bereich in einen
eigenen BGRA-Puffer (Alpha fest auf 0xFF; bei xRGB ist das vierte Byte oft 0
und würde sonst durchsichtig gezeichnet). Dart holt ihn pro Bildschirmtakt ab,
wenn sich etwas geändert hat, und baut ein `ui.Image`.

Warum zuerst so: derselbe Dart-Code auf allen fünf Plattformen, kein
plattformeigener Code für das erste Bild. Für Büroarbeit an 1080p reicht das.
Nächster Schritt: eine Flutter-Texture je Plattform (Linux
`FlPixelBufferTexture`, macOS/iOS `CVPixelBuffer`, Windows
`PixelBufferTexture`, Android `SurfaceTexture`), gespeist aus demselben Puffer
— die C-Schnittstelle bleibt gleich, nur `bildschirm.dart` bekommt eine
zweite Darstellung.

## 3. Ton: spice-glib dekodiert, miniaudio spielt ab

spice-glib liefert über die Signale `playback-start/-data/-stop` fertiges PCM
(S16, Opus schon dekodiert) und will über `record-start` PCM vom Mikrofon.
rwspice hängt dort einen Ringpuffer (400 ms) und ein miniaudio-Gerät an.

Damit braucht die App **kein GStreamer** für Ton. Das ist der grösste
Einzelgewinn für Android/iOS/Windows, weil GStreamer dort der schwerste Teil
des Stapels wäre. (Ohne GStreamer-Video bleibt bei SPICE nur MJPEG-Streaming,
das spice-glib eingebaut hat; normale Bildaktualisierungen sind davon nicht
betroffen. Proxmox schaltet Videostreaming standardmässig ohnehin aus.)

Mikrofon: standardmässig aus. Erst wenn die Person es in der Leiste einschaltet
UND der Gast aufnimmt, öffnet rwspice das Eingabegerät. Ein Gast soll nicht
ungefragt mithören können.

## 4. USB: spice-glib UsbDeviceManager, nie automatisch

`enable-usbredir` an, `auto-connect` aus. Die Leiste zeigt die Liste der
Geräte mit Schalter; nicht weiterreichbare Geräte erscheinen ausgegraut mit
Grund. Rechte und Treiber je Plattform: docs/plattformen.md.

## 5. Netz: eigener Gateway-CT (Entscheid Stefan, 26.11.2026)

Die App spricht **nie direkt** mit Proxmox, sondern immer mit dem
**vm-gateway** (eigener LXC, `gateway/`), im Haus wie unterwegs. Der
App-Tunnel endet dort, getrennt von wg-control und den Wohnungs-VLANs. Der
Gateway ist als Einziger zu `pve*:8006/3128` zugelassen.

Beide Enden laufen als wireguard-go mit Netzstapel **im Prozess**: auf dem
Gerät ohne Systemrechte (kein root, kein Admin-Dienst, keine Network
Extension, kein VPN-Dialog), auf dem Gateway ohne Schnittstelle und ohne
Weiterleiten. Durch den Tunnel erreicht eine App genau zwei Ports des
Gateways (80 Schnittstelle, 3128 SPICE). Das ist die Bauweise, nicht eine
Firewall-Regel.

Geprüfte Flutter-Pakete (25.11.2026): `wireguard_flutter` (0.1.3, letzte
Version März 2024) und `wireguard_flutter_plus` (Fork) bauen Systemtunnel —
genau die Rechte, die wir vermeiden.

**Im Haus und unterwegs derselbe Weg.** Ursprünglich sollte die App im Haus
ohne Tunnel gehen. Mit dem Gateway wäre das ein zweiter Weg mit eigenem
TLS-Zertifikat und ohne Gerätebindung. Stattdessen nimmt die App im Haus den
LAN-Endpunkt des Gateways (`endpoint_intern`, kurzer Weg) und sonst den
öffentlichen. Was sie wählt, zeigt der Chip („Im Haus“ / „Unterwegs“).

**Erkennung per DNS (Entscheid Stefan):** Beim Start und bei jedem Netzwechsel
(`connectivity_plus`, 2 s Ruhe) fragt die App über den **Resolver des
Geräts** den TXT-Eintrag `location.rosenweg4303.ch` ab (Zeitgrenze 1,5 s,
exakter Vergleich mit `Rosenweg GBT`; Name, Wert und Zeit in
`lib/konfig.dart`). Den Eintrag gibt es nur im internen DNS.
- Treffer → zuerst LAN-Endpunkt, Chip „Im Haus“.
- Kein Treffer, NXDOMAIN, keine Antwort, Fehler → zuerst öffentlicher
  Endpunkt, „Unterwegs“.
- **Die Sicherheit hängt nicht am DNS.** Ob ein Endpunkt gilt, entscheidet der
  WireGuard-Handshake (Gateway antwortet durch den Tunnel). Täuscht ein Netz
  den Eintrag vor, scheitert der Handshake am LAN-Endpunkt, und die App fällt
  auf den öffentlichen zurück. Ohne Treffer bleibt der LAN-Endpunkt nur als
  Rückfall, falls der öffentliche Weg nicht geht.
- Der Wechsel geschieht im **laufenden** Tunnel (`rwt_endpunkt`, WireGuard-
  Roaming): ein offener Bildschirm reisst beim Netzwechsel nicht ab.

DNS-Client: eigener kleiner Client in Dart (`lib/netz/haus_erkennung.dart`,
UDP, nur TXT), weil die gängigen Pakete feste Server (Google, Cloudflare)
fragen — genau das darf hier nicht sein. Die Server des Systems:

| Plattform | Woher |
|---|---|
| Linux | `/etc/resolv.conf`; mit systemd-resolved `127.0.0.53`, der die Server des aktuellen Netzes fragt |
| macOS | `/etc/resolv.conf` (von configd gepflegt), sonst `scutil --dns` |
| Windows | `Get-DnsClientServerAddress` (PowerShell), sonst `ipconfig /all` |
| Android | `ConnectivityManager.getLinkProperties(activeNetwork).dnsServers` über den Kanal `ch.rosenweg4303.vm/netz` (MainActivity.kt) |
| iOS | folgt mit der iOS-App (`res_9_getservers` aus libresolv). Bis dahin ohne Server: „Unterwegs“, sicher, nur etwas längerer Weg |

Auf dem Gerät: rwtunnel öffnet auf 127.0.0.1 einen CONNECT-Proxy (Geheimnis
pro Start) für SPICE und eine Weiterleitung für die Gateway-Schnittstelle
(einfaches HTTP im Tunnel; WireGuard verschlüsselt und weist den Absender aus).

## 6. Anmeldung: eine einzige (Entscheid Stefan)

- **Nur das Rosenweg-Konto** (Authentik `rosenweg-apps`, PKCE). Das Token
  öffnet den Tunnel (Haupt-API) und jede Anfrage an den Gateway. Es gibt
  **keine** zweite Proxmox-Anmeldung im Browser mehr.
- **Still beim Start**, wenn die letzte Browser-Anmeldung höchstens 30 Tage
  her ist (Refresh-Token im sicheren Speicher). Danach wieder Browser.
  Gezählt wird ab der Browser-Anmeldung, nicht ab dem letzten Erneuern.
- **Tunnel-Schlüssel**: pro Start neu, privat nur im Speicher. Beim Schliessen
  meldet die App den Peer beim Gateway ab (`POST /abmelden`), der Schlüssel ist
  sofort wertlos. Stürzt die App ab, entfernt der Gateway den Peer nach 3
  Minuten ohne Handshake bzw. 5 Minuten Stille.
- **Rechte**: der Gateway fragt Proxmox mit eigenem API-Token, aber **für die
  Person** (`/access/permissions?userid=<name>@authentik&path=/vms/<id>`).
  Sicherheitsbewertung: gateway/README.md.

## 7. Bedienung

Eine Liste „Meine Computer“, ein Tipp öffnet den Bildschirm, ein Tipp auf einen
ausgeschalteten fragt „einschalten?“. Oben rechts ein Chip: „Im Haus“ /
„Unterwegs · sicher verbunden“. Keine Begriffe wie VM, Knoten, SPICE, Proxy.
Im Bildschirm nur: Ton, Mikrofon, USB, Strg+Alt+Entf.

Tastatur: die App schickt die **physische** Taste (Scancode), nicht das
Zeichen. Das Schweizer Layout macht der Gast; sonst kämen Z und Y vertauscht an.
