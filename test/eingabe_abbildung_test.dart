// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/spice/belegungen.dart';
import 'package:rosenweg_vm/spice/bildschirm_tastatur.dart';
import 'package:rosenweg_vm/spice/scancodes.dart';
import 'package:rosenweg_vm/spice/tastatur.dart';

/// Taste ohne Scancode, wie sie `adb shell input keyevent` oder eine
/// Bildschirmtastatur auf Android liefert: physicalKey ausserhalb der
/// HID-Seite 0x07 (Android-Ebene von Flutter), nur die logische Taste stimmt.
KeyDownEvent ohneScancode(LogicalKeyboardKey k, {String? zeichen}) => KeyDownEvent(
      physicalKey: const PhysicalKeyboardKey(0x1100000043),
      logicalKey: k,
      character: zeichen,
      timeStamp: Duration.zero,
    );

void main() {
  group('Tasten ohne Scancode', () {
    test('Rueckschritt, Enter, Pfeile, Entf, F-Tasten ueber die logische Taste', () {
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.backspace)), 0x0e);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.enter)), 0x1c);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.arrowLeft)), 0x14b);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.arrowUp)), 0x148);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.delete)), 0x153);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.f12)), 0x58);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.escape)), 0x01);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.controlLeft)), 0x1d);
    });

    test('vorher verworfen, jetzt Steuertaste bzw. Umschalter', () {
      final r = ohneScancode(LogicalKeyboardKey.backspace);
      // Der alte Weg kannte nur die physische Taste:
      expect(scancode(r.physicalKey), isNull);
      expect(istSteuertaste(r.physicalKey), isFalse);
      // Der neue nimmt die logische dazu:
      expect(istSteuertasteEreignis(r), isTrue);
      expect(istUmschalterEreignis(ohneScancode(LogicalKeyboardKey.controlLeft)), isTrue);
      expect(istSteuertasteEreignis(ohneScancode(LogicalKeyboardKey.keyA, zeichen: 'a')), isFalse);
    });

    test('mit Scancode zaehlt weiter die physische Taste', () {
      const e = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyZ,
        logicalKey: LogicalKeyboardKey.keyY, // CH: Z-Taste traegt Y nicht, egal
        timeStamp: Duration.zero,
      );
      expect(tastenScancode(e), 0x2c);
      expect(tastenScancode(ohneScancode(LogicalKeyboardKey.metaLeft), cmdAlsStrg: true), 0x1d);
    });
  });

  group('Bildschirmtastatur', () {
    test('Textaenderung: Tippen, Rueckschritt, Komposition', () {
      expect(textAenderung(imePlatzhalter, '${imePlatzhalter}a'), (zurueck: 0, neu: 'a'));
      expect(textAenderung('${imePlatzhalter}ab', '${imePlatzhalter}a'), (zurueck: 1, neu: ''));
      // Tottaste: erst ´, dann ersetzt die Tastatur es durch é
      expect(textAenderung('$imePlatzhalter´', '$imePlatzhalteré'), (zurueck: 1, neu: 'é'));
      // Autokorrektur ersetzt ein ganzes Wort
      expect(textAenderung('${imePlatzhalter}teh', '${imePlatzhalter}the '), (zurueck: 2, neu: 'he '));
      // Emoji (zwei UTF-16-Einheiten) zaehlt als ein Zeichen
      expect(textAenderung('$imePlatzhalter😀', imePlatzhalter), (zurueck: 1, neu: ''));
    });

    test('Zeichen in der Belegung des Gasts, Enter und Tab als Tasten', () {
      final ch = belegungFinden('ch'), de = belegungFinden('de');
      List<int> runter(List<Taste>? f) => [for (final t in f!) if (t.druck) t.sc];
      expect(runter(zeichenTasten(ch, 'ä'.runes.first)), [0x28]); // CH: ä rechts neben ö
      expect(runter(zeichenTasten(de, 'ä'.runes.first)), [0x28]);
      expect(runter(zeichenTasten(ch, 'z'.runes.first)), [0x15]); // CH: Z rechts von T
      expect(runter(zeichenTasten(de, '@'.runes.first)), [scAltGr, 0x10]); // DE: AltGr+Q
      expect(runter(zeichenTasten(ch, 0x0a)), [0x1c]);
      expect(runter(zeichenTasten(ch, 0x09)), [0x0f]);
      expect(zeichenTasten(belegungFinden('us'), 'ä'.runes.first), isNull);
    });

    test('mit Umschaltern aus der Leiste: Grundtaste der Gastbelegung', () {
      final ch = belegungFinden('ch');
      // Strg + z (CH): Strg runter, Z-Taste (0x15), los, Strg los
      expect(zeichenTasten(ch, 'z'.runes.first, umschalter: [scStrg]), [
        (sc: scStrg, druck: true),
        (sc: 0x15, druck: true),
        (sc: 0x15, druck: false),
        (sc: scStrg, druck: false),
      ]);
      // Grossbuchstabe von der Bildschirmtastatur: dieselbe Taste
      expect(zeichenTasten(ch, 'C'.runes.first, umschalter: [scStrg])!.map((t) => t.sc), [scStrg, 0x2e, 0x2e, scStrg]);
    });
  });
}
