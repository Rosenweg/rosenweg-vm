// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:rosenweg_basis/rosenweg_basis.dart' show Zugangsquelle;

import '../netz/json_anfrage.dart';

/// Ein Computer (virtuelle Maschine) so, wie die Oberflaeche ihn braucht.
/// Keine Proxmox-Begriffe nach aussen.
class Computer {
  Computer({required this.vmid, required this.name, required this.laeuft, this.darfOeffnen = true, this.darfEinschalten = false});
  final int vmid;
  final String name;
  final bool laeuft;
  final bool darfOeffnen;
  final bool darfEinschalten;
}

/// Die Schnittstelle des vm-gateway, erreichbar nur durch den Tunnel
/// (lokale Weiterleitung auf 127.0.0.1). Jede Anfrage traegt das
/// Token der Anmeldung (Authentik oder rw_app_ von Karte/QR/Handy); der
/// Gateway prueft es und fragt Proxmox, was diese Person darf. Darum gibt es
/// in der App keine zweite Anmeldung.
class Gateway {
  Gateway(this.basis, this._zugang);

  /// z. B. http://127.0.0.1:53122 (Weiterleitung zu 10.243.43.1:80)
  final String basis;
  final Zugangsquelle _zugang;

  Future<dynamic> _ruf(String methode, String pfad) async {
    var token = await _zugang.zugangsToken();
    if (token == null) throw GatewayFehler(401, 'Bitte neu anmelden');
    Future<({int status, Object? json})> einmal(String t) => jsonAnfrage('Gateway $methode $pfad', (c) async {
          final r = await c.openUrl(methode, Uri.parse('$basis$pfad'));
          r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $t');
          return r.close();
        });
    var a = await einmal(token);
    if (a.status == 401) {
      // Karten-Zugang lebt 15 Minuten: einmal erneuern, dann ehrlich melden.
      _zugang.zugangUngueltig();
      final neu = await _zugang.zugangsToken();
      if (neu != null && neu != token) {
        token = neu;
        a = await einmal(token);
      }
    }
    final j = a.json;
    if (a.status != 200) {
      final m = j is Map ? j['error'] as String? : null;
      throw GatewayFehler(a.status, m ?? 'Fehler ${a.status}');
    }
    return j;
  }

  /// Antwortet der Gateway? Fuer "im Haus" (interner Endpunkt) vs. unterwegs.
  Future<bool> erreichbar({Duration zeit = const Duration(seconds: 3)}) async {
    final c = HttpClient()..connectionTimeout = zeit;
    try {
      final r = await c.getUrl(Uri.parse('$basis/gesundheit'));
      final a = await r.close().timeout(zeit);
      await a.drain<void>();
      return a.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  Future<List<Computer>> computer() async {
    final l = (await _ruf('GET', '/computer') as List<dynamic>).cast<Map<String, dynamic>>();
    return [
      for (final v in l)
        Computer(
          vmid: v['vmid'] as int,
          name: v['name'] as String,
          laeuft: v['laeuft'] as bool,
          darfOeffnen: v['darf_oeffnen'] as bool,
          darfEinschalten: v['darf_einschalten'] as bool,
        ),
    ];
  }

  Future<void> einschalten(Computer c) => _ruf('POST', '/computer/${c.vmid}/einschalten');

  /// SPICE-Ticket (kurzlebig). Der Gateway merkt sich das Ziel fuer genau
  /// dieses Geraet; nur damit laesst er die SPICE-Verbindung durch.
  Future<SpiceZugang> spice(Computer c) async =>
      SpiceZugang.aus(await _ruf('POST', '/computer/${c.vmid}/bildschirm') as Map<String, dynamic>);

  /// Beim Schliessen der App: Peer sofort entfernen (Schluessel ungueltig).
  Future<void> abmelden() async {
    try {
      await _ruf('POST', '/abmelden').timeout(const Duration(seconds: 2));
    } catch (_) {
      // Sonst raeumt der Gateway nach wenigen Minuten ohne Lebenszeichen auf.
    }
  }
}

class SpiceZugang {
  SpiceZugang({required this.host, required this.tlsPort, required this.passwort, this.ca, this.hostSubject, this.titel});

  factory SpiceZugang.aus(Map<String, dynamic> d) {
    int zahl(Object? v) => v == null ? 0 : int.tryParse('$v') ?? 0;
    return SpiceZugang(
      host: d['host'] as String,
      tlsPort: zahl(d['tls-port']),
      passwort: d['password'] as String,
      // In der .vv-Form stehen Zeilenumbrueche als "\n"; spice-glib will echte.
      ca: (d['ca'] as String?)?.replaceAll(r'\n', '\n'),
      hostSubject: d['host-subject'] as String?,
      titel: d['title'] as String?,
    );
  }

  final String host;
  final int tlsPort;
  final String passwort;
  final String? ca;
  final String? hostSubject;
  final String? titel;
}

class GatewayFehler implements Exception {
  GatewayFehler(this.status, this.text);
  final int status;
  final String text;
  @override
  String toString() => text;
}
