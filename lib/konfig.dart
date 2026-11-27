// SPDX-License-Identifier: GPL-3.0-or-later
/// Feste Angaben des Hauses, die nur die VM-App braucht. Nichts davon ist
/// geheim. Authentik, Client und Kerberos stehen seit 1.2.0 in
/// rosenweg_basis (`RosenwegKonfig`), siehe lib/vm_app.dart.
library;

class Konfig {
  /// Haupt-API: legt beim vm-gateway den Tunnel-Zugang an (POST /api/apps/tunnel).
  /// Proxmox selbst kennt die App nicht mehr; das macht der Gateway.
  static const api = 'https://rosenweg4303.ch';

  /// Erkennung "im Haus": TXT-Eintrag im INTERNEN DNS (UniFi-Gateway
  /// 100.64.2.1), oeffentlich nicht vorhanden. Exakter Vergleich.
  /// Nur ein Hinweis fuer die Reihenfolge der Endpunkte, keine Sicherheit
  /// (siehe lib/netz/haus_erkennung.dart).
  static const hausDnsName = 'location.rosenweg4303.ch';
  static const hausDnsWert = 'Rosenweg GBT';
  static const hausDnsZeit = Duration(milliseconds: 1500);
}
