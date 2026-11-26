// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../native/rwspice.dart';
import '../protokoll.dart';
import 'scancodes.dart';

/// Zeigt das Bild einer SPICE-Sitzung und schickt Maus, Tastatur und
/// Beruehrung zurueck.
///
/// Bildweg heute: rwspice kopiert die Primaerflaeche in einen eigenen Puffer;
/// dieses Widget holt ihn pro Bildschirmtakt ab (nur wenn sich etwas
/// geaendert hat) und macht daraus ein ui.Image. Das ist auf allen
/// Plattformen derselbe Dart-Code. Naechster Schritt fuer weniger Kopien:
/// eine Flutter-Texture je Plattform (Linux FlPixelBufferTexture, macOS/iOS
/// CVPixelBuffer, Windows PixelBufferTexture, Android SurfaceTexture), gespeist
/// aus demselben Puffer — die Schnittstelle von rwspice bleibt gleich.
class SpiceBildschirm extends StatefulWidget {
  const SpiceBildschirm({super.key});

  @override
  State<SpiceBildschirm> createState() => _SpiceBildschirmState();
}

class _SpiceBildschirmState extends State<SpiceBildschirm> with SingleTickerProviderStateMixin {
  final _spice = RwSpice.i;
  late final Ticker _takt;
  final _fokus = FocusNode();
  StreamSubscription<SpiceEreignis>? _abo;

  Pointer<Uint8> _puffer = nullptr;
  int _pufferBytes = 0;
  final Pointer<Int32> _b = calloc<Int32>(), _h = calloc<Int32>();
  ui.Image? _bild;
  bool _dekodiert = false;

  int _breite = 0, _hoehe = 0;
  bool _absolut = true; // Mausmodus Client (Tablet/Agent) oder Server
  int _tasten = 0;
  final _gedrueckt = <int>{};

  @override
  void initState() {
    super.initState();
    _takt = createTicker((_) => _abholen())..start();
    _abo = _spice.ereignisse.listen((e) {
      switch (e.art) {
        case SpiceEreignisArt.bildGroesse:
          // Neue Flaeche (Start, Anmeldung im Gast, Aufloesung): altes Bild
          // weg, "Bild wird aufgebaut" bis der erste Inhalt kommt.
          Protokoll.schreiben('Bildflaeche ${e.a}x${e.b}');
          setState(() {
            _breite = e.a;
            _hoehe = e.b;
            _bildWeg();
          });
        case SpiceEreignisArt.bildWeg:
          setState(_bildWeg);
        case SpiceEreignisArt.mausmodus:
          _absolut = e.a == 2;
        default:
          break;
      }
    });
  }

  void _bildWeg() {
    _bild?.dispose();
    _bild = null;
  }

  void _abholen() {
    if (_dekodiert) return; // vorheriges Bild noch in Arbeit: Takt auslassen
    final noetig = _breite * _hoehe * 4;
    if (noetig <= 0) return;
    if (_pufferBytes < noetig) {
      if (_puffer != nullptr) malloc.free(_puffer);
      _puffer = malloc<Uint8>(noetig);
      _pufferBytes = noetig;
    }
    final r = _spice.bildAbholen(_puffer, _pufferBytes, _b, _h);
    if (r != 1) return;
    final w = _b.value, h = _h.value;
    _dekodiert = true;
    // fromUint8List kopiert; danach darf rwspice den Puffer wieder fuellen.
    ui.ImmutableBuffer.fromUint8List(_puffer.asTypedList(w * h * 4)).then((buf) async {
      final desc = ui.ImageDescriptor.raw(buf, width: w, height: h, pixelFormat: ui.PixelFormat.bgra8888);
      final codec = await desc.instantiateCodec();
      final frame = await codec.getNextFrame();
      codec.dispose();
      desc.dispose();
      buf.dispose();
      if (!mounted || w != _breite || h != _hoehe) {
        // Inzwischen neue Flaeche: altes Bild nicht mehr zeigen.
        frame.image.dispose();
        _dekodiert = false;
        return;
      }
      final alt = _bild;
      setState(() => _bild = frame.image);
      alt?.dispose();
      _dekodiert = false;
    });
  }

  // ── Eingaben ──────────────────────────────────────────────────────────

  /// Umrechnung Widget → Gastbildschirm (das Bild ist eingepasst, nicht verzerrt).
  Offset? _gast(Offset lokal, Size groesse) {
    if (_breite == 0) return null;
    final s = math.min(groesse.width / _breite, groesse.height / _hoehe);
    final dx = (groesse.width - _breite * s) / 2, dy = (groesse.height - _hoehe * s) / 2;
    final x = (lokal.dx - dx) / s, y = (lokal.dy - dy) / s;
    return Offset(x.clamp(0, _breite - 1).toDouble(), y.clamp(0, _hoehe - 1).toDouble());
  }

  static int _maske(int flutterTasten) {
    var m = 0;
    if (flutterTasten & kPrimaryButton != 0) m |= 1;
    if (flutterTasten & kMiddleMouseButton != 0) m |= 2;
    if (flutterTasten & kSecondaryButton != 0) m |= 4;
    return m;
  }

