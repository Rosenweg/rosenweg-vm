// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart'
    show ApiAntwort, RosenwegSitzung, Schluesselbund, Transport, Zugangsquelle;
import 'package:rosenweg_vm/app_zustand.dart';
import 'package:rosenweg_vm/native/rwtunnel.dart';
import 'package:rosenweg_vm/netz/netzlage.dart';
import 'package:rosenweg_vm/vm_app.dart';

class _OhneApi implements Transport {
  const _OhneApi();
  @override
  Future<ApiAntwort> senden(String methode, String pfad, {Object? koerper}) async => (status: 503, json: null);
}

class _OhneZugang implements Zugangsquelle {
  @override
  Future<String?> zugangsToken() async => null;
  @override
  void zugangUngueltig() {}
}

/// Netzlage ohne Tunnel: [aufbauen] tut, was der Test vorgibt.
class _Netz extends Netzlage {
  _Netz(this._aufbau) : super(_OhneZugang());
  final Future<void> Function() _aufbau;
  int abgebaut = 0;

  @override
  Future<void> aufbauen() => _aufbau();

  @override
  Future<void> abbauen() async => abgebaut++;
}

AppZustand _zustand(_Netz netz, {Duration zeit = const Duration(milliseconds: 50)}) {
  final sitzung = RosenwegSitzung(vmApp, speicher: Schluesselbund('rosenweg_vm_test'), transport: const _OhneApi());
  return AppZustand(sitzung, netz: netz, aufbauZeit: zeit);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('haengt der Aufbau, kommt nach dem Zeitlimit ein Fehler mit "Nochmals" (A37, 27.11.2026)', () async {
    final netz = _Netz(() => Completer<void>().future); // antwortet nie
    final z = _zustand(netz);
    await z.starten();
    expect(z.phase, Phase.fehler);
    expect(z.fehler, contains('sichere Verbindung ins Haus kam nicht zustande'));
    expect(z.fehlerDetails, contains('Zeitueberschreitung'));
    expect(netz.abgebaut, 1, reason: 'der haengende Versuch wird abgebaut');
  });

  test('lehnen API oder Gateway die Anmeldung ab (401), bleibt die Seite nicht beim Warten stehen', () async {
    // So am A37: Karte angemeldet (Kotlin), alter Gateway kannte rw_app_ nicht
    // -> 401 -> frueher nur nichtMehrAngemeldet(), Anzeige blieb bei "wird aufgebaut".
    final netz = _Netz(() async => throw TunnelFehler('Anmeldung abgelaufen', status: 401));
    final z = _zustand(netz, zeit: const Duration(seconds: 5));
    await z.starten();
    expect(z.phase, Phase.fehler);
    expect(z.fehler, contains('nicht angenommen'));
    expect(z.fehlerDetails, contains('Anmeldung abgelaufen'));
  });

  test('andere Ablehnung des Gateways: sein Satz steht da', () async {
    final netz = _Netz(() async => throw TunnelFehler('Höchstens 5 Geräte gleichzeitig.', status: 429));
    final z = _zustand(netz, zeit: const Duration(seconds: 5));
    await z.starten();
    expect(z.phase, Phase.fehler);
    expect(z.fehler, 'Höchstens 5 Geräte gleichzeitig.');
  });

  test('ein Aufbau innerhalb der Zeit bleibt unberuehrt', () async {
    // Gegenprobe zum Zeitlimit: schneller Aufbau -> kein Abbau, kein Fehler.
    final netz = _Netz(() async {});
    final z = _zustand(netz, zeit: const Duration(seconds: 5));
    await z.starten();
    expect(netz.abgebaut, 0);
    expect(z.phase, isNot(Phase.fehler));
  });
}
