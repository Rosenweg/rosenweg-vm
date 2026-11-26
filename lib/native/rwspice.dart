// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import 'bibliothek.dart';

/// Ereignisse aus native/rwspice/rwspice.h (RW_E_*).
enum SpiceEreignisArt {
  verbunden(1),
  bildGroesse(2),
  bildWeg(3),
  getrennt(4),
  mausmodus(5),
  ton(6),
  mikrofon(7),
  usb(8),
  usbFehler(9),
  agent(10);

  const SpiceEreignisArt(this.code);
  final int code;
  static SpiceEreignisArt? aus(int c) {
    for (final a in values) {
      if (a.code == c) return a;
    }
    return null;
  }
}

/// Gruende fuer RW_E_GETRENNT (RW_G_*).
enum TrennGrund { normal, tls, anmeldung, verbindung, anderes }

class SpiceEreignis {
  SpiceEreignis(this.art, this.a, this.b);
  final SpiceEreignisArt art;
  final int a, b;
}

class UsbGeraet {
  UsbGeraet(this.id, this.name, this.verbunden, this.moeglich, this.grund);
  final String id, name, grund;
  final bool verbunden, moeglich;
}

typedef _EreignisC = Void Function(Int32, Int32, Int32, Int32, Int32);

/// Bindung an librwspice. Eine Sitzung zur Zeit (siehe rwspice.h).
class RwSpice {
  RwSpice._(DynamicLibrary lib)
      : _start = lib.lookupFunction<Void Function(Int32, Pointer<NativeFunction<_EreignisC>>),
            void Function(int, Pointer<NativeFunction<_EreignisC>>)>('rw_spice_start'),
        _verbinden = lib.lookupFunction<
            Int32 Function(Pointer<Utf8>, Int32, Int32, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>),
            int Function(Pointer<Utf8>, int, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>)>('rw_spice_verbinden'),
        trennen = lib.lookupFunction<Void Function(), void Function()>('rw_spice_trennen'),
        bildAbholen = lib.lookupFunction<Int32 Function(Pointer<Uint8>, Int32, Pointer<Int32>, Pointer<Int32>),
            int Function(Pointer<Uint8>, int, Pointer<Int32>, Pointer<Int32>)>('rw_spice_bild_abholen'),
        mausPosition = lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('rw_spice_maus_position'),
        mausBewegung = lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('rw_spice_maus_bewegung'),
        mausTaste = lib.lookupFunction<Void Function(Int32, Int32, Int32), void Function(int, int, int)>('rw_spice_maus_taste'),
        taste = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('rw_spice_taste'),
        bildschirmGroesse = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('rw_spice_bildschirm_groesse'),
        _ton = lib.lookupFunction<Void Function(Int32, Int32), void Function(int, int)>('rw_spice_ton'),
        _usbListe = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_spice_usb_liste'),
        _usbSchalten = lib.lookupFunction<Void Function(Pointer<Utf8>, Int32), void Function(Pointer<Utf8>, int)>('rw_spice_usb_schalten'),
        _fehler = lib.lookupFunction<Pointer<Utf8> Function(), Pointer<Utf8> Function()>('rw_spice_letzter_fehler'),
        _frei = lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>('rw_spice_frei') {
    // listener: das Ereignis kommt aus dem GLib-Thread und wird hier im
    // Dart-Isolat zugestellt — ohne dass der GLib-Thread auf Dart wartet.
    _cb = NativeCallable<_EreignisC>.listener((int art, int a, int b, int c, int d) {
      final e = SpiceEreignisArt.aus(art);
      if (e != null) _ereignisse.add(SpiceEreignis(e, a, b));
    });
    // Linux: die GTK-Hauptschleife von Flutter dreht den GLib-Standardkontext
    // schon; ein zweiter Thread darauf waere ein Wettlauf. Sonst eigener Thread.
    _start(Platform.isLinux ? 0 : 1, _cb.nativeFunction);
  }

  static RwSpice? _inst;
  static RwSpice get i => _inst ??= RwSpice._(bibliothekLaden('rwspice'));

  final void Function(int, Pointer<NativeFunction<_EreignisC>>) _start;
  final int Function(Pointer<Utf8>, int, int, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>) _verbinden;
  final void Function() trennen;
  final int Function(Pointer<Uint8>, int, Pointer<Int32>, Pointer<Int32>) bildAbholen;
  final void Function(int, int, int) mausPosition, mausBewegung, mausTaste;
  final void Function(int, int) taste, bildschirmGroesse, _ton;
  final Pointer<Utf8> Function() _usbListe, _fehler;
  final void Function(Pointer<Utf8>, int) _usbSchalten;
  final void Function(Pointer<Utf8>) _frei;
  late final NativeCallable<_EreignisC> _cb;
  final _ereignisse = StreamController<SpiceEreignis>.broadcast();

  Stream<SpiceEreignis> get ereignisse => _ereignisse.stream;

  /// Verbindet mit den Angaben aus spiceproxy (siehe Gateway.spice()).
  void verbinden({
    required String host,
    int port = 0,
    int tlsPort = 0,
    String? passwort,
    String? proxy,
    String? ca,
    String? hostSubject,
  }) {
    final zeiger = <Pointer<Utf8>>[];
    Pointer<Utf8> s(String? t) {
      if (t == null || t.isEmpty) return nullptr;
      final p = t.toNativeUtf8();
      zeiger.add(p);
      return p;
    }

    try {
      final r = _verbinden(s(host), port, tlsPort, s(passwort), s(proxy), s(ca), s(hostSubject));
      if (r != 0) throw StateError('Verbindungsangaben unvollstaendig');
    } finally {
      // rwspice kopiert alles; Ticket nicht laenger als noetig liegen lassen.
      for (final p in zeiger) {
        final n = p.length;
        p.cast<Uint8>().asTypedList(n).fillRange(0, n, 0);
        malloc.free(p);
      }
    }
  }

  void ton({required bool wiedergabe, required bool mikrofon}) => _ton(wiedergabe ? 1 : 0, mikrofon ? 1 : 0);

  List<UsbGeraet> usbListe() {
    final p = _usbListe();
    try {
      final l = jsonDecode(p.toDartString()) as List<dynamic>;
      return [
        for (final e in l.cast<Map<String, dynamic>>())
          UsbGeraet(e['id'] as String, (e['name'] as String).trim(), e['verbunden'] as bool, e['moeglich'] as bool,
              e['grund'] as String? ?? ''),
      ];
    } finally {
      _frei(p);
    }
  }

  void usbSchalten(String id, bool an) {
    final p = id.toNativeUtf8();
    try {
      _usbSchalten(p, an ? 1 : 0);
    } finally {
      malloc.free(p);
    }
  }

  String letzterFehler() {
    final p = _fehler();
    try {
      return p.toDartString();
    } finally {
      _frei(p);
    }
  }
}
