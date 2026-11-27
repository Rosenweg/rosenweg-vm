// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../native/rwspice.dart';
import '../protokoll.dart';
import 'bildschirm_tastatur.dart';
import 'scancodes.dart';
import 'spice_ziel.dart';
import 'tastatur.dart';
import 'tastatur_einstellung.dart';

/// Bedienung des Bildschirms von aussen (Leiste der Seite): Bildschirm-
/// tastatur auf/zu, Sondertasten, gehaltene Umschalter, Fokus zurueck.
class BildschirmSteuerung extends ChangeNotifier {
  _SpiceBildschirmState? _s;
  final _gehalten = <Umschalter>{};
  bool _tastatur = false;

  /// Umschalter, die beim naechsten Tastendruck mitgehen.
  Set<Umschalter> get gehalten => Set.unmodifiable(_gehalten);

  /// Bildschirmtastatur und Sondertasten-Leiste sind offen.
  bool get tastaturOffen => _tastatur;

  void umschalten(Umschalter u) {
    if (!_gehalten.remove(u)) _gehalten.add(u);
    notifyListeners();
    _s?._fokusHolen();
  }

  /// Eine Taste antippen (mit den gehaltenen Umschaltern).
  void tippen(int sc) => _s?._antippen(sc);

  /// Tasten gemeinsam druecken und in umgekehrter Reihenfolge loslassen
  /// (Strg+Alt+Entf). Gehaltene Umschalter bleiben unberuehrt.
  void kombination(List<int> tasten) => _s?._kombination(tasten);

  void tastatur(bool an) {
    if (_tastatur == an) return;
    _tastatur = an;
    _s?._imeSchalten(an);
    notifyListeners();
  }

  /// Tastaturfokus zurueck aufs Bild (nach einem Blatt oder Menue).
  void fokus() => _s?._fokusHolen();

  /// Das System hat die Bildschirmtastatur geschlossen.
  void _imeZu() {
    if (!_tastatur) return;
    _tastatur = false;
    notifyListeners();
  }

  /// Gehaltene Umschalter fuer einen Tastendruck nehmen und loslassen.
  List<int> _verbrauchen() {
    if (_gehalten.isEmpty) return const [];
    final l = [
      for (final u in Umschalter.values)
        if (_gehalten.contains(u)) u.sc,
    ];
    _gehalten.clear();
    notifyListeners();
    return l;
  }
}

/// Bildschirmtastatur auf Android/iOS: ein unsichtbares Eingabefeld, dessen
/// Aenderungen als Tasten zum Gast gehen (siehe [textAenderung]).
class _Ime with TextInputClient {
  _Ime(this._s);
  final _SpiceBildschirmState _s;
  TextInputConnection? _v;
  var _wert = const TextEditingValue(
    text: imePlatzhalter,
    selection: TextSelection.collapsed(offset: imePlatzhalter.length),
  );

  /// Je Zeichen im Feld: ist es beim Gast angekommen? Der Platzhalter zaehlt
  /// als angekommen (Rueckschritt im "leeren" Feld loescht im Gast). Ein
  /// Zeichen, das die Gastbelegung nicht hat, wird beim Loeschen nicht
  /// zurueckgenommen.
  var _angekommen = List<bool>.filled(imePlatzhalter.length, true);

  bool get offen => _v?.attached ?? false;

  void oeffnen(int? viewId) {
    if (!offen) {
      _v = TextInput.attach(this, imeKonfiguration(viewId: viewId));
      _zuruecksetzen();
    }
    _v!.show();
  }

  void schliessen() {
    _v?.close();
    _v = null;
  }

