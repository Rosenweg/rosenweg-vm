// SPDX-License-Identifier: GPL-3.0-or-later
import 'belegungen.dart';

/// PC-Scancodes (Satz 1) der Umschalter, wie sie an SPICE gehen.
const scShift = 0x2a, scAltGr = 0x138, scStrg = 0x1d, scAlt = 0x38, scSuper = 0x15b;

/// Ein Tastendruck an den Gast: Scancode und gedrueckt/losgelassen.
typedef Taste = ({int sc, bool druck});

/// Tastenfolge, die in der Gastbelegung [b] das Zeichen [zeichen] (ein
/// Unicode-Codepunkt) ergibt — mit Shift/AltGr und ggf. Tottaste davor.
/// null: in dieser Belegung nicht erreichbar.
List<Taste>? zeichenFolge(GastBelegung b, int zeichen) {
  final schritte = b.folgen[zeichen];
  if (schritte == null) return null;
  final aus = <Taste>[];
  for (final s in schritte) {
    final sc = s & 0x1ff, stufe = s >> 9;
    final altgr = stufe & 2 != 0, shift = stufe & 1 != 0;
    if (altgr) aus.add((sc: scAltGr, druck: true));
    if (shift) aus.add((sc: scShift, druck: true));
    aus
      ..add((sc: sc, druck: true))
      ..add((sc: sc, druck: false));
    if (shift) aus.add((sc: scShift, druck: false));
    if (altgr) aus.add((sc: scAltGr, druck: false));
  }
  return aus;
}

/// Ganzer Text (fuer Tests und spaeter "Text einfuegen"). Nicht erreichbare
/// Zeichen landen in [fehlend].
List<Taste> textFolge(GastBelegung b, String text, {Set<String>? fehlend}) {
  final aus = <Taste>[];
  for (final r in text.runes) {
    final f = zeichenFolge(b, r);
    if (f == null) {
      fehlend?.add(String.fromCharCode(r));
    } else {
      aus.addAll(f);
    }
  }
  return aus;
}

/// Scancode der Taste, die in [b] ohne Umschalter [zeichen] ergibt (fuer
/// Kurzbefehle wie Strg+Z: Z liegt je nach Belegung woanders).
int? grundTaste(GastBelegung b, int zeichen) {
  final s = b.folgen[zeichen];
  if (s == null || s.length != 1 || s.first >> 9 != 0) return null;
  return s.first & 0x1ff;
}

/// Ist das ein druckbares Zeichen (kein Steuerzeichen, keine Funktions-
/// taste von macOS im privaten Bereich U+F700–U+F8FF)?
bool druckbar(String? c) {
  if (c == null || c.isEmpty) return false;
  final r = c.runes.toList();
  if (r.length != 1) return false;
  final z = r.first;
  return z >= 0x20 && z != 0x7f && !(z >= 0xf700 && z <= 0xf8ff) && !(z >= 0x80 && z < 0xa0);
}
