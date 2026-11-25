import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../konfig.dart';
import 'browser_anmeldung.dart';

/// Anmeldung mit dem Rosenweg-Konto (Authentik "rosenweg-apps", PKCE).
///
/// Gespeichert wird nur das Refresh-Token, im sicheren Speicher des Systems
/// (Schluesselbund, libsecret, Windows-Anmeldeinformationen, Android-Keystore).
/// Das Access-Token lebt nur im Speicher. Kein Passwort, kein Client-Geheimnis.
///
/// Wozu ueberhaupt, wenn Proxmox selbst ueber Authentik anmeldet? Fuer den
/// Tunnel: die Haupt-API gibt ihn nur einer angemeldeten Person
/// (POST /api/apps/tunnel). Im Haus braucht es dieses Konto nicht.
class RosenwegKonto {
  RosenwegKonto({FlutterSecureStorage? speicher})
      : _speicher = speicher ??
            const FlutterSecureStorage(
              // Ohne den Data-Protection-Schluesselbund: der braucht eine
              // signierte App mit Team-ID, was im Entwicklungsbau fehlt.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  final FlutterSecureStorage _speicher;
  String? _zugang;
  DateTime _zugangBis = DateTime.fromMillisecondsSinceEpoch(0);
  String? name;
  String? email;

  static const _rt = 'rosenweg_refresh_token';

  static String _zufall(int n) {
    final r = Random.secure();
    return base64UrlEncode(List<int>.generate(n, (_) => r.nextInt(256))).replaceAll('=', '');
  }

  Future<bool> get angemeldet async => (await _speicher.read(key: _rt)) != null;

  /// Browser-Anmeldung. Meist ohne Eingabe, weil Authentik im Browser die
  /// Sitzung schon kennt.
  Future<void> anmelden() async {
    final verifier = _zufall(48);
    final state = _zufall(24);
    final challenge = base64UrlEncode(sha256.convert(ascii.encode(verifier)).bytes).replaceAll('=', '');
    final rueck = await BrowserAnmeldung.oeffnen('/anmeldung');
    final url = Uri.parse('${Konfig.authentik}/authorize/').replace(queryParameters: {
      'response_type': 'code',
      'client_id': Konfig.clientId,
      'redirect_uri': rueck.adresse,
      'scope': Konfig.scopes,
      'state': state,
      'code_challenge': challenge,
      'code_challenge_method': 'S256',
    });
    final antwort = await rueck.warten(url);
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
    await _profil();
  }

  /// Gueltiges Access-Token; erneuert es bei Bedarf. null = nicht angemeldet.
  Future<String?> zugangsToken() async {
    if (_zugang != null && DateTime.now().isBefore(_zugangBis.subtract(const Duration(minutes: 1)))) {
      return _zugang;
    }
    final rt = await _speicher.read(key: _rt);
    if (rt == null) return null;
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
    await _speicher.delete(key: _rt);
  }

  Future<void> _uebernehmen(Map<String, dynamic> j) async {
    _zugang = j['access_token'] as String;
    _zugangBis = DateTime.now().add(Duration(seconds: (j['expires_in'] as num?)?.toInt() ?? 300));
    final rt = j['refresh_token'] as String?;
    if (rt != null) await _speicher.write(key: _rt, value: rt);
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
  Future<Map<String, dynamic>?> _token(Map<String, String> felder) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final r = await c.postUrl(Uri.parse('${Konfig.authentik}/token/'));
      r.headers.contentType = ContentType('application', 'x-www-form-urlencoded', charset: 'utf-8');
      r.write(Uri(queryParameters: felder).query);
      final a = await r.close();
      final text = await a.transform(utf8.decoder).join();
      if (a.statusCode == 200) return jsonDecode(text) as Map<String, dynamic>;
      return null; // Token nie protokollieren, auch nicht im Fehlerfall.
    } finally {
      c.close();
    }
  }
}

class AnmeldeFehler implements Exception {
  AnmeldeFehler(this.text);
  final String text;
  @override
  String toString() => text;
}
