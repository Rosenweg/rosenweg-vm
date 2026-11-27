// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/oberflaeche/sondertasten_leiste.dart';
import 'package:rosenweg_vm/spice/bildschirm.dart';
import 'package:rosenweg_vm/spice/bildschirm_tastatur.dart';
import 'package:rosenweg_vm/spice/tastatur.dart';

import 'hilfen/attrappe.dart';

/// Bildschirm mit Leiste darunter, wie auf der Bildschirmseite.
Future<(AttrappeZiel, BildschirmSteuerung)> aufbauen(WidgetTester tester) async {
  final ziel = AttrappeZiel();
  final st = BildschirmSteuerung();
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [
        Expanded(child: SpiceBildschirm(ziel: ziel, steuerung: st)),
        ListenableBuilder(
          listenable: st,
          builder: (context, _) => st.tastaturOffen ? SondertastenLeiste(steuerung: st) : const SizedBox.shrink(),
        ),
      ]),
    ),
  ));
  await tester.pump();
  return (ziel, st);
}

/// Taste der Leiste antippen; vorher seitlich hinschieben.
Future<void> tasteTippen(WidgetTester tester, String key) async {
  final f = find.byKey(ValueKey(key));
  await tester.scrollUntilVisible(f, 80,
      scrollable: find.descendant(of: find.byKey(const ValueKey('sondertasten')), matching: find.byType(Scrollable)));
  await tester.tap(f);
  await tester.pump();
}

/// Tastenereignis direkt an den Bildschirm geben (wie es Flutter fuer eine
/// Taste ohne Scancode liefert; der Simulator im Test kann scanCode 0 nicht).
void ereignis(WidgetTester tester, KeyEvent e) {
  final fokus = tester.widget<Focus>(
      find.descendant(of: find.byType(SpiceBildschirm), matching: find.byWidgetPredicate((w) => w is Focus && w.onKeyEvent != null)).first);
  fokus.onKeyEvent!(fokus.focusNode!, e);
}

const ohneSc = PhysicalKeyboardKey(0x1100000043);

