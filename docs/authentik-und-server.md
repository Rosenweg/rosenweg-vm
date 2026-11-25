# Was ausserhalb der App eingerichtet werden muss

Nichts davon ist gemacht — die App wurde ohne Änderungen an Servern gebaut.

## Authentik

1. **Anwendung „rosenweg-apps“** (öffentlicher Client, PKCE; schon da für
   commons-rosenweg und Rosenweg Telefon) → Anbieter → Weiterleitungs-URIs
   ergänzen:
   - Modus **Regex**: `^http://localhost:[0-9]+/anmeldung$` (Desktop: Linux,
     Windows, macOS)
   - Modus **Strikt**: `ch.rosenweg4303.vm:/anmeldung` (Android, iOS; erst
     nötig, wenn die Telefon-Anmeldung gebaut ist)
   - Bereiche wie bisher: `openid email profile offline_access`. Prüfen, dass
     `offline_access` ein Refresh-Token ausgibt (die anderen Apps nutzen es).
2. **Anbieter „Proxmox VE“** → Weiterleitungs-URIs:
   - Regex `^http://localhost:[0-9]+/?$` — laut os-stationen
     `docs/konfiguration.md` schon für „Maschinen“ vorgesehen; bitte
     nachsehen, ob er wirklich eingetragen ist.
   - später für Telefone: strikt `ch.rosenweg4303.vm:/proxmox`.

## Haupt-API (Website)

Branch `vm-app-tunnel` im Worktree `/Users/stefan/Documents/Website-vm-app-tunnel`
(von `origin/main`, committet, nicht gepusht):

- `POST /api/apps/tunnel` `{geraet, geraet_name, schluessel}` → `{tunnel:{peer, vlan, adresse, config}}`
- `DELETE /api/apps/tunnel/:geraet`
- Anmeldung: Bearer-Token von `rosenweg-apps`, geprüft über Authentik
  `userinfo` plus `aud/azp == rosenweg-apps` (userinfo allein nähme Tokens
  jeder Authentik-Anwendung). Deaktivierte Konten und fremde
  `authentik_sub` werden abgewiesen wie beim Browser-Login.
- Grenzen: 10/Std., höchstens 5 Geräte je Konto (`docs/sicherheit.md`).
- VLAN = Wohnung der Person (wie Laptop-Stationen), kein Technik-VLAN.
- Keine neue Umgebungsvariable nötig (`ROSENWEG_APPS_CLIENT_ID` optional).
- Ausrollen wie üblich per Skript.

## wg-control

Keine Änderung nötig: `POST /peers` nimmt schon `public_key` und
`allowed_ips` (seit den Laptop-Stationen). Zu prüfen:
- Erreicht ein Peer im **Wohnungs-VLAN** `pve1..3:8006` und `:3128`?
  (Firewall/Routing zwischen Wohnungs-VLAN und Proxmox-Netz.)
- Antwortet der DNS `100.64.2.1` durch den Tunnel?

## Proxmox (je virtuellem Computer)

- Bildschirm: Anzeige **SPICE** (`vga: qxl`), sonst „no spice port“.
- Ton: `audio0: device=ich9-intel-hda,driver=spice`.
- USB durchreichen: `usb0: spice` (je weiterreichbares Gerät ein Eintrag,
  `usb1: spice` …).
- Absolute Maus und Grösse anpassen: im Gast `spice-vdagent` (Linux) bzw.
  „SPICE Guest Tools“ (Windows); QEMU-Gastagent an.
- Rechte wie heute: `VM.Console` auf den Computer (für spiceproxy),
  `VM.PowerMgmt` falls „einschalten“ erlaubt sein soll.

## Stationen (später)

Rolle `desktop`: `85-vm-konsolen.sh` durch das Paket dieser App ersetzen,
udev-Regel für USB (`uaccess`), Menüeintrag-Name in `60-programme`
mitziehen.
