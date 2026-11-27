// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/native/rwspice.dart';
import 'package:rosenweg_vm/spice/bedien_einstellung.dart';
import 'package:rosenweg_vm/spice/bildschirm.dart';

import 'hilfen/attrappe.dart';

/// 800x600 Testflaeche, Gast 1024x768: das Bild fuellt sie genau, Massstab
/// 0,78125 – eine Widget-Stelle mal 1,28 ist die Gaststelle.
Future<AttrappeZiel> aufbauen(WidgetTester tester) async {
  final ziel = AttrappeZiel();
  await tester.pumpWidget(MaterialApp(home: Scaffold(body: SpiceBildschirm(ziel: ziel))));
  ziel.melden(SpiceEreignisArt.bildGroesse, 1024, 768);
  await tester.pump();
  ziel.leeren();
  return ziel;
}

Future<void> tipp(WidgetTester tester, Offset p, int ms, {int pointer = 1}) async {
  final g = await tester.createGesture(pointer: pointer, kind: PointerDeviceKind.touch);
  await g.down(p, timeStamp: Duration(milliseconds: ms));
  await g.up(timeStamp: Duration(milliseconds: ms + 60));
  await tester.pump();
}

void main() {
  setUp(() => BedienEinstellung.i.zuruecksetzen());

  testWidgets('Tippen = Linksklick genau an der Stelle', (tester) async {
    final ziel = await aufbauen(tester);
    await tipp(tester, const Offset(400, 300), 0);
    expect(ziel.maus, ['pos 512,384', 'taste 1 ab', 'taste 1 auf']);
  });

  testWidgets('Doppeltipp = Doppelklick an derselben Stelle', (tester) async {
    final ziel = await aufbauen(tester);
    await tipp(tester, const Offset(100, 100), 0);
    await tipp(tester, const Offset(110, 104), 200); // leicht daneben
    expect(ziel.maus, [
      'pos 128,128', 'taste 1 ab', 'taste 1 auf', //
      'pos 128,128', 'taste 1 ab', 'taste 1 auf',
    ]);
    // Spaeter ist es wieder ein einzelner Klick an der neuen Stelle
    ziel.leeren();
    await tipp(tester, const Offset(110, 104), 2000);
    expect(ziel.maus.first, 'pos 141,133');
  });

  testWidgets('Lange druecken = Rechtsklick mit Vibration', (tester) async {
    final vibriert = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'HapticFeedback.vibrate') vibriert.add(c.arguments as String);
      return null;
    });
    final ziel = await aufbauen(tester);
    final g = await tester.startGesture(const Offset(200, 200), kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 600));
    await g.up();
    await tester.pump();
    expect(ziel.maus, ['pos 256,256', 'taste 3 ab', 'taste 3 auf']);
    expect(vibriert, ['HapticFeedbackType.mediumImpact']);
  });

  testWidgets('Ziehen = mit gedrueckter linker Taste ziehen', (tester) async {
    final ziel = await aufbauen(tester);
    final g = await tester.startGesture(const Offset(100, 100), kind: PointerDeviceKind.touch);
    await g.moveBy(const Offset(50, 0));
    await g.moveBy(const Offset(50, 0));
    await g.up();
    await tester.pump();
    expect(ziel.maus.first, 'pos 128,128');
    expect(ziel.maus[1], 'taste 1 ab');
    expect(ziel.maus.last, 'taste 1 auf');
    expect(ziel.maus, contains('pos 256,128'));
  });

  testWidgets('Zwei Finger ziehen = Mausrad, kein Klick', (tester) async {
    final ziel = await aufbauen(tester);
    final a = await tester.startGesture(const Offset(300, 300), pointer: 1, kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(const Offset(400, 300), pointer: 2, kind: PointerDeviceKind.touch);
    for (var i = 0; i < 6; i++) {
      await a.moveBy(const Offset(0, -20));
      await b.moveBy(const Offset(0, -20));
    }
    await a.up();
    await b.up();
    await tester.pump();
    // Finger hoch = Inhalt hoch = im Gast nach unten scrollen (Taste 5)
    expect(ziel.maus.where((m) => m.startsWith('taste 5 ab')).length, greaterThanOrEqualTo(3));
    expect(ziel.maus.where((m) => m.startsWith('taste 1')), isEmpty);
    expect(ziel.maus.where((m) => m.startsWith('taste 4')), isEmpty);
  });

  testWidgets('Spreizen = Zoom; dann verschiebt ein Finger das Bild, Knopf stellt zurueck', (tester) async {
    final ziel = await aufbauen(tester);
    expect(find.byKey(const ValueKey('zoom-zurueck')), findsNothing);
    final a = await tester.startGesture(const Offset(350, 300), pointer: 1, kind: PointerDeviceKind.touch);
    final b = await tester.startGesture(const Offset(450, 300), pointer: 2, kind: PointerDeviceKind.touch);
    for (var i = 0; i < 5; i++) {
      await a.moveBy(const Offset(-20, 0));
      await b.moveBy(const Offset(20, 0));
    }
    await a.up();
    await b.up();
    await tester.pump();
    expect(ziel.maus.where((m) => m.startsWith('taste')), isEmpty);
    // Bild ist nicht da (Attrappe), also kein Knopf; die Umrechnung zeigt den Zoom:
    // Mitte bleibt Mitte, ein Tipp daneben trifft jetzt naeher an der Mitte.
    ziel.leeren();
    await tipp(tester, const Offset(600, 300), 5000);
    expect(ziel.maus.first, 'pos 597,384', reason: 'Zoom 3x um die Mitte: (600-400)/3+400 = 466,7, ×1,28');

    // Ein Finger verschiebt jetzt das Bild, ohne zu klicken
    ziel.leeren();
    final c = await tester.startGesture(const Offset(400, 300), kind: PointerDeviceKind.touch);
    await c.moveBy(const Offset(-100, 0));
    await c.up();
    await tester.pump();
    expect(ziel.maus, isEmpty);
  });

  testWidgets('Touchpad-Modus: Finger schiebt den Zeiger, Tippen klickt beim Zeiger', (tester) async {
    BedienEinstellung.i.zuruecksetzen(touch: TouchModus.touchpad);
    final ziel = await aufbauen(tester);
    final g = await tester.startGesture(const Offset(100, 500), kind: PointerDeviceKind.touch);
    await g.moveBy(const Offset(30, 0));
    await g.moveBy(const Offset(70, 0));
    await g.up();
    await tester.pump();
    // Zeiger startet in der Mitte (512,384) und geht 100 px * 1,28 nach rechts
    expect(ziel.maus.last, 'pos 640,384');
    expect(ziel.maus.where((m) => m.startsWith('taste')), isEmpty);
    ziel.leeren();
    await tipp(tester, const Offset(700, 100), 9000);
    expect(ziel.maus, ['pos 640,384', 'taste 1 ab', 'taste 1 auf']);
  });
}