void main() {
  testWidgets('Leiste: Strg halten, dann Pfeil – Strg geht mit und laesst los', (tester) async {
    final (ziel, st) = await aufbauen(tester);
    st.tastatur(true);
    await tester.pump();
    expect(find.byKey(const ValueKey('sondertasten')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('umschalter-strg')));
    await tester.pump();
    expect(st.gehalten, {Umschalter.strg});

    await tester.tap(find.byKey(const ValueKey('taste-←')));
    await tester.pump();
    expect(ziel.tasten, [(scStrg, true), (0x14b, true), (0x14b, false), (scStrg, false)]);
    expect(st.gehalten, isEmpty, reason: 'Umschalter gelten nur fuer einen Tastendruck');
  });

  testWidgets('Leiste: Esc, Rueckschritt, Entf, F5 und Strg+Alt+Entf', (tester) async {
    final (ziel, st) = await aufbauen(tester);
    st.tastatur(true);
    await tester.pump();
    for (final k in ['Esc', '⌫', 'Entf', 'F5', 'strg-alt-entf']) {
      await tasteTippen(tester, 'taste-$k');
    }
    expect(ziel.gedrueckt, [0x01, 0x0e, 0x153, 0x3f, 0x1d, 0x38, 0x153]);
  });

  testWidgets('echte Taste ohne Scancode (adb, Bildschirmtastatur): Rueckschritt kommt an', (tester) async {
    final (ziel, _) = await aufbauen(tester);
    await tester.tap(find.byType(SpiceBildschirm)); // Fokus aufs Bild
    ziel.leeren();
    ereignis(tester, const KeyDownEvent(physicalKey: ohneSc, logicalKey: LogicalKeyboardKey.backspace, timeStamp: Duration.zero));
    ereignis(tester, const KeyUpEvent(physicalKey: ohneSc, logicalKey: LogicalKeyboardKey.backspace, timeStamp: Duration.zero));
    // Buchstaben ohne Scancode gingen schon vorher (ueber das Zeichen)
    ereignis(tester, const KeyDownEvent(physicalKey: ohneSc, logicalKey: LogicalKeyboardKey.keyT, character: 'T', timeStamp: Duration.zero));
    ereignis(tester, const KeyUpEvent(physicalKey: ohneSc, logicalKey: LogicalKeyboardKey.keyT, timeStamp: Duration.zero));
    expect(ziel.tasten, [(0x0e, true), (0x0e, false), (scShift, true), (0x14, true), (0x14, false), (scShift, false)]);
  });

  testWidgets('echte Taste mit gehaltenem Strg aus der Leiste: Strg+A in der Gastbelegung', (tester) async {
    final (ziel, st) = await aufbauen(tester);
    st.tastatur(true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('umschalter-strg')));
    ziel.leeren();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.keyA, character: 'a');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.keyA);
    expect(ziel.tasten, [(scStrg, true), (0x1e, true), (0x1e, false), (scStrg, false)]);
  });

  group('Bildschirmtastatur (Android)', () {
    final android = TargetPlatformVariant.only(TargetPlatform.android);

    testWidgets('Knopf oeffnet sie; Tippen, Umlaut, Rueckschritt, Enter gehen zum Gast', (tester) async {
      final (ziel, st) = await aufbauen(tester);
      st.tastatur(true);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isTrue);
      expect(tester.testTextInput.setClientArgs?['inputType']?['name'], 'TextInputType.multiline');
      expect(tester.testTextInput.setClientArgs?['autocorrect'], isFalse);
      expect(tester.testTextInput.setClientArgs?['enableSuggestions'], isFalse);

      void feld(String t) => tester.testTextInput.updateEditingValue(
          TextEditingValue(text: t, selection: TextSelection.collapsed(offset: t.length)));

      feld('${imePlatzhalter}H');
      feld('${imePlatzhalter}Hä');
      feld('${imePlatzhalter}H'); // Rueckschritt
      feld('${imePlatzhalter}H\n'); // Enter
      await tester.pump();
      expect(ziel.gedrueckt, [scShift, 0x23, 0x28, 0x0e, 0x1c]);

      st.tastatur(false);
      await tester.pump();
      expect(tester.testTextInput.isVisible, isFalse);
    }, variant: android);

    testWidgets('Komposition: ´ dann é ersetzt das Zeichen', (tester) async {
      final (ziel, st) = await aufbauen(tester);
      st.tastatur(true);
      await tester.pump();
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: '$imePlatzhalter´',
        selection: const TextSelection.collapsed(offset: 9),
        composing: const TextRange(start: 8, end: 9),
      ));
      tester.testTextInput.updateEditingValue(const TextEditingValue(
        text: '$imePlatzhalteré',
        selection: TextSelection.collapsed(offset: 9),
      ));
      await tester.pump();
      // ´ (CH: Shift+^-Taste, Tottaste, dann Leertaste), zurueck, é (CH: Shift+ö)
      final runter = ziel.gedrueckt;
      // ´ gibt es in der CH-Belegung nicht als Zeichen: nicht gesendet, also
      // auch nicht zuruecknehmen.
      expect(runter, [scShift, 0x27]);
    }, variant: android);

    testWidgets('Umschalter aus der Leiste gelten auch fuer die Bildschirmtastatur', (tester) async {
      final (ziel, st) = await aufbauen(tester);
      st.tastatur(true);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('umschalter-strg')));
      ziel.leeren();
      tester.testTextInput.updateEditingValue(
          const TextEditingValue(text: '${imePlatzhalter}c', selection: TextSelection.collapsed(offset: 9)));
      await tester.pump();
      expect(ziel.tasten, [(scStrg, true), (0x2e, true), (0x2e, false), (scStrg, false)]);
    }, variant: android);
  });
}
