// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/native/rwspice.dart';
import 'package:rosenweg_vm/spice/aufloesung.dart';
import 'package:rosenweg_vm/spice/bedien_einstellung.dart';
import 'package:rosenweg_vm/spice/bildschirm.dart';

import 'hilfen/attrappe.dart';

void main() {
  test('Handy hochkant, quer, Tablet, Rechner', () {
    // A37 hochkant: 412x871 logisch (ohne Leisten), Dichte 2,625
    expect(gastAufloesung(const Size(412, 871), 2.625), const Size(720, 1522));
    // gedreht
    expect(gastAufloesung(const Size(915, 368), 2.625), const Size(1784, 720));
    // Tablet quer
    expect(gastAufloesung(const Size(1280, 756), 2), const Size(1280, 756));
    // Rechnerfenster: logische Pixel
    expect(gastAufloesung(const Size(1440, 856), 2), const Size(1440, 856));
    // Dichte 1 und winziges Fenster: nichts (lieber einpassen)
    expect(gastAufloesung(const Size(400, 300), 1), isNull);
    expect(gastAufloesung(Size.zero, 3), isNull);
    // Breite immer in Achterschritten
    expect(gastAufloesung(const Size(1001, 701), 1)!.width % 8, 0);
  });

  Future<AttrappeZiel> aufbauen(WidgetTester tester, Size flaeche) async {
    final ziel = AttrappeZiel();
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600), devicePixelRatio: 2.625),
        child: SpiceBildschirm(ziel: ziel, flaeche: flaeche),
      ),
    ));
    ziel.melden(SpiceEreignisArt.bildGroesse, 1024, 768);
    await tester.pump();
    return ziel;
  }

  testWidgets('mit Agent: Gast bekommt die Geraetegroesse, auch nach dem Drehen', (tester) async {
    BedienEinstellung.i.zuruecksetzen();
    final ziel = await aufbauen(tester, const Size(412, 871));
    await tester.pump(const Duration(seconds: 1));
    expect(ziel.groessen, isEmpty, reason: 'ohne Agent nichts');

    ziel.melden(SpiceEreignisArt.agent, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(ziel.groessen, [(720, 1522)]);

    // Drehen: neue Flaeche
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: const MediaQueryData(size: Size(800, 600), devicePixelRatio: 2.625),
        child: SpiceBildschirm(ziel: ziel, flaeche: const Size(915, 368)),
      ),
    ));
    await tester.pump(const Duration(seconds: 1));
    expect(ziel.groessen, [(720, 1522), (1784, 720)]);
  });

  testWidgets('Schalter aus: Aufloesung bleibt', (tester) async {
    BedienEinstellung.i.zuruecksetzen(aufloesungAnpassen: false);
    final ziel = await aufbauen(tester, const Size(412, 871));
    ziel.melden(SpiceEreignisArt.agent, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(ziel.groessen, isEmpty);
    BedienEinstellung.i.zuruecksetzen();
  });
}
