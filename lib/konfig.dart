// SPDX-License-Identifier: GPL-3.0-or-later
/// Feste Angaben des Hauses. Nichts davon ist geheim.
///
/// Bewusst im Code und nicht in einer Einstellungsseite: die App soll auf
/// einem fremden Laptop ohne jede Einrichtung funktionieren. Ein Haus, ein
/// Cluster, eine Anmeldung.
library;

class Konfig {
  /// Authentik, Anwendung "rosenweg-apps": oeffentlicher Client mit PKCE,
  /// derselbe wie in commons-rosenweg (RosenwegAnmeldung) und Rosenweg Telefon.
  static const authentik = 'https://authentik.rosenweg4303.ch/application/o';
  static const clientId = 'rosenweg-apps';

  /// offline_access: ohne Refresh-Token muesste die Person bei jedem Start
  /// durch den Browser, auch wenn sie nur zuhause sitzt.
  static const scopes = 'openid email profile offline_access';

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

  /// Schema fuer Ruecksprung auf Telefonen (Android/iOS). Auf Desktops wird
  /// stattdessen ein Port auf localhost geoeffnet, wie im Programm "Maschinen".
  static const appSchema = 'ch.rosenweg4303.vm';

  /// Ruecksprung auf Android (Authentik rosenweg-apps, strikter Eintrag);
  /// die Activity dafuer bringt rosenweg_basis mit (Schema = applicationId).
  static const telefonRuecksprung = '$appSchema:/anmeldung';
}
