// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show Zugangsquelle;

import '../gateway/gateway.dart';
import '../konfig.dart';
import '../native/rwtunnel.dart';
import '../vm_app.dart';
import 'haus_erkennung.dart';
import 'json_anfrage.dart';

enum Lage { unbekannt, imHaus, unterwegs, keinZugang, test }

/// Der Tunnel zum vm-gateway — im Haus wie unterwegs.
///
/// Die App spricht nie direkt mit Proxmox, sondern immer mit dem Gateway, und
/// zwar durch ihren eigenen WireGuard-Tunnel (im Prozess, ohne Systemrechte).
/// Der Unterschied zwischen "im Haus" und "unterwegs" ist nur der Endpunkt:
/// im Haus die LAN-Adresse des Gateways (kurzer Weg), sonst die oeffentliche.
/// Welcher zuerst, sagt der TXT-Eintrag im internen DNS (haus_erkennung.dart);
/// ob er geht, der WireGuard-Handshake.
/// So gibt es einen einzigen Weg, eine Anmeldung und eine Pruefung — statt
/// eines zweiten, ungetunnelten Wegs fuer zuhause, der eigene Zertifikate und
/// eine zweite Proxmox-Anmeldung braeuchte.
class Netzlage extends ChangeNotifier {
  Netzlage(this._zugang);

  /// Token der aktiven Anmeldung (rosenweg_basis `RosenwegSitzung.zugang`):
  /// Authentik (Konto, Kerberos) oder rw_app_ (Karte, QR, Handy). Haupt-API
  /// und vm-gateway nehmen beide an.
  final Zugangsquelle _zugang;

  Lage lage = Lage.unbekannt;
  Gateway? gateway;

  /// Proxy fuer SPICE: `http://rw:geheimnis@127.0.0.1:port`.
  String? spiceProxy;

  DateTime? letzterHandshake;
  Timer? _waechter;
  String? _geraet;


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
    _geraet ??= await _geraetKennung();
    final paar = RwTunnel.i.schluesselpaar();

    Future<({int status, Object? json})> anfragen(String token) => jsonAnfrage('API Tunnel', (c) async {
          final r = await c.postUrl(Uri.parse('${Konfig.api}/api/apps/tunnel'));
          r.headers
            ..set(HttpHeaders.authorizationHeader, 'Bearer $token')
            ..contentType = ContentType.json;
          r.write(jsonEncode({'geraet': _geraet, 'geraet_name': Platform.localHostname, 'schluessel': paar.oeffentlich}));
          return r.close();
        });
    var token = await _zugang.zugangsToken();
    if (token == null) throw TunnelFehler('Bitte neu anmelden', status: 401);
    var a = await anfragen(token);
    if (a.status == 401) {
      // wie HttpTransport der Basis: einmal erneuern, dann ehrlich melden
      _zugang.zugangUngueltig();
      final neu = await _zugang.zugangsToken();
      if (neu != null && neu != token) {
        token = neu;
        a = await anfragen(token);
      }
    }
    final j = a.json is Map<String, dynamic> ? a.json as Map<String, dynamic> : const <String, dynamic>{};
    if (a.status != 200) throw TunnelFehler((j['error'] as String?) ?? 'Verbindung abgelehnt (${a.status})', status: a.status);
    final antwort = j['tunnel'] as Map<String, dynamic>;

    final konfig = antwort['config'] as String;
    final gw = antwort['gateway'] as String;
    _intern = (antwort['endpoint_intern'] as String?) ?? '';
    _extern = RegExp(r'^Endpoint = (.*)$', multiLine: true).firstMatch(konfig)?.group(1)?.trim() ?? '';

    final start = RwTunnel.i.starten(
      wgQuick: konfig,
      privat: paar.privat,
      erlaubteZiele: ['$gw:80'],
      spiceProxy: '$gw:3128',
    );
    final port = RwTunnel.i.weiterleitung('$gw:80');
    final g = Gateway('http://127.0.0.1:$port', _zugang);
    spiceProxy = 'http://rw:${start.geheimnis}@127.0.0.1:${start.port}';

