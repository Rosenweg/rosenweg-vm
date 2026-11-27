// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../protokoll.dart';

/// Server (API, Gateway, Authentik) gerade nicht erreichbar: Neustart,
/// 502/503/504 vom Webserver, HTML statt JSON, Verbindung abgebrochen.
class ServerNichtErreichbar implements Exception {
  @override
  String toString() => 'Der Rosenweg-Server ist gerade nicht erreichbar – bitte gleich nochmals versuchen.';
}

/// 429: zu viele Anfragen; [warten] aus Retry-After, falls angegeben.
class ZuVieleAnfragen implements Exception {
  ZuVieleAnfragen(this.warten);
  final Duration? warten;
  @override
  String toString() {
    final w = warten;
    if (w == null) return 'Zu viele Anfragen – bitte etwas später nochmals versuchen.';
    if (w.inSeconds < 120) return 'Zu viele Anfragen – bitte in ${w.inSeconds} Sekunden nochmals versuchen.';
    return 'Zu viele Anfragen – bitte in ${(w.inSeconds / 60).ceil()} Minuten nochmals versuchen.';
  }
}

/// Antwort mit Status und gelesenem JSON (null bei leerem Text).
typedef JsonAntwort = ({int status, Object? json});

/// Schickt eine Anfrage und liest JSON. Bei 502/503/504, Nicht-JSON oder
/// Verbindungsfehlern bis zu [versuche] Mal mit Rueckoff (2 s, 4 s, …);
/// danach [ServerNichtErreichbar]. Bei 429 [ZuVieleAnfragen].
/// Statuscode und Rohtext (gekuerzt) nur ins app.log — nie bei 200, damit
/// keine Tokens im Log landen.
///
/// [senden] baut die Anfrage auf dem gegebenen Client jedes Mal neu.
Future<JsonAntwort> jsonAnfrage(
  String quelle,
  Future<HttpClientResponse> Function(HttpClient c) senden, {
  int versuche = 3,
  Duration zeit = const Duration(seconds: 30),
  Duration rueckoff = const Duration(seconds: 2),
}) async {
  for (var n = 1; ; n++) {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    String grund;
    try {
      final a = await senden(c).timeout(zeit);
      final text = await a.transform(utf8.decoder).join().timeout(zeit);
      final status = a.statusCode;
      if (status == 429) {
        final ra = int.tryParse(a.headers.value('retry-after') ?? '');
        Protokoll.schreiben('$quelle: 429 (Retry-After: ${ra ?? '-'})');
        throw ZuVieleAnfragen(ra == null ? null : Duration(seconds: ra));
      }
      Object? json;
      var lesbar = true;
      if (text.trim().isNotEmpty) {
        try {
          json = jsonDecode(text);
        } on FormatException {
          lesbar = false;
        }
      }
      if (lesbar && status != 502 && status != 503 && status != 504) return (status: status, json: json);
      final roh = text.length > 300 ? '${text.substring(0, 300)} …' : text;
      grund = 'Status $status, ${lesbar ? 'JSON' : 'kein JSON'}: ${roh.replaceAll(RegExp(r'\s+'), ' ')}';
    } on SocketException catch (e) {
      grund = 'Verbindung: ${e.message}';
    } on HttpException catch (e) {
      grund = 'HTTP: ${e.message}';
    } on TimeoutException {
      grund = 'Zeitueberschreitung';
    } finally {
      c.close();
    }
    Protokoll.schreiben('$quelle: Server nicht erreichbar (Versuch $n/$versuche) — $grund');
    if (n >= versuche) throw ServerNichtErreichbar();
    await Future<void>.delayed(rueckoff * (1 << (n - 1)));
  }
}
