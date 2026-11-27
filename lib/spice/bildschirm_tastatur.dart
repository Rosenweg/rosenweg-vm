// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

import 'belegungen.dart';
import 'tastatur.dart';

/// Umschalter der Sondertasten-Leiste. Ein Druck haelt sie fuer den NAECHSTEN
/// Tastendruck (Leiste, Bildschirmtastatur oder echte Tastatur); danach
/// lassen sie von selbst los. So geht Strg+C auch ohne Strg-Taste.
enum Umschalter {
  strg('Strg', scStrg),
  alt('Alt', scAlt),
  altGr('AltGr', scAltGr),
  win('Win', scSuper),
  shift('⇧', scShift);

  const Umschalter(this.anzeige, this.sc);
  final String anzeige;
  final int sc;
}

/// Text im versteckten Eingabefeld der Bildschirmtastatur. Nie leer, damit
/// Rueckschritt immer etwas zu loeschen hat (manche Tastaturen schicken bei
/// leerem Feld gar nichts). Unsichtbare Zeichen: keine Tastatur korrigiert sie
/// oder macht aus zwei Leerzeichen einen Punkt.
const imePlatzhalter = '​​​​​​​​';

/// Was sich im versteckten Feld geaendert hat, als "so viele Zeichen
/// zuruecknehmen, dann diesen Text tippen". Die Schreibmarke steht immer am
/// Ende; Aenderungen (Tippen, Rueckschritt, Autokorrektur, Komposition
/// "´"+"e" → "é") passieren also hinten.
({int zurueck, String neu}) textAenderung(String alt, String neu) {
  final a = alt.runes.toList(), b = neu.runes.toList();
  var p = 0;
  while (p < a.length && p < b.length && a[p] == b[p]) {
    p++;
  }
  return (zurueck: a.length - p, neu: String.fromCharCodes(b.sublist(p)));
}

/// Scancodes fuer Zeichen, die keine Taste der Belegung sind, sondern eine
/// Steuertaste: Zeilenumbruch → Enter, Tab → Tab.
const _steuerZeichen = {0x0a: 0x1c, 0x0d: 0x1c, 0x09: 0x0f};

/// Tastenfolge fuer ein Zeichen von der Bildschirmtastatur.
///
/// Ohne gehaltene Umschalter: wie getippt, in der Belegung des Gasts
/// ([zeichenFolge]). Mit Umschaltern aus der Leiste (Strg, Alt …): die Taste,
/// die in der Gastbelegung dieses Zeichen ohne Umschalter ergibt, mit den
/// Umschaltern drumherum (Strg + c → Strg+C, egal wo C im Gast liegt).
/// null: Zeichen gibt es in dieser Belegung nicht.
List<Taste>? zeichenTasten(GastBelegung b, int zeichen, {List<int> umschalter = const []}) {
  final steuer = _steuerZeichen[zeichen];
  if (umschalter.isEmpty) {
    if (steuer != null) return [(sc: steuer, druck: true), (sc: steuer, druck: false)];
    return zeichenFolge(b, zeichen);
  }
  var sc = steuer ?? grundTaste(b, zeichen);
  if (sc == null) {
    final klein = String.fromCharCode(zeichen).toLowerCase().runes.first;
    sc = grundTaste(b, klein);
  }
  if (sc == null) return null;
  return [
    for (final m in umschalter) (sc: m, druck: true),
    (sc: sc, druck: true),
    (sc: sc, druck: false),
    for (final m in umschalter.reversed) (sc: m, druck: false),
  ];
}

/// Eine Taste der Sondertasten-Leiste.
class Sondertaste {
  const Sondertaste(this.name, this.sc, {this.hilfe});
  final String name;
  final int sc;
  final String? hilfe;
}

const sondertasten = <Sondertaste>[
  Sondertaste('Esc', 0x01),
  Sondertaste('Tab', 0x0f),
  Sondertaste('←', 0x14b, hilfe: 'Pfeil links'),
  Sondertaste('↑', 0x148, hilfe: 'Pfeil hoch'),
  Sondertaste('↓', 0x150, hilfe: 'Pfeil runter'),
  Sondertaste('→', 0x14d, hilfe: 'Pfeil rechts'),
  Sondertaste('Pos1', 0x147),
  Sondertaste('Ende', 0x14f),
  Sondertaste('Bild↑', 0x149, hilfe: 'Bild auf'),
  Sondertaste('Bild↓', 0x151, hilfe: 'Bild ab'),
  Sondertaste('⌫', 0x0e, hilfe: 'Rückschritt'),
  Sondertaste('Entf', 0x153),
];

const fTasten = <Sondertaste>[
  Sondertaste('F1', 0x3b),
  Sondertaste('F2', 0x3c),
  Sondertaste('F3', 0x3d),
  Sondertaste('F4', 0x3e),
  Sondertaste('F5', 0x3f),
  Sondertaste('F6', 0x40),
  Sondertaste('F7', 0x41),
  Sondertaste('F8', 0x42),
  Sondertaste('F9', 0x43),
  Sondertaste('F10', 0x44),
  Sondertaste('F11', 0x57),
  Sondertaste('F12', 0x58),
];

/// Konfiguration des versteckten Eingabefelds: keine Vorschlaege, keine
/// Autokorrektur, kein Lernen, Enter = Zeilenumbruch (geht als Enter).
TextInputConfiguration imeKonfiguration({int? viewId}) => TextInputConfiguration(
  viewId: viewId,
  inputType: TextInputType.multiline,
  inputAction: TextInputAction.newline,
  autocorrect: false,
  enableSuggestions: false,
  enableIMEPersonalizedLearning: false,
  smartDashesType: SmartDashesType.disabled,
  smartQuotesType: SmartQuotesType.disabled,
  textCapitalization: TextCapitalization.none,
  keyboardAppearance: Brightness.dark,
);