  void _zuruecksetzen() {
    _angekommen = List<bool>.filled(imePlatzhalter.length, true);
    _wert = const TextEditingValue(
      text: imePlatzhalter,
      selection: TextSelection.collapsed(offset: imePlatzhalter.length),
    );
    _v?.setEditingState(_wert);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _wert;

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateEditingValue(TextEditingValue neu) {
    final alt = _wert;
    _wert = neu;
    if (alt.text == neu.text) {
      // Nur die Schreibmarke bewegt (Wischen auf der Leertaste): als Pfeile.
      final d = neu.selection.baseOffset - alt.selection.baseOffset;
      if (neu.selection.isCollapsed && d != 0 && neu.composing.isCollapsed) {
        for (var i = 0; i < d.abs() && i < 50; i++) {
          _s._antippen(d < 0 ? 0x14b : 0x14d);
        }
        _zuruecksetzen();
      }
      return;
    }
    final a = textAenderung(alt.text, neu.text);
    final bleibt = (_angekommen.length - a.zurueck).clamp(0, _angekommen.length);
    final zurueck = _angekommen.sublist(bleibt).where((x) => x).length;
    _angekommen = [..._angekommen.take(bleibt), ..._s._imeText(zurueck, a.neu)];
    // Feld wieder auf den Platzhalter, sobald nichts mehr komponiert wird
    // und es zu kurz oder zu lang geworden ist.
    final laenge = neu.text.runes.length;
    if (neu.composing.isCollapsed || !neu.composing.isValid) {
      if (laenge < 3 || laenge > 40 || !neu.text.startsWith('\u200B\u200B')) _zuruecksetzen();
    }
  }

  @override
  void performAction(TextInputAction action) {
    if (action != TextInputAction.newline) _s._antippen(0x1c);
  }

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}
  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}
  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  @override
  void connectionClosed() {
    _v = null;
    _s._imeGeschlossen();
  }
}

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
  const SpiceBildschirm({super.key, this.hinweis, this.steuerung, this.ziel});

  /// Kurzer Hinweis an die Person (z. B. Zeichen fehlt in der Gastbelegung).
  final void Function(String text)? hinweis;

  /// Bildschirmtastatur, Sondertasten, Fokus (von der Leiste der Seite).
  final BildschirmSteuerung? steuerung;

  /// Wohin Eingaben gehen; ohne Angabe librwspice.
  final SpiceZiel? ziel;

  @override
  State<SpiceBildschirm> createState() => _SpiceBildschirmState();
}

class _SpiceBildschirmState extends State<SpiceBildschirm> with SingleTickerProviderStateMixin {
  late final SpiceZiel _spice = widget.ziel ?? RwSpice.i;
  late final BildschirmSteuerung _steuerung = widget.steuerung ?? BildschirmSteuerung();
  late final _ime = _Ime(this);
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
    _steuerung._s = this;
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

  /// Gerade gehaltene Umschalter als Gast-Scancodes (Zeichenmodus), dazu
  /// die aus der Sondertasten-Leiste ([klebend], schon verbraucht).
  List<int> _umschalter(List<int> klebend) {
    final h = HardwareKeyboard.instance;
    final l = [
      if (h.isControlPressed || (h.isMetaPressed && _einstellung.cmdAlsStrg)) scStrg,
      if (h.isAltPressed) scAlt,
      if (h.isShiftPressed) scShift,
      if (h.isMetaPressed && !_einstellung.cmdAlsStrg) scSuper,
    ];
    for (final k in klebend) {
      if (!l.contains(k)) l.add(k);
    }
    return l;
  }

  KeyEventResult _tastatur(FocusNode n, KeyEvent e) {
    if (_einstellung.modus == TastaturModus.direkt) return _direkt(e);
    return _zeichen(e);
  }

