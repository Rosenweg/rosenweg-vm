// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../anmeldung/rosenweg_konto.dart';
import '../gateway/gateway.dart';
import '../konfig.dart';
import '../native/rwtunnel.dart';

enum Lage { unbekannt, imHaus, unterwegs, keinZugang, test }

/// Der Tunnel zum vm-gateway — im Haus wie unterwegs.
///
/// Die App spricht nie direkt mit Proxmox, sondern immer mit dem Gateway, und
/// zwar durch ihren eigenen WireGuard-Tunnel (im Prozess, ohne Systemrechte).
/// Der Unterschied zwischen "im Haus" und "unterwegs" ist nur der Endpunkt:
/// im Haus die LAN-Adresse des Gateways (kurzer Weg), sonst die oeffentliche.
/// So gibt es einen einzigen Weg, eine Anmeldung und eine Pruefung — statt
/// eines zweiten, ungetunnelten Wegs fuer zuhause, der eigene Zertifikate und
/// eine zweite Proxmox-Anmeldung braeuchte.
class Netzlage extends ChangeNotifier {
  Netzlage(this._konto);
  final RosenwegKonto _konto;

  Lage lage = Lage.unbekannt;
  Gateway? gateway;

  /// Proxy fuer SPICE: `http://rw:geheimnis@127.0.0.1:port`.
  String? spiceProxy;

  DateTime? letzterHandshake;
  Timer? _waechter;
  String? _geraet;

  static const _speicher = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  String get beschreibung => switch (lage) {
        Lage.unbekannt => 'Verbindung wird aufgebaut …',
        Lage.imHaus => 'Im Haus · verbunden',
        Lage.unterwegs => _frisch ? 'Unterwegs · sicher verbunden' : 'Unterwegs · Verbindung unterbrochen',
        Lage.keinZugang => 'Keine Verbindung zum Haus',
        Lage.test => 'Testbetrieb ohne Hausnetz',
      };

  bool get _frisch =>
      letzterHandshake != null && DateTime.now().difference(letzterHandshake!) < const Duration(minutes: 3);

  /// Peer beim Gateway anlegen (ueber die Haupt-API) und Tunnel starten.
  ///
  /// Pro Start ein neues Schluesselpaar, privat nur im Speicher. Beim
  /// Schliessen meldet die App den Peer ab; stuerzt sie ab, entfernt ihn der
  /// Gateway nach wenigen Minuten ohne Lebenszeichen.
  Future<void> aufbauen() async {
    lage = Lage.unbekannt;
    notifyListeners();
    final token = await _konto.zugangsToken();
    if (token == null) throw StateError('Bitte mit dem Rosenweg-Konto anmelden');
    _geraet ??= await _geraetKennung();
    final paar = RwTunnel.i.schluesselpaar();

    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    Map<String, dynamic> antwort;
    try {
      final r = await c.postUrl(Uri.parse('${Konfig.api}/api/apps/tunnel'));
      r.headers
        ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
        ..contentType = ContentType.json;
      r.write(jsonEncode({'geraet': _geraet, 'geraet_name': Platform.localHostname, 'schluessel': paar.oeffentlich}));
      final a = await r.close();
      final text = await a.transform(utf8.decoder).join();
      final j = text.isEmpty ? <String, dynamic>{} : jsonDecode(text) as Map<String, dynamic>;
      if (a.statusCode != 200) throw TunnelFehler((j['error'] as String?) ?? 'Verbindung abgelehnt (${a.statusCode})');
      antwort = j['tunnel'] as Map<String, dynamic>;
    } finally {
      c.close();
    }

    final konfig = antwort['config'] as String;
    final gw = antwort['gateway'] as String;
    final intern = (antwort['endpoint_intern'] as String?) ?? '';

    // Erst intern versuchen (im Haus), dann oeffentlich.
    final versuche = <(Lage, String)>[
      if (intern.isNotEmpty) (Lage.imHaus, konfig.replaceFirst(RegExp(r'^Endpoint = .*$', multiLine: true), 'Endpoint = $intern')),
      (Lage.unterwegs, konfig),
    ];
    for (final (l, k) in versuche) {
      final start = RwTunnel.i.starten(
        wgQuick: k,
        privat: paar.privat,
        erlaubteZiele: ['$gw:80'],
        spiceProxy: '$gw:3128',
      );
      final port = RwTunnel.i.weiterleitung('$gw:80');
      final g = Gateway('http://127.0.0.1:$port', _konto.zugangsToken);
      if (await g.erreichbar(zeit: Duration(seconds: l == Lage.imHaus ? 3 : 10))) {
        gateway = g;
        spiceProxy = 'http://rw:${start.geheimnis}@127.0.0.1:${start.port}';
        lage = l;
        _waechterStarten();
        notifyListeners();
        return;
      }
      RwTunnel.i.stoppen();
    }
    lage = Lage.keinZugang;
    notifyListeners();
    throw TunnelFehler('Das Haus antwortet nicht. Bitte spaeter nochmals versuchen.');
  }

  void _waechterStarten() {
    _waechter?.cancel();
    _waechter = Timer.periodic(const Duration(seconds: 5), (_) {
      final z = RwTunnel.i.zustand();
      final hs = (z?['letzter_handshake'] as num?)?.toInt() ?? 0;
      final neu = hs > 0 ? DateTime.fromMillisecondsSinceEpoch(hs * 1000) : null;
      if (neu != letzterHandshake) {
        letzterHandshake = neu;
        notifyListeners();
      }
    });
  }

  Future<String> _geraetKennung() async {
    var g = await _speicher.read(key: 'rosenweg_geraet');
    if (g == null) {
      final r = Random.secure();
      g = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await _speicher.write(key: 'rosenweg_geraet', value: g);
    }
    return g;
  }

  /// Beim Schliessen und Abmelden: Peer beim Gateway abmelden (Schluessel
  /// sofort ungueltig), dann Tunnel zu.
  Future<void> abbauen() async {
    _waechter?.cancel();
    await gateway?.abmelden();
    gateway = null;
    spiceProxy = null;
    if (lage == Lage.imHaus || lage == Lage.unterwegs) RwTunnel.i.stoppen();
    letzterHandshake = null;
    lage = Lage.unbekannt;
    notifyListeners();
  }

  @override
  void dispose() {
    _waechter?.cancel();
    super.dispose();
  }
}
