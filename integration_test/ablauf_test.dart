// SPDX-License-Identifier: GPL-3.0-or-later
// Ende-zu-Ende auf dem Entwicklungsrechner, ohne Hausnetz:
//
//   spice-server/test-display-no-ssl  (lauscht auf 127.0.0.1:5912)
//   flutter test integration_test -d macos \
//     --dart-define=RW_NATIVE_DIR=$PWD/native \
//     --dart-define=RW_TEST_SPICE=127.0.0.1:5912
//
// Prueft: Liste erscheint, Tipp oeffnet den Bildschirm, ein Bild kommt an,
// Maus und Tastatur gehen ohne Absturz durch die C-Schicht.
//
// Fuer ein Foto: App mit denselben --dart-define bauen, starten und nur ihr
// Fenster aufnehmen (screencapture -l <Fenster-ID>), siehe docs/entwicklung.md.
// Ein Foto ueber den Layer-Baum im Test liess die Knoepfe der Kopfzeile weg.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rosenweg_vm/main.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('Liste -> Bildschirm -> Bild', (tester) async {
    await tester.pumpWidget(const RosenwegVm());
    await tester.pumpAndSettle();
    expect(find.text('Meine Computer'), findsOneWidget);

    await tester.tap(find.text('Testcomputer (lokal)'));
    // Echtzeit: der Server malt, die C-Schicht kopiert, das Widget holt ab.
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 100));
      if (find.byType(RawImage).evaluate().isNotEmpty) break;
    }
    expect(find.text('Bildschirm wird geoeffnet …'), findsNothing);
    expect(find.text('Neu verbinden'), findsNothing);
    final roh = tester.widget<RawImage>(find.byType(RawImage));
    expect(roh.image, isNotNull);
    expect(roh.image!.width, greaterThan(0));

    // Eingaben durch die ganze Kette (Gast antwortet im Testserver nicht sichtbar).
    await tester.tapAt(tester.getCenter(find.byType(RawImage)));
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  });
}