    final l = await _endpunktWaehlen(g);
    if (l == null) {
      RwTunnel.i.stoppen();
      spiceProxy = null;
      lage = Lage.keinZugang;
      notifyListeners();
      throw TunnelFehler('Das Haus antwortet nicht. Bitte spaeter nochmals versuchen.');
    }
    gateway = g;
    lage = l;
    _waechterStarten();
    _netzBeobachten();
    notifyListeners();
  }

  String _intern = '', _extern = '';
  final _erkennung = HausErkennung(zeit: Konfig.hausDnsZeit);
  StreamSubscription<List<ConnectivityResult>>? _netzAbo;
  Timer? _netzVerzoegerung;

  /// DNS sagt, welchen Endpunkt die App zuerst versucht; ob er wirklich geht,
  /// entscheidet der WireGuard-Handshake (Gateway antwortet durch den Tunnel).
  Future<Lage?> _endpunktWaehlen(Gateway g) async {
    final imHaus = await _erkennung.imHaus();
    return endpunktWaehlen(
      dnsImHaus: imHaus,
      intern: _intern,
      extern: _extern,
      setzen: RwTunnel.i.endpunkt,
      erreichbar: (l) => g.erreichbar(zeit: Duration(seconds: l == Lage.imHaus ? 3 : 10)),
    );
  }

  /// Bei jedem Netzwechsel (WLAN zu, Mobilfunk an …) neu bestimmen und den
  /// Endpunkt im laufenden Tunnel wechseln. Kurz warten, bis das neue Netz
  /// seinen DNS hat.
  void _netzBeobachten() {
    _netzAbo ??= Connectivity().onConnectivityChanged.listen((_) {
      _netzVerzoegerung?.cancel();
      _netzVerzoegerung = Timer(const Duration(seconds: 2), () async {
        final g = gateway;
        if (g == null) return;
        final l = await _endpunktWaehlen(g);
        lage = l ?? Lage.keinZugang;
        notifyListeners();
      });
    });
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
    var g = await vmSpeicher.lesen('geraet');
    if (g == null) {
      final r = Random.secure();
      g = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await vmSpeicher.setzen({'geraet': g});
    }
    return g;
  }

  /// Beim Schliessen und Abmelden: Peer beim Gateway abmelden (Schluessel
  /// sofort ungueltig), dann Tunnel zu.
  Future<void> abbauen() async {
    _waechter?.cancel();
    _netzVerzoegerung?.cancel();
    await _netzAbo?.cancel();
    _netzAbo = null;
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
    _netzVerzoegerung?.cancel();
    _netzAbo?.cancel();
    super.dispose();
  }
}

/// Reihenfolge und Rueckfall, ohne Tunnel testbar.
///
/// DNS-Treffer: zuerst der LAN-Endpunkt ("Im Haus"); scheitert der Handshake
/// dort (fremdes Netz mit vorgetaeuschtem Eintrag, Gateway im LAN gestoert),
/// der oeffentliche ("Unterwegs"). Kein Treffer: zuerst der oeffentliche; der
/// LAN-Endpunkt bleibt nur als Rueckfall (z. B. Eintrag im DNS fehlt noch,
/// oeffentlicher Weg aus dem Haus gesperrt). null = keiner geht.
Future<Lage?> endpunktWaehlen({
  required bool dnsImHaus,
  required String intern,
  required String extern,
  required void Function(String endpunkt) setzen,
  required Future<bool> Function(Lage lage) erreichbar,
}) async {
  final reihe = <(Lage, String)>[
    if (dnsImHaus && intern.isNotEmpty) (Lage.imHaus, intern),
    if (extern.isNotEmpty) (Lage.unterwegs, extern),
    if (!dnsImHaus && intern.isNotEmpty) (Lage.imHaus, intern),
  ];
  for (final (l, ep) in reihe) {
    setzen(ep);
    if (await erreichbar(l)) return l;
  }
  return null;
}
