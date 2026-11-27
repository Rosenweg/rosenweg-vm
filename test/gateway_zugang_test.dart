// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show Zugangsquelle;
import 'package:rosenweg_vm/gateway/gateway.dart';

/// Wie die Karten-Sitzung der Basis: Zugang lebt 15 Minuten, nach
/// zugangUngueltig kommt ein neuer.
class _Zugang implements Zugangsquelle {
  _Zugang(this.tokens);
  final List<String?> tokens;
  int i = 0, ungueltig = 0;
  @override
  Future<String?> zugangsToken() async => tokens[i];
  @override
  void zugangUngueltig() {
    ungueltig++;
    if (i < tokens.length - 1) i++;
  }
}

void main() {
  late HttpServer server;
  final gesehen = <String>[];
  setUp(() async {
    gesehen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      final t = (r.headers.value('authorization') ?? '').replaceFirst('Bearer ', '');
      gesehen.add(t);
      r.response.headers.contentType = ContentType.json;
      if (t == 'rw_app_neu' || t == 'authentik') {
        r.response.write(jsonEncode([
          {'vmid': 101, 'name': 'Buero', 'laeuft': true, 'darf_oeffnen': true, 'darf_einschalten': false},
        ]));
      } else {
        r.response.statusCode = 401;
        r.response.write(jsonEncode({'error': 'Anmeldung abgelaufen'}));
      }
      await r.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  String basis() => 'http://127.0.0.1:${server.port}';

  test('abgelaufener Karten-Zugang: einmal erneuern, dann geht es', () async {
    final z = _Zugang(['rw_app_alt', 'rw_app_neu']);
    final l = await Gateway(basis(), z).computer();
    expect(l.single.name, 'Buero');
    expect(gesehen, ['rw_app_alt', 'rw_app_neu']);
    expect(z.ungueltig, 1);
  });

  test('auch das neue Token abgelehnt: 401 an die App (Sitzung meldet neu an)', () async {
    final z = _Zugang(['rw_app_alt', 'rw_app_auch_alt']);
    await expectLater(Gateway(basis(), z).computer(), throwsA(isA<GatewayFehler>().having((e) => e.status, 'status', 401)));
    expect(gesehen.length, 2);
  });

  test('nicht angemeldet: gar keine Anfrage', () async {
    await expectLater(Gateway(basis(), _Zugang([null])).computer(), throwsA(isA<GatewayFehler>()));
    expect(gesehen, isEmpty);
  });

  test('Authentik-Token wie bisher', () async {
    final z = _Zugang(['authentik']);
    expect((await Gateway(basis(), z).computer()).length, 1);
    expect(z.ungueltig, 0);
  });
}
