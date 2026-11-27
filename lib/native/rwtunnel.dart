// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import 'bibliothek.dart';

/// Bindung an librwtunnel (wireguard-go mit Netzstapel im Prozess).
/// Alle Antworten sind JSON; siehe native/rwtunnel/capi/main.go.
class RwTunnel {
  RwTunnel._(DynamicLibrary lib)
    : _paar = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rwt_schluesselpaar'),
      _start = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
        'rwt_start',
      ),
      _zustand = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rwt_zustand'),
      _weiter = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
        'rwt_weiterleitung',
      ),
      _endpunkt = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
        'rwt_endpunkt',
      ),
      _stop = lib.lookupFunction<Void Function(), void Function()>('rwt_stop'),
      _frei = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('rwt_frei'),
      _absturz = lib.lookupFunction<Pointer<Utf8> Function(Pointer<Utf8>), Pointer<Utf8> Function(Pointer<Utf8>)>(
        'rwt_absturzdatei',
      );

  static RwTunnel? _inst;
  static RwTunnel get i => _inst ??= RwTunnel._(bibliothekLaden('rwtunnel'));

  final Pointer<Utf8> Function() _paar;
  final Pointer<Utf8> Function(Pointer<Utf8>) _start;
  final Pointer<Utf8> Function() _zustand;
  final Pointer<Utf8> Function(Pointer<Utf8>) _weiter;
  final Pointer<Utf8> Function(Pointer<Utf8>) _endpunkt;
  final void Function() _stop;
  final void Function(Pointer<Utf8>) _frei;
  final Pointer<Utf8> Function(Pointer<Utf8>) _absturz;

  /// Nicht aufgefangene panics der Go-Laufzeit zusaetzlich in [pfad]
  /// schreiben (die Laufzeit beendet den Prozess dann trotzdem).
  void absturzdatei(String pfad) {
    final z = pfad.toNativeUtf8();
    try {
      _lesen(_absturz(z));
    } finally {
      malloc.free(z);
    }
  }

  Map<String, dynamic> _lesen(Pointer<Utf8> p) {
    try {
      final m = jsonDecode(p.toDartString()) as Map<String, dynamic>;
      if (m['fehler'] != null) throw TunnelFehler(m['fehler'] as String, technisch: true);
      return m;
    } finally {
      _frei(p);
    }
  }

  /// Neues Schluesselpaar. Der private Teil bleibt nur im Speicher (siehe
  /// Netzlage): pro Start ein neues Paar, darum muss nichts Geheimes auf
  /// der Platte liegen.
  ({String privat, String oeffentlich}) schluesselpaar() {
    final m = _lesen(_paar());
    return (privat: m['privat'] as String, oeffentlich: m['oeffentlich'] as String);
  }

  /// Startet den Tunnel; liefert Port und Geheimnis des lokalen Proxys.
  ({int port, String geheimnis}) starten({
    required String wgQuick,
    required String privat,
    required List<String> erlaubteZiele,
    required String spiceProxy,
    Map<String, String> hosts = const {},
  }) {
    final k = jsonEncode({
      'wg_quick': wgQuick,
      'private_key': privat,
      'erlaubte_ziele': erlaubteZiele,
      'spice_proxy': spiceProxy,
      'hosts': hosts,
    }).toNativeUtf8();
    try {
      final m = _lesen(_start(k));
      return (port: m['proxy_port'] as int, geheimnis: m['proxy_geheimnis'] as String);
    } finally {
      // Die Konfiguration enthaelt den privaten Schluessel: vor dem Freigeben
      // ueberschreiben, damit er nicht im freien Speicher liegen bleibt.
      final n = k.length;
      k.cast<Uint8>().asTypedList(n).fillRange(0, n, 0);
      malloc.free(k);
    }
  }

  /// Letzter Handshake (Unix-Sekunden, 0 = keiner) und Zaehler.
  Map<String, dynamic>? zustand() {
    try {
      return _lesen(_zustand());
    } on TunnelFehler {
      return null;
    }
  }

  /// Lokaler Port, der zu einem freigegebenen Ziel im Tunnel durchreicht
  /// (fuer die HTTP-Schnittstelle des Gateways).
  int weiterleitung(String ziel) {
    final z = ziel.toNativeUtf8();
    try {
      return _lesen(_weiter(z))['port'] as int;
    } finally {
      malloc.free(z);
    }
  }

  /// Endpunkt im laufenden Tunnel wechseln (WireGuard-Roaming: offene
  /// Verbindungen, z. B. ein Bildschirm, bleiben bestehen).
  void endpunkt(String ep) {
    final z = ep.toNativeUtf8();
    try {
      _lesen(_endpunkt(z));
    } finally {
      malloc.free(z);
    }
  }

  void stoppen() => _stop();
}

class TunnelFehler implements Exception {
  TunnelFehler(this.text, {this.status, this.technisch = false});
  final String text;

  /// Roher Text der Go-Bibliothek (nicht fuer die Person, nur "Details").
  final bool technisch;

  /// HTTP-Status der Haupt-API, falls sie abgelehnt hat (401 = neu anmelden).
  final int? status;
  @override
  String toString() => text;
}
