// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../protokoll.dart';

/// Alles, was die App sicher speichert, in EINEM Eintrag (JSON):
/// Refresh-Token, Zeitpunkt der Browser-Anmeldung, Geraete-Kennung.
///
/// Warum einer: Auf macOS fragt der Schluesselbund bei einer unsignierten
/// (Entwicklungs-)App pro Eintrag nach Erlaubnis. Mit drei Eintraegen waren es
/// drei Fragen bei jedem Start eines neuen Baus.
///
/// Fruehere Fassungen hatten je Wert einen eigenen Eintrag; die werden beim
/// ersten Lesen uebernommen und geloescht.
class Schluesselbund {
  Schluesselbund([FlutterSecureStorage? speicher])
      : _speicher = speicher ??
            const FlutterSecureStorage(
              // Ohne den Data-Protection-Schluesselbund: der braucht eine
              // signierte App mit Team-ID, was im Entwicklungsbau fehlt.
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            );

  /// Eine Instanz fuer die ganze App (ein Eintrag, ein Zwischenspeicher).
  static final Schluesselbund i = Schluesselbund();

  static const eintrag = 'rosenweg_vm';
  static const alteEintraege = {
    'refresh_token': 'rosenweg_refresh_token',
    'angemeldet_am': 'rosenweg_angemeldet_am',
    'geraet': 'rosenweg_geraet',
  };

  final FlutterSecureStorage _speicher;
  Map<String, String>? _werte;
  Future<Map<String, String>>? _laden;

  /// true, sobald der Schluesselbund des Systems versagt hat. Dann lebt alles
  /// nur noch im Speicher der App, bis sie endet.
  ///
  /// Linux: libsecret braucht einen Secret-Service-Dienst (gnome-keyring,
  /// KeePassXC) in der Sitzung. Auf den Rosenweg-Stationen laeuft keiner
  /// (desktop-test, 26.11.2026). Ohne diesen Rueckfall scheiterte dort schon
  /// das erste Lesen — und mit ihm Anmeldung und Geraete-Kennung. So geht es
  /// weiter, nur ohne Erinnerung ueber das Programmende hinaus; die stille
  /// Anmeldung ueber die Browser-Sitzung (30 Tage) bleibt davon unberuehrt.
  bool get nurImSpeicher => _nurImSpeicher;
  bool _nurImSpeicher = false;

  void _versagt(Object e) {
    if (!_nurImSpeicher) {
      Protokoll.schreiben('Schluesselbund des Systems nicht nutzbar, Werte nur bis Programmende', e);
    }
    _nurImSpeicher = true;
  }

  Future<Map<String, String>> _alle() => _laden ??= _ladenOderLeer();

  Future<Map<String, String>> _ladenOderLeer() async {
    try {
      return await _ladenUndUebernehmen();
    } catch (e) {
      _versagt(e);
      return _werte ??= <String, String>{};
    }
  }

  Future<Map<String, String>> _ladenUndUebernehmen() async {
    final roh = await _speicher.read(key: eintrag);
    final werte = <String, String>{};
    if (roh != null) {
      try {
        (jsonDecode(roh) as Map<String, dynamic>).forEach((k, v) {
          if (v is String) werte[k] = v;
        });
      } catch (e) {
        Protokoll.schreiben('Schluesselbund-Eintrag unlesbar, wird neu angelegt', e);
      }
    }
    // Uebernahme der alten Einzel-Eintraege (einmalig).
    var uebernommen = false;
    for (final MapEntry(key: neu, value: alt) in alteEintraege.entries) {
      final v = await _speicher.read(key: alt);
      if (v == null) continue;
      werte.putIfAbsent(neu, () => v);
      uebernommen = true;
    }
    _werte = werte;
    if (uebernommen) {
      await _schreiben();
      for (final alt in alteEintraege.values) {
        await _speicher.delete(key: alt);
      }
      Protokoll.schreiben('Schluesselbund: alte Einzel-Eintraege in einen zusammengefuehrt');
    }
    return werte;
  }

  Future<void> _schreiben() async {
    if (_nurImSpeicher) return;
    final w = _werte ?? const {};
    try {
      if (w.isEmpty) {
        await _speicher.delete(key: eintrag);
      } else {
        await _speicher.write(key: eintrag, value: jsonEncode(w));
      }
    } catch (e) {
      _versagt(e);
    }
  }

  Future<String?> lesen(String schluessel) async => (await _alle())[schluessel];

  /// Mehrere Werte auf einmal setzen (null = entfernen); ein Schreibvorgang.
  Future<void> setzen(Map<String, String?> neu) async {
    final w = await _alle();
    neu.forEach((k, v) => v == null ? w.remove(k) : w[k] = v);
    await _schreiben();
  }
}
