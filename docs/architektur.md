# Architekturentscheide

Stand 25.11.2026.

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

## 5. WireGuard: im Prozess der App, ohne Systemtunnel

**Entscheid:** wireguard-go mit dem gVisor-Netzstapel (`tun/netstack`) als
Bibliothek in der App (`native/rwtunnel`, Go, c-shared/c-archive), nicht die
WireGuard-App und kein Systemtunnel.

Warum:
- Ein Systemtunnel braucht überall Sonderrechte: Linux root/CAP_NET_ADMIN,
  Windows einen Admin-Dienst mit wintun/wireguard-nt, macOS/iOS eine Network
  Extension mit eigener Apple-Berechtigung, Android den VPN-Dialog. Der
  Netzstapel im Benutzerraum braucht **gar keine** Rechte und keine
  Bestätigung.
- Die App braucht nur zwei Ziele: Proxmox-API (8006) und SPICE-Proxy (3128).
  Nichts im System wird verändert (keine Route, kein DNS); der Tunnel ist weg,
  wenn die App zu ist.
- Ein Code für alle fünf Plattformen.

Geprüfte Flutter-Pakete (25.11.2026): `wireguard_flutter` (0.1.3, letzte
Version März 2024) und `wireguard_flutter_plus` (Fork, 12 Likes) bauen beide
Systemtunnel (wg-quick mit root unter Linux, Dienst unter Windows, Network
Extension auf Apple) — genau die Rechte, die wir vermeiden wollen.

Wie die App den Tunnel benutzt: rwtunnel startet einen **HTTP-CONNECT-Proxy
auf 127.0.0.1** (Zufallsport, Geheimnis pro Start, nur freigegebene Ziele).
- Dart-HttpClient: `findProxy = 'PROXY rw:<geheimnis>@127.0.0.1:<port>'`. TLS
  läuft Ende-zu-Ende durch den Proxy, das Zertifikat wird weiter gegen
  `pve1.rosenweg4303.ch` geprüft.
- spice-glib: Eigenschaft `proxy = http://rw:<geheimnis>@127.0.0.1:<port>`.
  Proxmox erwartet am Port 3128 ein `CONNECT pvespiceproxy:<ticket>:…`; der
  lokale Proxy reicht genau solche Ziele unverändert an den SPICE-Proxy des
  Clusters weiter (ohne das lokale Geheimnis).
- Namen löst der Proxy über den DNS **im Tunnel** auf (100.64.2.1), weil der
  öffentliche DNS für pve1 eine andere Adresse liefert (100.64.90.20 statt
  100.64.2.20/100.64.3.20 intern).

Schlüssel: pro Start ein neues Paar, privat nur im Speicher. Die API ersetzt
den alten Peer dieses Geräts. Damit liegt kein langlebiges Geheimnis auf dem
Gerät, wie gefordert.

Im Haus: Antwortet ein Knoten direkt (`/version` → 401), kein Tunnel. Das
fragt genau das, was gleich gebraucht wird, und erkennt auch Geräte, die schon
einen Tunnel haben (Laptop-Stationen).

## 6. Anmeldung

Zwei Anmeldungen, beide über Authentik, meist ohne Eingabe:
1. **Rosenweg-Konto** (Anwendung `rosenweg-apps`, öffentlich, PKCE) — nur für
   den Tunnel nötig. Refresh-Token im sicheren Speicher des Systems.
2. **Proxmox** über den bestehenden OpenID-Realm `authentik`
   (`/access/openid/auth-url` + `/login`), wie „Maschinen“. Das Ticket (2 h)
   wird stündlich mit sich selbst erneuert.

Desktop: Rücksprung auf `http://localhost:<Zufallsport>`. Telefone: eigenes
Schema `ch.rosenweg4303.vm:/…` (folgt). Was in Authentik einzutragen ist:
docs/authentik-und-server.md.

Warum nicht nur eine Anmeldung: Proxmox nimmt keine fremden Tokens an, und die
Haupt-API kennt keine Proxmox-Tickets. Die zweite Anmeldung kostet keine
Eingabe, weil der Browser die Authentik-Sitzung schon hat.

## 7. Bedienung

Eine Liste „Meine Computer“, ein Tipp öffnet den Bildschirm, ein Tipp auf einen
ausgeschalteten fragt „einschalten?“. Oben rechts ein Chip: „Im Haus“ /
„Unterwegs · sicher verbunden“. Keine Begriffe wie VM, Knoten, SPICE, Proxy.
Im Bildschirm nur: Ton, Mikrofon, USB, Strg+Alt+Entf.

Tastatur: die App schickt die **physische** Taste (Scancode), nicht das
Zeichen. Das Schweizer Layout macht der Gast; sonst kämen Z und Y vertauscht an.
