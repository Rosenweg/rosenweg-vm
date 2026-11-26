// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/anmeldung/schluesselbund.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const roh = FlutterSecureStorage();

  test('alte Einzel-Eintraege werden in einen uebernommen und geloescht', () async {
    FlutterSecureStorage.setMockInitialValues({
      'rosenweg_refresh_token': 'rt1',
      'rosenweg_angemeldet_am': '2026-11-26T12:47:07Z',
      'rosenweg_geraet': 'abc',
    });
    final s = Schluesselbund(roh);
    expect(await s.lesen('refresh_token'), 'rt1');
    expect(await s.lesen('geraet'), 'abc');
    final alle = await roh.readAll();
    expect(alle.keys, ['rosenweg_vm']);
    expect(jsonDecode(alle['rosenweg_vm']!), {
      'refresh_token': 'rt1',
      'angemeldet_am': '2026-11-26T12:47:07Z',
      'geraet': 'abc',
    });
  });

  test('setzen und entfernen in einem Eintrag; leer = Eintrag weg', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final s = Schluesselbund(roh);
    await s.setzen({'refresh_token': 'x', 'angemeldet_am': 'y'});
    expect((await roh.readAll()).keys, ['rosenweg_vm']);
    await s.setzen({'refresh_token': null, 'angemeldet_am': null});
    expect(await roh.readAll(), isEmpty);
    expect(await Schluesselbund(roh).lesen('refresh_token'), isNull);
  });
}
