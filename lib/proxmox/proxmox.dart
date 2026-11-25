import 'dart:convert';
import 'dart:io';

import '../anmeldung/browser_anmeldung.dart';
import '../konfig.dart';

/// Ein Computer (virtuelle Maschine) so, wie die Oberflaeche ihn braucht.
/// Keine Proxmox-Begriffe nach aussen: "laeuft", nicht "running".
class Computer {
  Computer({required this.vmid, required this.knoten, required this.name, required this.laeuft});
  final int vmid;
  final String knoten;
  final String name;
  final bool laeuft;
}

/// Der schmale Ausschnitt der Proxmox-API, den die App braucht — derselbe
/// wie im Programm "Maschinen" (vm-konsolen.py), dort stehen auch die Lehren.
///
/// Das Zertifikat wird immer geprueft (Let's Encrypt fuer pve*.rosenweg4303.ch).
/// Durch den Tunnel geht TLS Ende-zu-Ende durch den lokalen Proxy; die
/// Pruefung gilt also auch unterwegs dem echten Namen.
class Proxmox {
  Proxmox(this.host, {this.proxy});

  final String host;

  /// `rw:geheimnis@127.0.0.1:port` unterwegs, null im Haus.
  final String? proxy;

  String? _ticket;
  String? _csrf;
  String? benutzer;
  DateTime _ticketVon = DateTime.fromMillisecondsSinceEpoch(0);

  bool get angemeldet => _ticket != null;

  Uri _url(String pfad) => Uri.parse('https://$host:${Konfig.proxmoxPort}/api2/json$pfad');

