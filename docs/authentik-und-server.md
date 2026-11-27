# Was ausserhalb der App eingerichtet werden muss

Nichts davon ist gemacht — App, Gateway und API-Änderung wurden ohne Eingriff
an Servern gebaut.

## Authentik

**Anwendung „rosenweg-apps“** (öffentlicher Client, PKCE; schon da für
commons-rosenweg und Rosenweg Telefon) → Anbieter:
- Weiterleitungs-URIs ergänzen:
  - Modus **Regex**: `^http://localhost:[0-9]+/anmeldung$` (Linux, Windows, macOS)
  - Modus **Strikt**: `ch.rosenweg4303.vm:/anmeldung` (Android, iOS; erst nötig,
    wenn die Telefon-Anmeldung gebaut ist)
- Bereiche wie bisher: `openid email profile offline_access`.
- **Gültigkeit des Refresh-Tokens ≥ 30 Tage** (Anbieter → „Refresh Token
  validity“, z. B. `days=31`). Die App fragt nach 30 Tagen selbst wieder
  über den Browser; läuft das Token vorher ab, kommt die Frage früher.
- Der Claim `preferred_username` muss dem Benutzernamen im Proxmox-Realm
  `authentik` entsprechen (`joerg.herrmann` ↔ `joerg.herrmann@authentik`).
  Sonst im Gateway `PVE_BENUTZER_CLAIM` anpassen.

**Stille Anmeldung (Kerberos)** an Stationen und Windows-Rechnern der Domäne
(`RosenwegKonto.stillAnmelden`, siehe rosenweg-basis `docs/authentik.md`):
- Kerberos-Quelle `ad-kerberos` (SPN `HTTP/authentik.rosenweg4303.ch@AD.ROSENWEG4303.CH`),
  Benutzerzuordnung AD-Konto = Authentik-Benutzer — für die Stationen schon da.
- `rosenweg-apps` mit **impliziter** Zustimmung, sonst fragt Authentik nach
  Zustimmung und die App fällt auf den Browser zurück
  (Website-Repo `scripts/authentik-apps-sso.sh`).
- Ruecksprung `http://localhost:0/anmeldung` passt auf die Regex oben.

Der Anbieter „Proxmox VE“ braucht für die App **nichts Neues** mehr: es gibt
keine Proxmox-Anmeldung im Browser.

## vm-gateway (neuer CT)

Siehe [gateway/README.md](../gateway/README.md), Abschnitt „Einrichten“:
- CT anlegen (Debian 13, unprivilegiert, LAN-Adresse im Servernetz)
- `setup.sh`, `/etc/vm-gateway/env` ausfüllen
- Proxmox: Benutzer `vm-gateway@pve`, Rolle `VMGateway` (`VM.Audit`,
  `VM.Console`, `VM.PowerMgmt` auf `/vms`; `Sys.Audit` auf `/access`), Token
  `vm-gateway@pve!app` mit Rechte-Trennung. **Prüfen**, ob `spiceproxy` mit
  dem Token ein brauchbares Ticket gibt.
- Router: UDP **51831** von `kooperation.rosenweg4303.ch` auf den CT.
- Firewall: hinein nur 51831/udp (alle) und 8080/tcp (nur CT 128);
  hinaus nur pve1–3:8006/3128, Authentik 443, DNS (nftables im CT,
  `gateway/nftables.conf`).

## Interner DNS (UniFi-Gateway 100.64.2.1)

Für die Erkennung „im Haus“: TXT-Eintrag **`location.rosenweg4303.ch`** mit
dem Wert **`Rosenweg GBT`** (genau so, Gross-/Kleinschreibung zählt), **nur
im internen DNS**, nicht bei Cloudflare. In UniFi: Einstellungen → Routing →
DNS → Eintrag vom Typ TXT. Prüfen aus einem Hausnetz:
`dig +short TXT location.rosenweg4303.ch` → `"Rosenweg GBT"`; von aussen
darf nichts kommen. (Am 26.11.2026 lieferte der Resolver im Netz des
Entwicklungs-Macs den Eintrag bereits.)

## Haupt-API (Website)

Branch `vm-app-tunnel` (PR offen, nicht gemergt):
- `POST /api/apps/tunnel` `{geraet, geraet_name, schluessel}` →
  `{tunnel:{config, adresse, gateway, endpoint_intern}}`
- `DELETE /api/apps/tunnel/:geraet` (Rückfallweg)
- Neue Variablen in `/opt/rosenweg-core/.env`:
  `VM_GATEWAY_URL=http://<CT-Adresse>:8080`,
  `VM_GATEWAY_TOKEN=<GW_STEUER_TOKEN>`.

## wg-control

Keine Änderung. Die App nutzt wg-control nicht mehr.

## Proxmox (je virtuellem Computer)

- Bildschirm: Anzeige **SPICE** (`vga: qxl`), sonst „no spice port“.
- Ton: `audio0: device=ich9-intel-hda,driver=spice`.
- USB durchreichen: `usb0: spice` (je weiterreichbares Gerät ein Eintrag).
- Absolute Maus und Grösse anpassen: im Gast `spice-vdagent` (Linux) bzw.
  „SPICE Guest Tools“ (Windows).
- Rechte der Person wie heute: `VM.Console` (Bildschirm), `VM.PowerMgmt`
  (Einschalten), `VM.Audit` (nur in der Liste sehen).

## Stationen (später)

Rolle `desktop`: `85-vm-konsolen.sh` durch das Paket dieser App ersetzen,
udev-Regel für USB (`uaccess`), Menüeintrag-Name in `60-programme` mitziehen.
