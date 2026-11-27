// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../vm_app.dart';
import '../protokoll.dart';
import 'belegungen.dart';

/// Wie Tastendruecke zum Gast gehen.
enum TastaturModus {
  /// Vorgabe: druckbare Zeichen werden aus dem GETIPPTEN Zeichen in die
  /// Tastenfolge der Gastbelegung uebersetzt. Geht mit jeder Tastatur am
  /// Geraet (Mac/PC, CH/DE/FR/US …, Tottasten, Umlaute).
  zeichen,

  /// Physische Taste 1:1 (wie eine echte PC-Tastatur am Gast). Nur richtig,
  /// wenn Geraet und Gast dieselbe Belegung haben.
  direkt,
}

/// Einstellungen der Tastatur; gespeichert im selben Schluesselbund-Eintrag
/// wie die Anmeldung (kein zweiter Eintrag, keine zweite Rueckfrage).
class TastaturEinstellung extends ChangeNotifier {
  TastaturEinstellung._();
  static final TastaturEinstellung i = TastaturEinstellung._();

  TastaturModus modus = TastaturModus.zeichen;
  GastBelegung belegung = alleBelegungen.first;

  /// macOS: Cmd wie Strg senden (Cmd+C → Strg+C im Gast).
  bool cmdAlsStrg = Platform.isMacOS;

  /// macOS mit ISO-Tastatur (CH/DE …): macOS meldet die Taste links oben (§)
  /// und die neben der linken Umschalttaste (<) vertauscht. Nur im Modus
  /// "direkt" von Bedeutung.
  bool macIsoTausch = Platform.isMacOS;

  bool _geladen = false;

  Future<void> laden() async {
    if (_geladen) return;
    _geladen = true;
    try {
      final roh = await vmSpeicher.lesen('tastatur');
      if (roh == null) return;
      final j = jsonDecode(roh) as Map<String, dynamic>;
      modus = j['modus'] == 'direkt' ? TastaturModus.direkt : TastaturModus.zeichen;
      belegung = belegungFinden((j['belegung'] as String?) ?? 'ch');
      cmdAlsStrg = (j['cmd_als_strg'] as bool?) ?? cmdAlsStrg;
      macIsoTausch = (j['mac_iso'] as bool?) ?? macIsoTausch;
      notifyListeners();
    } catch (e) {
      Protokoll.schreiben('Tastatur-Einstellung unlesbar, Vorgaben', e);
    }
  }

  Future<void> setzen({TastaturModus? modus, GastBelegung? belegung, bool? cmdAlsStrg, bool? macIsoTausch}) async {
    this.modus = modus ?? this.modus;
    this.belegung = belegung ?? this.belegung;
    this.cmdAlsStrg = cmdAlsStrg ?? this.cmdAlsStrg;
    this.macIsoTausch = macIsoTausch ?? this.macIsoTausch;
    notifyListeners();
    Protokoll.schreiben('Tastatur: ${this.modus.name}, Gast ${this.belegung.kennung}, '
        'Cmd als Strg ${this.cmdAlsStrg}, Mac-ISO ${this.macIsoTausch}');
    await vmSpeicher.setzen({
      'tastatur': jsonEncode({
        'modus': this.modus.name,
        'belegung': this.belegung.kennung,
        'cmd_als_strg': this.cmdAlsStrg,
        'mac_iso': this.macIsoTausch,
      }),
    });
  }
}
