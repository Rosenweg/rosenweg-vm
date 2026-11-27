// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show Protokoll;

/// Speicher fuer den Schluesselbund der Basis, der unter Linux zuerst den
/// Secret Service fragt (aus 1.1.x, #28 – die Basis kann das noch nicht).
///
/// Ist kein Schluesselbund da, in den libsecret ohne Rueckfrage schreiben
/// kann, scheitert schon das erste Lesen mit einem Fehler, OHNE libsecret
/// anzufassen. Der Schluesselbund der Basis faellt dann auf "nur im
/// Speicher" zurueck (`nurImSpeicher`) – und libsecret oeffnet kein Fenster
/// "Neuen Schluesselbund anlegen".
///
/// Gehoert eigentlich in rosenweg_basis (Schluesselbund); dort nachziehen
/// und dann hier entfernen.
class PruefenderSpeicher extends FlutterSecureStorage {
  PruefenderSpeicher({FlutterSecureStorage? innen, Future<bool> Function()? bereit})
      : _innen = innen ??
            const FlutterSecureStorage(
              mOptions: MacOsOptions(usesDataProtectionKeychain: false),
            ),
        _bereitFn = bereit ?? linuxBereit;

  final FlutterSecureStorage _innen;
  final Future<bool> Function() _bereitFn;
  Future<bool>? _bereit;

  Future<void> _pruefen() async {
    if (!await (_bereit ??= _bereitFn())) {
      throw StateError('kein Schluesselbund, in den ohne Rueckfrage geschrieben werden kann');
    }
  }

  @override
  Future<String?> read({required String key, AppleOptions? iOptions, AndroidOptions? aOptions,
      LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    await _pruefen();
    return _innen.read(key: key);
  }

  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    await _pruefen();
    return _innen.write(key: key, value: value);
  }

  @override
  Future<void> delete({required String key, AppleOptions? iOptions, AndroidOptions? aOptions,
      LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    await _pruefen();
    return _innen.delete(key: key);
  }

  /// Linux: gibt es einen Schluesselbund, den libsecret ohne Rueckfrage
  /// benutzen kann? Gefragt wird der Secret Service selbst (ReadAlias
  /// "default", Standard-API, egal ob gnome-keyring oder KeePassXC).
  ///
  /// - kein Dienst: libsecret scheiterte ohnehin (so bisher auf den Stationen).
  /// - Dienst, aber keine Standard-Sammlung ("/"): libsecret wuerde beim
  ///   ersten Speichern ein Fenster "Neuen Schluesselbund anlegen" oeffnen und
  ///   nach einem Passwort fragen. Auf den Stationen ist das genau der Fall,
  ///   wenn der Anmelde-Schluesselbund nach einem Passwortwechsel im AD
  ///   beiseitegelegt wurde (os-stationen, schluesselbund-pruefen.sh); bei
  ///   der naechsten Anmeldung ist er wieder da. Bis dahin lieber nichts
  ///   merken als fragen.
  /// - busctl fehlt oder antwortet nicht: libsecret selbst entscheiden lassen.
  static Future<bool> linuxBereit() async {
    try {
      final r = await Process.run('busctl', [
        '--user', 'call', 'org.freedesktop.secrets', '/org/freedesktop/secrets',
        'org.freedesktop.Secret.Service', 'ReadAlias', 's', 'default',
      ]).timeout(const Duration(seconds: 5));
      if (r.exitCode != 0) {
        Protokoll.schreiben('Secret Service antwortet nicht: ${'${r.stderr}'.trim()}');
        return false;
      }
      return !'${r.stdout}'.trim().endsWith('"/"');
    } on ProcessException {
      return true;
    } on TimeoutException {
      return true;
    }
  }
}