  KeyEventResult _zeichen(KeyEvent e) {
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
    if (istUmschalterEreignis(e) || k == PhysicalKeyboardKey.capsLock || e.logicalKey == LogicalKeyboardKey.capsLock) {
      return KeyEventResult.handled;
    }

    final h = HardwareKeyboard.instance;
    // AltGr meldet Windows als Strg+Alt: mit druckbarem Zeichen ist das Text,
    // kein Kurzbefehl.
    final altGr = h.isControlPressed && h.isAltPressed && druckbar(e.character);
    final klebend = _steuerung._gehalten.isNotEmpty;
    final kurzbefehl = ((h.isControlPressed || h.isMetaPressed) && !altGr) || klebend;
    final steuer = istSteuertasteEreignis(e);

    if (steuer || kurzbefehl) {
      if (e is KeyRepeatEvent) {
        final sc = _gedruecktVon(k);
        if (sc != null) _tasteSenden(sc, true);
        return KeyEventResult.handled;
      }
      // Kurzbefehl mit Buchstabe/Zeichen: die Taste, die im GAST dieses
      // Zeichen ergibt (Strg+Z auf CH-Mac → Strg+Z im Gast, egal welche
      // Belegung er hat).
      int? sc;
      if (!steuer) {
        final label = e.logicalKey.keyLabel;
        if (label.runes.length == 1) sc = grundTaste(_einstellung.belegung, label.toLowerCase().runes.first);
        final c = e.character;
        if (sc == null && druckbar(c)) sc = grundTaste(_einstellung.belegung, c!.toLowerCase().runes.first);
      }
      sc ??= tastenScancode(e, macIsoTausch: _einstellung.macIsoTausch);
      if (sc == null) return KeyEventResult.ignored;
      final mods = _umschalter(_steuerung._verbrauchen());
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
    _zeichenSenden(c!.runes.first);
    return KeyEventResult.handled;
  }

  /// Ein Zeichen in der Belegung des Gasts tippen (mit gehaltenen
  /// Umschaltern aus der Leiste, siehe [zeichenTasten]).
  bool _zeichenSenden(int zeichen) {
    final klebend = _steuerung._verbrauchen();
    final folge = zeichenTasten(_einstellung.belegung, zeichen, umschalter: klebend);
    if (folge == null) {
      final c = String.fromCharCode(zeichen);
      Protokoll.schreiben(
        'Tastatur: Zeichen "$c" (U+${zeichen.toRadixString(16).toUpperCase()}) '
        'ist in der Gastbelegung ${_einstellung.belegung.kennung} nicht vorhanden',
      );
      if (_gemeldet.add(c)) {
        widget.hinweis?.call('Zeichen „$c“ ist in der Belegung ${_einstellung.belegung.name} nicht vorhanden.');
      }
      return false;
    }
    if (klebend.isEmpty) _spice.feststellAus();
    for (final t in folge) {
      _tasteSenden(t.sc, t.druck);
    }
    return true;
  }

  final _scVon = <PhysicalKeyboardKey, int>{};
  int? _gedruecktVon(PhysicalKeyboardKey k) => _scVon[k];

  KeyEventResult _direkt(KeyEvent e) {
    final hid = scancode(e.physicalKey) != null;
    // Ohne Scancode (Bildschirmtastatur, adb): Zeichen wie im Zeichenmodus,
    // Steuertasten ueber die logische Taste.
    if (!hid && !istSteuertasteEreignis(e) && !istUmschalterEreignis(e)) return _zeichen(e);
    final sc = tastenScancode(e, macIsoTausch: _einstellung.macIsoTausch, cmdAlsStrg: _einstellung.cmdAlsStrg);
    if (sc == null) return KeyEventResult.ignored;
    if (e is KeyDownEvent) {
      final mods = istUmschalterEreignis(e) ? const <int>[] : _steuerung._verbrauchen();
      for (final m in mods) {
        _tasteSenden(m, true);
      }
      if (mods.isNotEmpty) _gesendet[e.physicalKey] = mods;
      _tasteSenden(sc, true);
    } else if (e is KeyRepeatEvent) {
      _tasteSenden(sc, true);
    } else if (e is KeyUpEvent) {
      _tasteSenden(sc, false);
      for (final m in (_gesendet.remove(e.physicalKey) ?? const <int>[]).reversed) {
        _tasteSenden(m, false);
      }
    }
    return KeyEventResult.handled;
  }

  // ── Leiste und Bildschirmtastatur ──────────────────────────────────────

  /// Taste antippen, mit den gehaltenen Umschaltern.
  void _antippen(int sc) {
    final mods = _steuerung._verbrauchen();
    for (final m in mods) {
      _tasteSenden(m, true);
    }
    _tasteSenden(sc, true);
    _tasteSenden(sc, false);
    for (final m in mods.reversed) {
      _tasteSenden(m, false);
    }
    _fokusHolen();
  }

  void _kombination(List<int> tasten) {
    for (final sc in tasten) {
      _tasteSenden(sc, true);
    }
    for (final sc in tasten.reversed) {
      _tasteSenden(sc, false);
    }
    _fokusHolen();
  }

  /// Aenderung im Feld der Bildschirmtastatur: [zurueck] Rueckschritte,
  /// dann [text] Zeichen fuer Zeichen. Rueckgabe: je Zeichen, ob es ankam.
  List<bool> _imeText(int zurueck, String text) {
    for (var i = 0; i < zurueck; i++) {
      _antippen(0x0e);
    }
    return [
      for (final r in text.runes) r == 0x200B || _zeichenSenden(r), // 0x200B: Platzhalter
    ];
  }

  /// Bildschirmtastatur nur auf Telefonen und Tablets; am Rechner bleibt
  /// es bei der Leiste (die echte Tastatur geht ohnehin).
  static bool get _mitIme =>
      defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;

  void _imeSchalten(bool an) {
    if (!_mitIme) return;
    if (an) {
      _fokus.requestFocus();
      _ime.oeffnen(View.maybeOf(context)?.viewId);
    } else {
      _ime.schliessen();
    }
  }

  void _imeGeschlossen() {
    _steuerung._imeZu();
  }

  void _fokusHolen() {
    if (!mounted) return;
    _fokus.requestFocus();
    // Nach einem Blatt ist die Verbindung zur Bildschirmtastatur weg.
    if (_steuerung._tastatur && _mitIme && !_ime.offen) _ime.oeffnen(View.maybeOf(context)?.viewId);
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
      child: LayoutBuilder(
        builder: (context, c) {
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
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            CircularProgressIndicator(color: Colors.white70),
                            SizedBox(height: 16),
                            Text('Bild wird aufgebaut …', style: TextStyle(color: Colors.white70)),
                          ],
                        ),
                      )
                    : RawImage(image: bild, fit: BoxFit.contain, filterQuality: FilterQuality.medium),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _ime.schliessen();
    if (_steuerung._s == this) _steuerung._s = null;
    if (widget.steuerung == null) _steuerung.dispose();
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