  HttpClient _client() {
    final c = HttpClient()
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 15);
    final p = proxy;
    if (p != null) c.findProxy = (_) => 'PROXY $p';
    return c;
  }

  Future<dynamic> _ruf(String methode, String pfad, [Map<String, String>? felder]) async {
    final c = _client();
    try {
      final r = await c.openUrl(methode, _url(pfad));
      if (_ticket != null) r.cookies.add(Cookie('PVEAuthCookie', Uri.encodeComponent(_ticket!)));
      if (felder != null) {
        if (_csrf != null) r.headers.set('CSRFPreventionToken', _csrf!);
        r.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
        r.write(Uri(queryParameters: felder).query);
      }
      final a = await r.close().timeout(const Duration(seconds: 30));
      final text = await a.transform(utf8.decoder).join();
      if (a.statusCode != 200) throw ProxmoxFehler(a.statusCode, text.isEmpty ? a.reasonPhrase : text);
      return (jsonDecode(text) as Map<String, dynamic>)['data'];
    } finally {
      c.close();
    }
  }

  /// Antwortet der Knoten? Ohne Ticket kommt 401 — das genuegt als
  /// Lebenszeichen und beweist zugleich ein gueltiges Zertifikat.
  Future<bool> erreichbar({Duration zeit = const Duration(seconds: 3)}) async {
    final c = _client()..connectionTimeout = zeit;
    try {
      final r = await c.getUrl(_url('/version'));
      final a = await r.close().timeout(zeit);
      await a.drain<void>();
      return a.statusCode == 401 || a.statusCode == 200;
    } catch (_) {
      return false;
    } finally {
      c.close(force: true);
    }
  }

  /// Anmeldung ueber den OpenID-Realm "authentik". Der Browser kennt die
  /// Authentik-Sitzung meist schon; dann blitzt die Seite nur kurz auf.
  Future<void> anmelden() async {
    // Ohne Pfad: der Eintrag in Authentik (Anbieter "Proxmox VE") lautet
    // ^http://localhost:[0-9]+/?$ — derselbe wie fuer "Maschinen".
    final rueck = await BrowserAnmeldung.oeffnen('');
    final url = await _ruf('POST', '/access/openid/auth-url', {'realm': Konfig.realm, 'redirect-url': rueck.adresse}) as String;
    final antwort = await rueck.warten(Uri.parse(url));
    final q = antwort.queryParameters;
    if (q['error'] != null || q['code'] == null || q['state'] == null) {
      throw ProxmoxFehler(0, 'Anmeldung abgebrochen');
    }
    final d = await _ruf('POST', '/access/openid/login', {
      'code': q['code']!,
      'state': q['state']!,
      'redirect-url': rueck.adresse,
    }) as Map<String, dynamic>;
    _uebernehmen(d);
  }

  void _uebernehmen(Map<String, dynamic> d) {
    _ticket = d['ticket'] as String;
    _csrf = d['CSRFPreventionToken'] as String?;
    benutzer = d['username'] as String?;
    _ticketVon = DateTime.now();
  }

  /// Ein Proxmox-Ticket gilt 2 Stunden und laesst sich mit sich selbst
  /// erneuern. So muss niemand nach einer Stunde wieder in den Browser.
  Future<void> ticketErneuern() async {
    if (_ticket == null || benutzer == null) return;
    if (DateTime.now().difference(_ticketVon) < const Duration(minutes: 60)) return;
    final d = await _ruf('POST', '/access/ticket', {'username': benutzer!, 'password': _ticket!}) as Map<String, dynamic>;
    _uebernehmen(d);
  }

  /// Die eigenen Computer. Nach RECHTEN filtert Proxmox anhand des Tickets;
  /// hier nur nach TYP (Container haben keinen Bildschirm, siehe Maschinen).
  Future<List<Computer>> computer() async {
    final alle = (await _ruf('GET', '/cluster/resources?type=vm') as List<dynamic>).cast<Map<String, dynamic>>();
    final liste = [
      for (final v in alle)
        if (v['type'] == 'qemu' && v['template'] != 1)
          Computer(
            vmid: (v['vmid'] as num).toInt(),
            knoten: v['node'] as String,
            name: (v['name'] as String?) ?? 'Computer ${v['vmid']}',
            laeuft: v['status'] == 'running',
          ),
    ];
    liste.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return liste;
  }

  Future<void> einschalten(Computer c) async {
    await _ruf('POST', '/nodes/${c.knoten}/qemu/${c.vmid}/status/start', {});
  }

  /// Verbindungsdaten fuer SPICE (Ticket mit kurzer Laufzeit).
  ///
  /// proxy = dieser Knoten: dessen spiceproxy (Port 3128) reicht zum Knoten
  /// weiter, auf dem die Maschine laeuft. So braucht der Tunnel nur ein Ziel.
  Future<SpiceZugang> spice(Computer c) async {
    try {
      final d = await _ruf('POST', '/nodes/${c.knoten}/qemu/${c.vmid}/spiceproxy', {'proxy': host}) as Map<String, dynamic>;
      return SpiceZugang.aus(d);
    } on ProxmoxFehler catch (e) {
      // "no spice port": Maschine hat keine SPICE-Anzeige (vga: qxl fehlt).
      if (e.text.toLowerCase().contains('spice')) {
        throw ProxmoxFehler(e.status,
            'Fuer diesen Computer ist keine Bildschirmausgabe eingerichtet. Bitte die Technik melden (Anzeige "SPICE" noetig).');
      }
      rethrow;
    }
  }
}

class SpiceZugang {
  SpiceZugang({required this.host, required this.tlsPort, required this.passwort, required this.proxy, this.ca, this.hostSubject, this.titel});

  factory SpiceZugang.aus(Map<String, dynamic> d) {
    int zahl(Object? v) => v == null ? 0 : int.tryParse('$v') ?? 0;
    return SpiceZugang(
      host: d['host'] as String,
      tlsPort: zahl(d['tls-port']),
      passwort: d['password'] as String,
      proxy: d['proxy'] as String,
      // In der .vv-Datei stehen Zeilenumbrueche als "\n"; spice-glib will echte.
      ca: (d['ca'] as String?)?.replaceAll(r'\n', '\n'),
      hostSubject: d['host-subject'] as String?,
      titel: d['title'] as String?,
    );
  }

  final String host;
  final int tlsPort;
  final String passwort;
  final String proxy;
  final String? ca;
  final String? hostSubject;
  final String? titel;
}

class ProxmoxFehler implements Exception {
  ProxmoxFehler(this.status, this.text);
  final int status;
  final String text;
  @override
  String toString() => text;
}
