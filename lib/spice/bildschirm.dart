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
import 'tastatur.dart';
import 'tastatur_einstellung.dart';

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
  const SpiceBildschirm({super.key, this.hinweis});

  /// Kurzer Hinweis an die Person (z. B. Zeichen fehlt in der Gastbelegung).
  final void Function(String text)? hinweis;

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

  // ── Tastatur ─────────────────────────────────────────────────────────
  //
  // Modus "zeichen" (Vorgabe): druckbare Zeichen werden aus dem GETIPPTEN
  // Zeichen in die Tastenfolge der Gastbelegung uebersetzt (tastatur.dart).
  // Damit passt jede Tastatur am Geraet zu jeder Gastbelegung. Umschalter
  // (Shift, Alt/Option, Strg, Cmd) gehen dabei nicht einzeln zum Gast,
  // sondern nur zusammen mit einer Steuertaste (Pfeile, F-Tasten, Enter …)
  // oder als Kurzbefehl (Strg/Cmd + Taste).
  // Modus "direkt": jede Taste physisch, wie bisher.

  final _einstellung = TastaturEinstellung.i;

  /// Physisch gesendete Tasten: Taste -> mitgedrueckte Umschalter (zum
  /// Loslassen in umgekehrter Reihenfolge).
  final _gesendet = <PhysicalKeyboardKey, List<int>>{};
  final _gemeldet = <String>{};

  void _tasteSenden(int sc, bool druck) {
    if (druck) {
      _gedrueckt.add(sc);
    } else {
      _gedrueckt.remove(sc);
    }
    _spice.taste(sc, druck ? 1 : 0);
  }

  /// Gerade gehaltene Umschalter als Gast-Scancodes (Zeichenmodus).
  List<int> _umschalter() {
    final h = HardwareKeyboard.instance;
    return [
      if (h.isControlPressed || (h.isMetaPressed && _einstellung.cmdAlsStrg)) scStrg,
      if (h.isAltPressed) scAlt,
      if (h.isShiftPressed) scShift,
      if (h.isMetaPressed && !_einstellung.cmdAlsStrg) scSuper,
    ];
  }

  KeyEventResult _tastatur(FocusNode n, KeyEvent e) {
    if (_einstellung.modus == TastaturModus.direkt) return _direkt(e);
    final k = e.physicalKey;

    if (e is KeyUpEvent) {
      final mods = _gesendet.remove(k);
      if (mods != null) {
        final sc = _gedruecktVon(k);
        if (sc != null) _tasteSenden(sc, false);
        for (final m in mods.reversed) {
          _tasteSenden(m, false);
        }
      }
      return KeyEventResult.handled;
    }

    // Umschalter selbst und die Feststelltaste: nichts senden (das Zeichen
    // bringt sie schon mit).
    if (istUmschalter(k) || k == PhysicalKeyboardKey.capsLock) return KeyEventResult.handled;

    final h = HardwareKeyboard.instance;
    // AltGr meldet Windows als Strg+Alt: mit druckbarem Zeichen ist das Text,
    // kein Kurzbefehl.
    final altGr = h.isControlPressed && h.isAltPressed && druckbar(e.character);
    final kurzbefehl = (h.isControlPressed || h.isMetaPressed) && !altGr;

    if (istSteuertaste(k) || kurzbefehl) {
      if (e is KeyRepeatEvent) {
        final sc = _gedruecktVon(k);
        if (sc != null) _tasteSenden(sc, true);
        return KeyEventResult.handled;
      }
      // Kurzbefehl mit Buchstabe/Zeichen: die Taste, die im GAST dieses
      // Zeichen ergibt (Strg+Z auf CH-Mac → Strg+Z im Gast, egal welche
      // Belegung er hat).
      int? sc;
      if (!istSteuertaste(k)) {
        final label = e.logicalKey.keyLabel;
        if (label.runes.length == 1) sc = grundTaste(_einstellung.belegung, label.toLowerCase().runes.first);
      }
      sc ??= scancode(k, macIsoTausch: _einstellung.macIsoTausch);
      if (sc == null) return KeyEventResult.ignored;
      final mods = _umschalter();
      for (final m in mods) {
        _tasteSenden(m, true);
      }
      _gesendet[k] = mods;
      _scVon[k] = sc;
      _tasteSenden(sc, true);
      return KeyEventResult.handled;
    }

    // Druckbares Zeichen (auch Umlaute, Akzente nach Tottaste, Option-Zeichen
    // am Mac). Tottaste selbst liefert kein Zeichen: nichts senden.
    final c = e.character;
    if (!druckbar(c)) return KeyEventResult.handled;
    final folge = zeichenFolge(_einstellung.belegung, c!.runes.first);
    if (folge == null) {
      Protokoll.schreiben('Tastatur: Zeichen "$c" (U+${c.runes.first.toRadixString(16).toUpperCase()}) '
          'ist in der Gastbelegung ${_einstellung.belegung.kennung} nicht vorhanden');
      if (_gemeldet.add(c)) {
        widget.hinweis?.call('Zeichen „$c“ ist in der Belegung ${_einstellung.belegung.name} nicht vorhanden.');
      }
      return KeyEventResult.handled;
    }
    _spice.feststellAus();
    for (final t in folge) {
      _tasteSenden(t.sc, t.druck);
    }
    return KeyEventResult.handled;
  }

  final _scVon = <PhysicalKeyboardKey, int>{};
  int? _gedruecktVon(PhysicalKeyboardKey k) => _scVon[k];

  KeyEventResult _direkt(KeyEvent e) {
    final sc = scancode(e.physicalKey,
        macIsoTausch: _einstellung.macIsoTausch, cmdAlsStrg: _einstellung.cmdAlsStrg);
    if (sc == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent || e is KeyRepeatEvent) {
      _tasteSenden(sc, true);
    } else if (e is KeyUpEvent) {
      _tasteSenden(sc, false);
    }
    return KeyEventResult.handled;
  }

  /// Fokus weg (z. B. Fenster gewechselt): gedrueckte Tasten loslassen, sonst
  /// klemmt im Gast eine Umschalttaste.
  void _allesLoslassen() {
    for (final sc in _gedrueckt.toList()) {
      _spice.taste(sc, 0);
    }
    _gedrueckt.clear();
    _gesendet.clear();
    _scVon.clear();
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
