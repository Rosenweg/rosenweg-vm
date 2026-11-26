// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// Oeffnet eine Anmeldeseite im Browser und wartet auf den Ruecksprung.
///
/// Desktop (Linux, Windows, macOS): ein kurzlebiger Port auf localhost,
/// wie im Programm "Maschinen" auf den Stationen. Der Port kommt vom
/// Betriebssystem (0), sonst liesse sich die App kein zweites Mal oeffnen.
/// In Authentik steht dafuer eine Regex-Ruecksprungadresse (docs/authentik.md).
///
/// Telefone (Android, iOS): eigenes Schema ch.rosenweg4303.vm:/… ueber ein
/// Browserfenster der Plattform (Custom Tab bzw. ASWebAuthenticationSession).
/// Kommt im naechsten Schritt (flutter_web_auth_2); siehe docs/plattformen.md.
class BrowserAnmeldung {
  /// Startet einen Ruecksprung-Empfaenger und liefert dessen Adresse.
  /// [pfad] ist "/anmeldung" (Eintrag in Authentik bei rosenweg-apps:
  /// Regex ^http://localhost:[0-9]+/anmeldung$).
  static Future<Ruecksprung> oeffnen(String pfad) async {
    if (Platform.isAndroid || Platform.isIOS) {
      throw UnsupportedError('Anmeldung auf Telefonen folgt (eigenes Schema)');
    }
    // IPv4 und, wenn moeglich, IPv6 auf demselben Port: "localhost" loest der
    // Browser je nach System zuerst nach ::1 auf.
    final v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    HttpServer? v6;
    try {
      v6 = await HttpServer.bind(InternetAddress.loopbackIPv6, v4.port, v6Only: true);
    } catch (_) {
      v6 = null;
    }
    return Ruecksprung._(v4, v6, 'http://localhost:${v4.port}$pfad');
  }
}

class Ruecksprung {
  Ruecksprung._(this._v4, this._v6, this.adresse) {
    for (final s in [_v4, if (_v6 != null) _v6]) {
      s.listen(_annehmen);
    }
  }

  final HttpServer _v4;
  final HttpServer? _v6;
  final String adresse;
  final _ergebnis = Completer<Uri>();

  static const _antwortSeite = '''<!doctype html><html lang="de"><head><meta charset="utf-8">
<title>Angemeldet</title></head>
<body style="font-family:sans-serif;text-align:center;padding:4em">
<h1>Angemeldet</h1><p>Sie k&ouml;nnen dieses Fenster schliessen und zur App zur&uuml;ckkehren.</p>
<script>setTimeout(function(){window.close()},1500)</script>
</body></html>''';

  void _annehmen(HttpRequest r) {
    final q = r.uri.queryParameters;
    if (!_ergebnis.isCompleted && (q.containsKey('code') || q.containsKey('error'))) {
      _ergebnis.complete(r.uri);
    }
    r.response
      ..statusCode = 200
      ..headers.contentType = ContentType.html
      ..write(_antwortSeite);
    r.response.close();
  }

  /// Oeffnet [url] im Browser und wartet hoechstens 5 Minuten.
  Future<Uri> warten(Uri url) async {
    try {
      if (!await launchUrl(url, mode: LaunchMode.externalApplication)) {
        throw StateError('Browser liess sich nicht oeffnen');
      }
      return await _ergebnis.future.timeout(const Duration(minutes: 5));
    } finally {
      await _v4.close(force: true);
      await _v6?.close(force: true);
    }
  }
}
