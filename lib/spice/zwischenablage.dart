// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

/// Gleicht die Zwischenablage (Text) zwischen Geraet und Gast ab.
///
/// Gast → Geraet: kommt Text vom Gast (spice-vdagent), landet er in der
/// Zwischenablage des Geraets. Geraet → Gast: die App sieht nach, ob auf dem
/// Geraet neuer Text liegt (beim Verbinden, wenn die App wieder nach vorn
/// kommt, am Rechner alle zwei Sekunden), und bietet ihn dem Gast an. Auf
/// dem Handy wird nicht laufend gelesen: Android und iOS melden jedes Lesen.
class ZwischenablageAbgleich {
  ZwischenablageAbgleich({
    required this.anGast,
    Future<String?> Function()? lesen,
    Future<void> Function(String text)? schreiben,
  })  : _lesen = lesen ?? _systemLesen,
        _schreiben = schreiben ?? _systemSchreiben;

  /// Text dem Gast anbieten (rw_spice_zwischenablage_setzen).
  final void Function(String text) anGast;
  final Future<String?> Function() _lesen;
  final Future<void> Function(String text) _schreiben;

  bool an = true;

  /// Zuletzt abgeglichen (egal in welche Richtung): nicht im Kreis schicken.
  String? _zuletzt;

  static Future<String?> _systemLesen() async => (await Clipboard.getData(Clipboard.kTextPlain))?.text;
  static Future<void> _systemSchreiben(String t) => Clipboard.setData(ClipboardData(text: t));

  /// Neuer Text auf dem Geraet? Dann dem Gast anbieten.
  Future<void> geraetPruefen() async {
    if (!an) return;
    String? t;
    try {
      t = await _lesen();
    } catch (_) {
      return;
    }
    if (t == null || t.isEmpty || t == _zuletzt) return;
    _zuletzt = t;
    anGast(t);
  }

  /// Der Gast hat Text kopiert.
  Future<void> gastHat(String text) async {
    if (!an || text.isEmpty) return;
    final t = text.replaceAll('\r\n', '\n');
    if (t == _zuletzt) return;
    _zuletzt = t;
    await _schreiben(t);
  }

  /// Neue Sitzung: was der Gast hat, ist unbekannt.
  void vergessen() => _zuletzt = null;
}
