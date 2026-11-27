// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../protokoll.dart';
import '../vm_app.dart';

/// Wie ein Finger auf dem Bild wirkt.
enum TouchModus {
  /// Vorgabe: Tippen klickt genau dort, wo der Finger ist.
  direkt,

  /// Wie ein Touchpad: der Finger schiebt einen Mauszeiger, Tippen klickt
  /// dort, wo der Zeiger steht. Fuer kleine Bedienelemente.
  touchpad,
}

/// Einstellungen der Bedienung (Beruehrung, Hilfe); im selben
/// Schluesselbund-Eintrag wie die Anmeldung, wie [TastaturEinstellung].
class BedienEinstellung extends ChangeNotifier {
  BedienEinstellung._();
  static final BedienEinstellung i = BedienEinstellung._();

  TouchModus touch = TouchModus.direkt;

  /// Aufloesung des Gasts an Bildschirm bzw. Fenster anpassen (braucht im
  /// Gast den spice-vdagent; ohne ihn wird das Bild nur eingepasst).
  bool aufloesungAnpassen = true;

  /// Kurze Hilfe zu den Gesten schon gezeigt?
  bool hilfeGesehen = false;

  bool _geladen = false;

  Future<void> laden() async {
    if (_geladen) return;
    _geladen = true;
    try {
      final roh = await vmSpeicher.lesen('bedienung');
      if (roh == null) return;
      final j = jsonDecode(roh) as Map<String, dynamic>;
      touch = j['touch'] == 'touchpad' ? TouchModus.touchpad : TouchModus.direkt;
      hilfeGesehen = (j['hilfe'] as bool?) ?? false;
      aufloesungAnpassen = (j['aufloesung'] as bool?) ?? true;
      notifyListeners();
    } catch (e) {
      Protokoll.schreiben('Bedien-Einstellung unlesbar, Vorgaben', e);
    }
  }

  Future<void> setzen({TouchModus? touch, bool? hilfeGesehen, bool? aufloesungAnpassen}) async {
    this.touch = touch ?? this.touch;
    this.aufloesungAnpassen = aufloesungAnpassen ?? this.aufloesungAnpassen;
    this.hilfeGesehen = hilfeGesehen ?? this.hilfeGesehen;
    notifyListeners();
    Protokoll.schreiben('Bedienung: Touch ${this.touch.name}, Aufloesung anpassen ${this.aufloesungAnpassen}');
    try {
      await vmSpeicher.setzen({'bedienung': jsonEncode(_json())});
    } catch (e) {
      Protokoll.schreiben('Bedien-Einstellung nicht gespeichert', e);
    }
  }

  Map<String, Object> _json() => {'touch': touch.name, 'hilfe': hilfeGesehen, 'aufloesung': aufloesungAnpassen};

  /// Nur fuer Tests: Werte setzen, ohne Schluesselbund.
  @visibleForTesting
  void zuruecksetzen({TouchModus touch = TouchModus.direkt, bool aufloesungAnpassen = true}) {
    this.touch = touch;
    this.aufloesungAnpassen = aufloesungAnpassen;
    hilfeGesehen = false;
    _geladen = true;
    notifyListeners();
  }
}
