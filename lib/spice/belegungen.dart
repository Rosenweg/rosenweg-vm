// SPDX-License-Identifier: GPL-3.0-or-later
/// Tastaturbelegungen des GASTES (wie er Scancodes in Zeichen uebersetzt).
///
/// Die Tabellen kommen aus xkeyboard-config (tool/belegungen_erzeugen.py),
/// gelten aber auch fuer Windows-Gaeste: die Scancodes sind dieselben, die
/// Belegungen im Schreibblock praktisch gleich (Abweichungen nur bei
/// seltenen AltGr-Zeichen).
library;

part 'belegungen.g.dart';

class GastBelegung {
  const GastBelegung(this.kennung, this.name, this.folgen);

  /// xkb-Name, z. B. "ch" oder "de(nodeadkeys)".
  final String kennung;
  final String name;

  /// Unicode-Zeichen -> Schritte (Scancode | Stufe << 9).
  final Map<int, List<int>> folgen;
}

/// Alle Belegungen; die erste (Schweiz, Deutsch) ist die Vorgabe.
const List<GastBelegung> alleBelegungen = _erzeugt;

GastBelegung belegungFinden(String kennung) =>
    alleBelegungen.firstWhere((b) => b.kennung == kennung, orElse: () => alleBelegungen.first);
