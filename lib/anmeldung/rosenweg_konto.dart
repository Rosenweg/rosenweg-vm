// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show Anmeldeweg, AnmeldungAbgebrochen;

import '../konfig.dart';
import '../netz/json_anfrage.dart';
import '../protokoll.dart';
import 'schluesselbund.dart';

/// Anmeldung mit dem Rosenweg-Konto (Authentik "rosenweg-apps", PKCE).
///
/// Gespeichert wird nur das Refresh-Token, im sicheren Speicher des Systems
/// (Schluesselbund, libsecret, Windows-Anmeldeinformationen, Android-Keystore).
/// Das Access-Token lebt nur im Speicher. Kein Passwort, kein Client-Geheimnis.
///
/// Das ist die EINZIGE Anmeldung der App: dasselbe Token oeffnet den Tunnel
/// (Haupt-API) und alle Anfragen an den vm-gateway; der fragt Proxmox, was
/// diese Person darf.
class RosenwegKonto {
  RosenwegKonto({Schluesselbund? speicher}) : _speicher = speicher ?? Schluesselbund.i;

  final Schluesselbund _speicher;
  String? _zugang;
  DateTime _zugangBis = DateTime.fromMillisecondsSinceEpoch(0);
  String? name;
  String? email;

  static const _rt = 'refresh_token';
  static const _am = 'angemeldet_am';

  /// Entscheid Stefan: beim Start still anmelden, wenn die letzte Anmeldung im
  /// Browser hoechstens 30 Tage her ist; danach wieder durch den Browser.
  /// Gezaehlt wird ab der Browser-Anmeldung, nicht ab dem letzten Erneuern —
  /// sonst wuerde ein taeglich genutztes Geraet nie mehr nachgefragt.
  static const hoechstensAlt = Duration(days: 30);

  static String _zufall(int n) {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(n, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  Future<bool> get angemeldet async {
    if (await _speicher.lesen(_rt) == null) return false;
    if (await _zuAlt()) {
      await abmelden();
      return false;
    }
    return true;
  }

  Future<bool> _zuAlt() async {
    final am = DateTime.tryParse(await _speicher.lesen(_am) ?? '');
    return am == null || DateTime.now().difference(am) > hoechstensAlt;
  }

  /// Browser-Anmeldung. Meist ohne Eingabe, weil Authentik im Browser die
  /// Sitzung schon kennt.
  Future<void> anmelden() async {
    final verifier = _zufall(48);
    final state = _zufall(24);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    // Desktop: localhost-Port; Android: Schema ch.rosenweg4303.vm:/anmeldung
    // ueber die Ruecksprung-Activity von rosenweg_basis (wie alle Rosenweg-Apps).
    final rueck = await Anmeldeweg.fuer(Konfig.telefonRuecksprung).vorbereiten();
    final url = Uri.parse('${Konfig.authentik}/authorize/').replace(queryParameters: {
      'response_type': 'code',
      'client_id': Konfig.clientId,
      'redirect_uri': rueck.adresse,
      'scope': Konfig.scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    final Uri antwort;
    try {
      antwort = await rueck.warten(url);
    } on AnmeldungAbgebrochen {
      throw AnmeldeFehler('Anmeldung abgebrochen');
    }
    final q = antwort.queryParameters;
    if (q['error'] != null || q['code'] == null) throw AnmeldeFehler('Anmeldung abgebrochen');
    if (q['state'] != state) throw AnmeldeFehler('Anmeldung abgelaufen, bitte nochmals');
    final j = await _token({
      'grant_type': 'authorization_code',
      'code': q['code']!,
      'redirect_uri': rueck.adresse,
      'client_id': Konfig.clientId,
      'code_verifier': verifier,
    });
    if (j == null) throw AnmeldeFehler('Rosenweg-Anmeldung fehlgeschlagen');
    await _uebernehmen(j);
    await _speicher.setzen({_am: DateTime.now().toUtc().toIso8601String()});
    await _profil();
  }

  /// Gueltiges Access-Token; erneuert es bei Bedarf. null = nicht angemeldet.
  Future<String?> zugangsToken() async {
    if (_zugang != null && DateTime.now().isBefore(_zugangBis.subtract(const Duration(minutes: 1)))) {
      return _zugang;
    }
    final rt = await _speicher.lesen(_rt);
    if (rt == null) return null;
    if (await _zuAlt()) {
      await abmelden();
      return null;
    }
    final j = await _token({'grant_type': 'refresh_token', 'refresh_token': rt, 'client_id': Konfig.clientId});
    if (j == null) {
      // Widerrufen oder abgelaufen: ehrlich abmelden statt still weiterprobieren.
      await abmelden();
      return null;
    }
    await _uebernehmen(j);
    if (name == null) await _profil();
    return _zugang;
  }

  Future<void> abmelden() async {
    _zugang = null;
    _zugangBis = DateTime.fromMillisecondsSinceEpoch(0);
    name = email = null;
    await _speicher.setzen({_rt: null, _am: null});
  }

  Future<void> _uebernehmen(Map<String, dynamic> j) async {
    _zugang = j['access_token'] as String;
    _zugangBis = DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 300));
    final rt = j['refresh_token'] as String?;
    if (rt != null) await _speicher.setzen({_rt: rt});
  }

  Future<void> _profil() async {
    try {
      final c = HttpClient();
      final r = await c.getUrl(Uri.parse('${Konfig.authentik}/userinfo/'));
      r.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_zugang');
      final a = await r.close();
      if (a.statusCode == 200) {
        final u = jsonDecode(await a.transform(utf8.decoder).join()) as Map<String, dynamic>;
        name = u['name'] as String?;
        email = u['email'] as String?;
      }
      c.close();
    } catch (_) {
      // Nur fuer die Anzeige; ohne Namen geht alles weiter.
    }
  }

  /// null bei 400/401 (abgelaufen/widerrufen). Wirft bei Netzfehlern.
  /// Token-Endpunkt von Authentik. null = abgelehnt (abgelaufen, widerrufen).
  /// Ist Authentik nur gerade nicht erreichbar (502, HTML, Netz), wirft
  /// [jsonAnfrage] — dann bleibt die Anmeldung gespeichert, statt dass ein
  /// kurzer Neustart des Servers die Person abmeldet.
  Future<Map<String, dynamic>?> _token(Map<String, String> felder) async {
    final a = await jsonAnfrage('Authentik Token', (c) async {
      final r = await c.postUrl(Uri.parse('${Konfig.authentik}/token/'));
      r.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      r.write(Uri(queryParameters: felder).query);
      return r.close();
    });
    if (a.status == 200 && a.json is Map<String, dynamic>) return a.json as Map<String, dynamic>;
    // Token nie protokollieren; Status genuegt.
    Protokoll.schreiben('Authentik Token: abgelehnt (Status ${a.status})');
    return null;
  }
}

class AnmeldeFehler implements Exception {
  AnmeldeFehler(this.text);
  final String text;
  @override
  String toString() => text;
}
