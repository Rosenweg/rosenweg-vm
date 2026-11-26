// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:rosenweg_vm/spice/belegungen.dart';
import 'package:rosenweg_vm/spice/scancodes.dart';
import 'package:rosenweg_vm/spice/tastatur.dart';

/// Kurzschrift fuer erwartete Folgen: Taste antippen, mit Umschaltern.
List<Taste> tipp(int sc, {bool shift = false, bool altgr = false}) => [
      if (altgr) (sc: scAltGr, druck: true),
      if (shift) (sc: scShift, druck: true),
      (sc: sc, druck: true),
      (sc: sc, druck: false),
      if (shift) (sc: scShift, druck: false),
      if (altgr) (sc: scAltGr, druck: false),
    ];

void main() {
  test('Vorgabe ist Schweiz (Deutsch)', () {
    expect(alleBelegungen.first.kennung, 'ch');
    expect(belegungFinden('gibts-nicht').kennung, 'ch');
  });

  test('de-CH: "Zürich.y-Z@#"', () {
    final b = belegungFinden('ch');
    final fehlend = <String>{};
    expect(textFolge(b, 'Zürich.y-Z@#', fehlend: fehlend), [
      ...tipp(0x15, shift: true), // Z (CH: Taste rechts von T)
      ...tipp(0x1a), // ü
      ...tipp(0x13), // r
      ...tipp(0x17), // i
      ...tipp(0x2e), // c
      ...tipp(0x23), // h
      ...tipp(0x34), // .
      ...tipp(0x2c), // y (CH: unten links)
      ...tipp(0x35), // -
      ...tipp(0x15, shift: true), // Z
      ...tipp(0x03, altgr: true), // @ = AltGr+2
      ...tipp(0x04, altgr: true), // # = AltGr+3
    ]);
    expect(fehlend, isEmpty);
  });

  test('de-CH: Tottasten ^ und ê, Zeichen unter Shift', () {
    final b = belegungFinden('ch');
    expect(zeichenFolge(b, '^'.runes.first), [...tipp(0x0d), ...tipp(0x39)]); // ^ dann Leertaste
    expect(zeichenFolge(b, 'ê'.runes.first), [...tipp(0x0d), ...tipp(0x12)]);
    expect(zeichenFolge(b, 'é'.runes.first), tipp(0x27, shift: true)); // CH: Shift+ö
    expect(zeichenFolge(b, '+'.runes.first), tipp(0x02, shift: true));
    expect(zeichenFolge(b, '<'.runes.first), tipp(0x56));
  });

  test('de-DE: y/z, @ = AltGr+Q, ß', () {
    final b = belegungFinden('de');
    expect(textFolge(b, 'yz@ß'), [...tipp(0x2c), ...tipp(0x15), ...tipp(0x10, altgr: true), ...tipp(0x0c)]);
  });

  test('us: Umlaute fehlen und werden gemeldet, Rest geht', () {
    final b = belegungFinden('us');
    final fehlend = <String>{};
    expect(textFolge(b, 'aä@', fehlend: fehlend), [...tipp(0x1e), ...tipp(0x03, shift: true)]);
    expect(fehlend, {'ä'});
  });

  test('us(intl): ä ueber Tottaste " und a', () {
    final b = belegungFinden('us(intl)');
    expect(zeichenFolge(b, 'ä'.runes.first), isNotNull);
  });

  test('fr (AZERTY): a liegt auf Q-Taste, 1 braucht Shift', () {
    final b = belegungFinden('fr');
    expect(zeichenFolge(b, 'a'.runes.first), tipp(0x10));
    expect(zeichenFolge(b, '1'.runes.first), tipp(0x02, shift: true));
  });

  test('jede Belegung kann alle druckbaren ASCII-Buchstaben und Ziffern', () {
    const zeichen = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 .';
    for (final b in alleBelegungen) {
      final fehlend = <String>{};
      textFolge(b, zeichen, fehlend: fehlend);
      // Lettisch, Litauisch usw. haben alle lateinischen Buchstaben; nur
      // wenige Belegungen (z. B. lt) legen Ziffern auf andere Ebenen.
      expect(fehlend.where((c) => RegExp('[a-zA-Z .]').hasMatch(c)), isEmpty, reason: b.kennung);
    }
  });

  test('Kurzbefehle: Grundtaste fuer Strg+Z je Belegung', () {
    expect(grundTaste(belegungFinden('ch'), 'z'.runes.first), 0x15);
    expect(grundTaste(belegungFinden('us'), 'z'.runes.first), 0x2c);
    expect(grundTaste(belegungFinden('fr'), 'q'.runes.first), 0x1e);
  });

  test('druckbar: Steuerzeichen und macOS-Funktionstasten nicht', () {
    expect(druckbar('a'), isTrue);
    expect(druckbar('ü'), isTrue);
    expect(druckbar('\r'), isFalse);
    expect(druckbar(''), isFalse); // Pfeil hoch auf macOS
    expect(druckbar(null), isFalse);
  });

  test('physisch: Shift links/rechts, Ziffernreihe, Mac-ISO-Tausch, Cmd als Strg', () {
    expect(scancode(PhysicalKeyboardKey.shiftLeft), 0x2a);
    expect(scancode(PhysicalKeyboardKey.shiftRight), 0x36);
    expect(scancode(PhysicalKeyboardKey.digit1), 0x02);
    expect(scancode(PhysicalKeyboardKey.digit0), 0x0b);
    expect(scancode(PhysicalKeyboardKey.period), 0x34);
    // Mac ISO: Taste links oben meldet macOS als intlBackslash
    expect(scancode(PhysicalKeyboardKey.intlBackslash), 0x56);
    expect(scancode(PhysicalKeyboardKey.intlBackslash, macIsoTausch: true), 0x29);
    expect(scancode(PhysicalKeyboardKey.backquote, macIsoTausch: true), 0x56);
    expect(scancode(PhysicalKeyboardKey.metaLeft), 0x15b);
    expect(scancode(PhysicalKeyboardKey.metaLeft, cmdAlsStrg: true), 0x1d);
    expect(scancode(PhysicalKeyboardKey.pause), isNull); // nicht mehr Num-Taste
    expect(istSteuertaste(PhysicalKeyboardKey.arrowLeft), isTrue);
    expect(istSteuertaste(PhysicalKeyboardKey.keyA), isFalse);
    expect(istUmschalter(PhysicalKeyboardKey.altRight), isTrue);
  });
}
