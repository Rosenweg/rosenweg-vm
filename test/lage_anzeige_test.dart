// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/anmeldung/rosenweg_konto.dart';
import 'package:rosenweg_vm/anmeldung/schluesselbund.dart';
import 'package:rosenweg_vm/app_zustand.dart';
import 'package:rosenweg_vm/netz/netzlage.dart';
import 'package:rosenweg_vm/oberflaeche/start_seite.dart';

void main() {
  final netz = Netzlage(RosenwegKonto(speicher: Schluesselbund(const FlutterSecureStorage(), () async => true)));

  String text(Phase p) => lageAnzeige(p, netz).$3;

  test('vor der Verbindung sagt die Anzeige, worauf die App wartet', () {
    netz.lage = Lage.unbekannt;
    expect(text(Phase.kontoNoetig), 'Bitte anmelden');
    expect(text(Phase.pruefen), 'Einen Moment …');
    expect(text(Phase.anmelden), 'Anmeldung im Browser …');
    expect(text(Phase.tunnel), 'Verbindung wird aufgebaut …');
    expect(text(Phase.fehler), 'Nicht verbunden');
  });

  test('sobald die Netzlage etwas weiss, gilt sie', () {
    netz.lage = Lage.imHaus;
    expect(text(Phase.liste), 'Im Haus · verbunden');
    netz.lage = Lage.keinZugang;
    expect(text(Phase.fehler), 'Keine Verbindung zum Haus');
    netz.lage = Lage.unbekannt;
  });
}