  void _bewegen(PointerEvent e, Size g) {
    if (_absolut) {
      final p = _gast(e.localPosition, g);
      if (p != null) _spice.mausPosition(p.dx.round(), p.dy.round(), _tasten);
    } else {
      _spice.mausBewegung(e.delta.dx.round(), e.delta.dy.round(), _tasten);
    }
  }

  void _taste(PointerEvent e, Size g, bool runter) {
    _fokus.requestFocus();
    _bewegen(e, g);
    final neu = _maske(e.buttons);
    // Beruehrung meldet keine Taste: als linke Taste werten.
    final effektiv = e.kind == PointerDeviceKind.touch ? (runter ? 1 : 0) : neu;
    for (final (bit, spiceTaste) in [(1, 1), (2, 2), (4, 3)]) {
      final war = _tasten & bit != 0, ist = effektiv & bit != 0;
      if (war != ist) _spice.mausTaste(spiceTaste, ist ? 1 : 0, effektiv);
    }
    _tasten = effektiv;
  }

  // ── Scrollen ──────────────────────────────────────────────────────────
  // SPICE kennt nur das Mausrad als Tasten 4 (hoch) und 5 (runter), je
  // Druck ein Schritt; waagrecht gibt es im Protokoll nicht.
  // Mausrad: PointerScrollEvent, eine Raste = mindestens ein Schritt.
  // Trackpad (macOS): PointerPanZoom*, feine Deltas — aufsummieren, je
  // [_schrittPx] logische Pixel ein Schritt.
  static const _schrittPx = 24.0;
  double _scrollRest = 0;

  void _radSchritte(int n) {
    final taste = n < 0 ? 4 : 5; // SPICE_MOUSE_BUTTON_UP/DOWN
    for (var i = 0; i < n.abs() && i < 10; i++) {
      _spice.mausTaste(taste, 1, _tasten);
      _spice.mausTaste(taste, 0, _tasten);
    }
  }

  void _rad(PointerSignalEvent e) {
    if (e is! PointerScrollEvent) return;
    final dy = e.scrollDelta.dy;
    if (dy == 0) return;
    final n = (dy / _schrittPx).round();
    _radSchritte(n == 0 ? dy.sign.toInt() : n);
  }

  void _panStart(PointerPanZoomStartEvent e) => _scrollRest = 0;

  void _panUpdate(PointerPanZoomUpdateEvent e) {
    // Finger nach unten = Inhalt nach unten = nach oben scrollen (wie am Mac).
    _scrollRest -= e.panDelta.dy;
    final n = (_scrollRest / _schrittPx).truncate();
    if (n != 0) {
      _scrollRest -= n * _schrittPx;
      _radSchritte(n);
    }
  }

  KeyEventResult _tastatur(FocusNode n, KeyEvent e) {
    final sc = scancode(e.physicalKey);
    if (sc == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      _gedrueckt.add(sc);
      _spice.taste(sc, 1);
    } else if (e is KeyUpEvent) {
      _gedrueckt.remove(sc);
      _spice.taste(sc, 0);
    }
    return KeyEventResult.handled;
  }

  /// Fokus weg (z. B. Fenster gewechselt): gedrueckte Tasten loslassen, sonst
  /// klemmt im Gast eine Umschalttaste.
  void _allesLoslassen() {
    for (final sc in _gedrueckt) {
      _spice.taste(sc, 0);
    }
    _gedrueckt.clear();
  }

  @override
  Widget build(BuildContext context) {
    final bild = _bild;
    return Focus(
      focusNode: _fokus,
      autofocus: true,
      onKeyEvent: _tastatur,
      onFocusChange: (an) {
        if (!an) _allesLoslassen();
      },
      child: LayoutBuilder(builder: (context, c) {
        final g = Size(c.maxWidth, c.maxHeight);
        return Listener(
          onPointerHover: (e) => _bewegen(e, g),
          onPointerMove: (e) => _bewegen(e, g),
          onPointerDown: (e) => _taste(e, g, true),
          onPointerUp: (e) => _taste(e, g, false),
          onPointerSignal: _rad,
          onPointerPanZoomStart: _panStart,
          onPointerPanZoomUpdate: _panUpdate,
          child: ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(
              child: bild == null
                  ? const Center(
                      child: Column(mainAxisSize: MainAxisSize.min, children: [
                        CircularProgressIndicator(color: Colors.white70),
                        SizedBox(height: 16),
                        Text('Bild wird aufgebaut …', style: TextStyle(color: Colors.white70)),
                      ]),
                    )
                  : RawImage(image: bild, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
            ),
          ),
        );
      }),
    );
  }

  @override
  void dispose() {
    _allesLoslassen();
    _takt.dispose();
    _abo?.cancel();
    _fokus.dispose();
    _bild?.dispose();
    if (_puffer != nullptr) malloc.free(_puffer);
    calloc.free(_b);
    calloc.free(_h);
    super.dispose();
  }
}
