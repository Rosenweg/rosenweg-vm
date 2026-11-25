import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../anmeldung/rosenweg_konto.dart';
import '../konfig.dart';
import '../native/rwtunnel.dart';
import '../proxmox/proxmox.dart';

enum Lage { unbekannt, imHaus, unterwegs, keinZugang, test }

/// Im Haus oder unterwegs — und wenn unterwegs, der eigene Tunnel.
///
/// Erkennung: Antwortet ein Proxmox-Knoten direkt, ist die App im Haus (oder
/// das Geraet hat schon einen Tunnel, etwa eine Laptop-Station). Dann kein
/// eigener Tunnel. Das ist genauer als eine Pruefung auf WLAN-Namen oder
/// Adressbereiche: es fragt genau das, was gleich gebraucht wird.
class Netzlage extends ChangeNotifier {
  Netzlage(this._konto);
  final RosenwegKonto _konto;

  Lage lage = Lage.unbekannt;

  /// Knoten, mit dem die App spricht (pve1 …).
  String? host;

  /// Proxy fuer Proxmox-API und SPICE, nur unterwegs gesetzt (`rw:geheimnis@127.0.0.1:port`).
  String? _proxyAuth;

  /// Letzter Handshake des Tunnels (fuer die Anzeige "Verbindung steht").
  DateTime? letzterHandshake;
  Timer? _waechter;
  String? _geraet;

  static const _speicher = FlutterSecureStorage(mOptions: MacOsOptions(usesDataProtectionKeychain: false));

  String? get proxyFuerHttp => _proxyAuth;

  /// spice-glib-Schreibweise: `http://rw:geheimnis@127.0.0.1:port`.
  /// Im Haus der Proxy aus spiceproxy (http://pve1…:3128) unveraendert.
  String spiceProxy(String ausProxmox) => _proxyAuth == null ? ausProxmox : 'http://$_proxyAuth';

  /// Kurzer Satz fuer die Kopfzeile. Keine Technikbegriffe.
  String get beschreibung => switch (lage) {
        Lage.unbekannt => 'Verbindung wird geprueft …',
        Lage.imHaus => 'Im Haus',
        Lage.unterwegs => _tunnelFrisch ? 'Unterwegs · sicher verbunden' : 'Unterwegs · Verbindung wird aufgebaut …',
        Lage.keinZugang => 'Keine Verbindung zum Haus',
        Lage.test => 'Testbetrieb ohne Hausnetz',
      };

  bool get _tunnelFrisch =>
      letzterHandshake != null && DateTime.now().difference(letzterHandshake!) < const Duration(minutes: 3);

  /// Sucht einen Knoten ohne Tunnel. true = im Haus.
  Future<bool> direktPruefen() async {
    lage = Lage.unbekannt;
    notifyListeners();
    for (final k in Konfig.proxmoxKnoten) {
      if (await Proxmox(k).erreichbar()) {
        host = k;
        lage = Lage.imHaus;
        notifyListeners();
        return true;
      }
    }
    return false;
  }

  /// Baut den eigenen Tunnel auf. Braucht das Rosenweg-Konto.
  ///
  /// Pro Start ein neues Schluesselpaar: der private Schluessel liegt nur im
  /// Speicher und ist mit der App weg. Die API ersetzt dabei den alten Peer
  /// dieses Geraets, statt einen weiteren anzulegen.
  Future<void> tunnelAufbauen() async {
    final token = await _konto.zugangsToken();
    if (token == null) throw AnmeldeFehler('Fuer unterwegs bitte mit dem Rosenweg-Konto anmelden');
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
      if (a.statusCode != 200) throw TunnelFehler((j['error'] as String?) ?? 'Tunnel abgelehnt (${a.statusCode})');
      antwort = j['tunnel'] as Map<String, dynamic>;
    } finally {
      c.close();
    }

    final start = RwTunnel.i.starten(
      wgQuick: antwort['config'] as String,
      privat: paar.privat,
      erlaubteZiele: [for (final k in Konfig.proxmoxKnoten) '$k:${Konfig.proxmoxPort}'],
      // Alle SPICE-Verbindungen ueber den ersten erreichbaren Knoten; dessen
      // spiceproxy reicht selbst an den richtigen Knoten weiter.
      spiceProxy: '${Konfig.proxmoxKnoten.first}:${Konfig.spiceProxyPort}',
    );
    _proxyAuth = 'rw:${start.geheimnis}@127.0.0.1:${start.port}';
    lage = Lage.unterwegs;
    _waechterStarten();
    notifyListeners();

    // Erster Handshake kann ein paar Sekunden dauern.
    for (final k in Konfig.proxmoxKnoten) {
      if (await Proxmox(k, proxy: _proxyAuth).erreichbar(zeit: const Duration(seconds: 10))) {
        host = k;
        // Der SPICE-Proxy muss derselbe Knoten sein, ueber den die API laeuft.
        if (k != Konfig.proxmoxKnoten.first) {
          RwTunnel.i.stoppen();
          final neu = RwTunnel.i.starten(
            wgQuick: antwort['config'] as String,
            privat: paar.privat,
            erlaubteZiele: [for (final k2 in Konfig.proxmoxKnoten) '$k2:${Konfig.proxmoxPort}'],
            spiceProxy: '$k:${Konfig.spiceProxyPort}',
          );
          _proxyAuth = 'rw:${neu.geheimnis}@127.0.0.1:${neu.port}';
        }
        notifyListeners();
        return;
      }
    }
    lage = Lage.keinZugang;
    notifyListeners();
    throw TunnelFehler('Der Tunnel steht, aber kein Rechner des Hauses antwortet');
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

  /// Zufaellige, nicht geheime Kennung dieses Geraets fuer den Peer-Namen.
  Future<String> _geraetKennung() async {
    var g = await _speicher.read(key: 'rosenweg_geraet');
    if (g == null) {
      final r = Random.secure();
      g = List.generate(16, (_) => r.nextInt(16).toRadixString(16)).join();
      await _speicher.write(key: 'rosenweg_geraet', value: g);
    }
    return g;
  }

  /// Beim Abmelden: Tunnel zu und Peer bei der API zurueckziehen.
  Future<void> abbauen({bool peerLoeschen = false}) async {
    _waechter?.cancel();
    if (_proxyAuth != null) RwTunnel.i.stoppen();
    _proxyAuth = null;
    letzterHandshake = null;
    if (peerLoeschen && _geraet != null) {
      final token = await _konto.zugangsToken();
      if (token != null) {
        final c = HttpClient();
        try {
          final r = await c.deleteUrl(Uri.parse('${Konfig.api}/api/apps/tunnel/$_geraet'));
          r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
          await (await r.close()).drain<void>();
        } catch (_) {
          // Bleibt der Peer stehen, ist er ohne privaten Schluessel wertlos
          // und laesst sich in der ISP-Verwaltung entfernen.
        } finally {
          c.close();
        }
      }
    }
    lage = Lage.unbekannt;
    notifyListeners();
  }

  @override
  void dispose() {
    _waechter?.cancel();
    super.dispose();
  }
}
