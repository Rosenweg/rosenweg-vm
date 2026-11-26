// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/netz/json_anfrage.dart';

void main() {
  late HttpServer server;
  late List<void Function(HttpResponse)> antworten;
  var anfragen = 0;

  setUp(() async {
    anfragen = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) {
      final f = antworten[anfragen.clamp(0, antworten.length - 1)];
      anfragen++;
      f(r.response);
      r.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  Future<JsonAntwort> los() => jsonAnfrage(
    'Test',
    (c) async => (await c.getUrl(Uri.parse('http://127.0.0.1:${server.port}/'))).close(),
    rueckoff: const Duration(milliseconds: 10),
  );

  void html502(HttpResponse r) => r
    ..statusCode = 502
    ..write('<html><body>Bad Gateway</body></html>');

  test('HTML-502 zweimal, dann JSON: klappt beim dritten Versuch', () async {
    antworten = [html502, html502, (r) => r.write('{"ok":true}')];
    final a = await los();
    expect(a.status, 200);
    expect(a.json, {'ok': true});
    expect(anfragen, 3);
  });

  test('immer HTML: verstaendliche Meldung nach 3 Versuchen', () async {
    antworten = [(r) => r.write('<html>Wartung</html>')];
    await expectLater(los(), throwsA(isA<ServerNichtErreichbar>()));
    expect(anfragen, 3);
    expect(ServerNichtErreichbar().toString(), contains('gerade nicht erreichbar'));
  });

  test('429 mit Retry-After: Wartezeit in der Meldung, kein Wiederholen', () async {
    antworten = [
      (r) => r
        ..statusCode = 429
        ..headers.set('Retry-After', '30')
        ..write('{"error":"zu viele"}'),
    ];
    await expectLater(los(), throwsA(predicate((e) => e is ZuVieleAnfragen && '$e'.contains('30 Sekunden'))));
    expect(anfragen, 1);
  });

  test('normaler Fehler mit JSON (403) geht ohne Wiederholen durch', () async {
    antworten = [
      (r) => r
        ..statusCode = 403
        ..write('{"error":"nein"}'),
    ];
    final a = await los();
    expect(a.status, 403);
    expect(anfragen, 1);
  });
}
