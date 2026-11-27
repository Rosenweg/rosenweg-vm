// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show Schluesselbund;
import 'package:rosenweg_vm/anmeldung/linux_schluesselbund.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const roh = FlutterSecureStorage();

  test('Dienst da, aber kein Standard-Schluesselbund: nichts anfassen, nichts merken', () async {
    FlutterSecureStorage.setMockInitialValues({'rosenweg_vm': '{"refresh_token":"alt"}'});
    final s = Schluesselbund('rosenweg_vm', speicher: PruefenderSpeicher(innen: roh, bereit: () async => false));
    expect(await s.lesen('refresh_token'), isNull);
    expect(s.nurImSpeicher, isTrue);
    await s.setzen({'refresh_token': 'neu'});
    expect(await s.lesen('refresh_token'), 'neu');
    // Der Eintrag im System bleibt, wie er war: libsecret wurde nie gefragt.
    expect(await roh.readAll(), {'rosenweg_vm': '{"refresh_token":"alt"}'});
  });

  test('Schluesselbund bereit: wie bisher, gefragt wird nur einmal', () async {
    FlutterSecureStorage.setMockInitialValues({});
    var gefragt = 0;
    final s = Schluesselbund('rosenweg_vm', speicher: PruefenderSpeicher(innen: roh, bereit: () async {
      gefragt++;
      return true;
    }));
    await s.setzen({'refresh_token': 'x'});
    await s.setzen({'geraet': 'g'});
    expect(s.nurImSpeicher, isFalse);
    expect((await roh.readAll()).keys, ['rosenweg_vm']);
    expect(gefragt, 1);
  });

  test('alte Einzel-Eintraege von 1.0 werden uebernommen', () async {
    FlutterSecureStorage.setMockInitialValues({'rosenweg_refresh_token': 'rt1'});
    final s = Schluesselbund('rosenweg_vm',
        speicher: PruefenderSpeicher(innen: roh, bereit: () async => true),
        alteEintraege: const {'refresh_token': 'rosenweg_refresh_token'});
    expect(await s.lesen('refresh_token'), 'rt1');
    expect((await roh.readAll()).keys, ['rosenweg_vm']);
  });
}
