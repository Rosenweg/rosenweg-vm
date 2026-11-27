// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/spice/zwischenablage.dart';

void main() {
  test('Geraet → Gast nur bei neuem Text, Gast → Geraet ohne Echo', () async {
    String? geraet = 'Hallo';
    final anGast = <String>[];
    final z = ZwischenablageAbgleich(
      anGast: anGast.add,
      lesen: () async => geraet,
      schreiben: (t) async => geraet = t,
    );
    await z.geraetPruefen();
    await z.geraetPruefen(); // unveraendert: nicht nochmals
    expect(anGast, ['Hallo']);

    // Gast kopiert (Windows mit CRLF): landet auf dem Geraet, geht nicht zurueck
    await z.gastHat('Zeile 1\r\nZeile 2');
    expect(geraet, 'Zeile 1\nZeile 2');
    await z.geraetPruefen();
    expect(anGast, ['Hallo']);

    geraet = 'Neu';
    await z.geraetPruefen();
    expect(anGast, ['Hallo', 'Neu']);
  });

  test('aus: in keine Richtung', () async {
    String? geraet = 'x';
    final anGast = <String>[];
    final z = ZwischenablageAbgleich(anGast: anGast.add, lesen: () async => geraet, schreiben: (t) async => geraet = t)
      ..an = false;
    await z.geraetPruefen();
    await z.gastHat('vom Gast');
    expect(anGast, isEmpty);
    expect(geraet, 'x');
  });

  test('Lesefehler (keine Berechtigung) stoert nicht', () async {
    final z = ZwischenablageAbgleich(anGast: (_) => fail('nichts senden'), lesen: () async => throw Exception('verweigert'));
    await z.geraetPruefen();
  });
}
