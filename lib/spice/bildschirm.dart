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
import 'bedien_einstellung.dart';
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
  final _bedienung = BedienEinstellung.i;

  @override
  void initState() {
    super.initState();
    _steuerung._s = this;
    _bedienung.addListener(_bedienungGeaendert);
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
            _zeiger = Offset(e.a / 2, e.b / 2);
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
  //
  // Maus und Stift: wie am Rechner (Position, Tasten, Rad).
  // Finger (siehe _finger*): Tippen = Klick, Doppeltipp = Doppelklick,
  // lange druecken = Rechtsklick (mit Vibration), ziehen = mit gedrueckter
  // Taste ziehen, zwei Finger ziehen = Mausrad, zwei Finger spreizen = Bild
  // vergroessern; vergroessert verschiebt ein Finger das Bild. Im
  // Touchpad-Modus schiebt ein Finger den Mauszeiger.

  /// Vergroesserung und Verschiebung des Bilds (logische Pixel im Widget).
  double _zoom = 1;
  Offset _versatz = Offset.zero;
  Size _flaeche = Size.zero;

  /// Mauszeiger im Gast (Touchpad-Modus), in Gastpixeln.
  Offset _zeiger = Offset.zero;

  /// Eingepasstes Bild ohne Zoom: Massstab und Rand.
  ({double s, double dx, double dy}) _einpassung(Size g) {
    final s = math.min(g.width / _breite, g.height / _hoehe);
    return (s: s, dx: (g.width - _breite * s) / 2, dy: (g.height - _hoehe * s) / 2);
  }

  /// Umrechnung Widget → Gastbildschirm (eingepasst, nicht verzerrt; mit Zoom).
  Offset? _gast(Offset lokal, Size groesse) {
    if (_breite == 0 || groesse.isEmpty) return null;
    final e = _einpassung(groesse);
    final basis = (lokal - _versatz) / _zoom;
    final x = (basis.dx - e.dx) / e.s, y = (basis.dy - e.dy) / e.s;
    return Offset(x.clamp(0, _breite - 1).toDouble(), y.clamp(0, _hoehe - 1).toDouble());
  }

  /// Umgekehrt: Gastpixel → Widget (fuer den Zeiger im Touchpad-Modus).
  Offset _widget(Offset gast, Size g) {
    final e = _einpassung(g);
    return Offset(e.dx + gast.dx * e.s, e.dy + gast.dy * e.s) * _zoom + _versatz;
  }

  static int _maske(int flutterTasten) {
    var m = 0;
    if (flutterTasten & kPrimaryButton != 0) m |= 1;
    if (flutterTasten & kMiddleMouseButton != 0) m |= 2;
    if (flutterTasten & kSecondaryButton != 0) m |= 4;
    return m;
  }

  void _bewegen(PointerEvent e, Size g) {
    if (e.kind == PointerDeviceKind.touch) return _fingerBewegt(e, g);
    if (_absolut) {
      final p = _gast(e.localPosition, g);
      if (p != null) _spice.mausPosition(p.dx.round(), p.dy.round(), _tasten);
    } else {
      _spice.mausBewegung(e.delta.dx.round(), e.delta.dy.round(), _tasten);
    }
  }

  void _taste(PointerEvent e, Size g, bool runter) {
    _fokusHolen();
    if (e.kind == PointerDeviceKind.touch) return runter ? _fingerRunter(e, g) : _fingerHoch(e, g);
    _bewegen(e, g);
    _tastenSetzen(_maske(e.buttons));
  }

  void _tastenSetzen(int neu) {
    for (final (bit, spiceTaste) in [(1, 1), (2, 2), (4, 3)]) {
      final war = _tasten & bit != 0, ist = neu & bit != 0;
      if (war != ist) _spice.mausTaste(spiceTaste, ist ? 1 : 0, neu);
    }
    _tasten = neu;
  }

  /// Mauszeiger im Gast an diese Stelle (Gastpixel).
  void _hin(Offset gast) {
    if (_absolut) {
      _spice.mausPosition(gast.dx.round(), gast.dy.round(), _tasten);
    }
  }

  /// Klick ([taste]: 1 links, 4 rechts als Maske) an einer Gaststelle.
  void _klick(Offset gast, int taste) {
    _hin(gast);
    _tastenSetzen(taste);
    _tastenSetzen(0);
  }

  // ── Finger ──────────────────────────────────────────────────────────

  static const _ruhe = 12.0; // so weit darf ein Tipp wackeln (logische px)
  static const _langeDruecken = Duration(milliseconds: 500);
  static const _doppeltippZeit = Duration(milliseconds: 400);
  static const _doppeltippWeg = 40.0;

  final _finger = <int, Offset>{};
  _Geste _geste = _Geste.keine;
  Offset _fingerStart = Offset.zero;
  Duration _fingerZeit = Duration.zero;
  Timer? _langTimer;

  /// Letzter Tipp (Gaststelle, Zeit), damit ein Doppeltipp genau dieselbe
  /// Stelle trifft und der Gast ihn als Doppelklick erkennt.
  Offset? _letzterTipp;
  Duration _letzterTippZeit = Duration.zero;

  // Zwei Finger
  double _startAbstand = 0, _startZoom = 1;
  Offset _startMitte = Offset.zero, _startVersatz = Offset.zero, _letzteMitte = Offset.zero;

  bool get _touchpad => _bedienung.touch == TouchModus.touchpad;

  Offset _mitte() {
    final p = _finger.values.take(2).toList();
    return (p[0] + p[1]) / 2;
  }

  double _abstand() {
    final p = _finger.values.take(2).toList();
    return (p[0] - p[1]).distance;
  }

  void _fingerRunter(PointerEvent e, Size g) {
    _finger[e.pointer] = e.localPosition;
    if (_finger.length == 1) {
      _geste = _Geste.wartet;
      _fingerStart = e.localPosition;
      _fingerZeit = e.timeStamp;
      _langTimer?.cancel();
      _langTimer = Timer(_langeDruecken, () => _langGedrueckt(g));
    } else if (_finger.length == 2) {
      _langTimer?.cancel();
      if (_geste == _Geste.ziehen) _tastenSetzen(0);
      _geste = _Geste.zweiFinger;
      _startAbstand = _abstand();
      _startMitte = _letzteMitte = _mitte();
      _startZoom = _zoom;
      _startVersatz = _versatz;
      _fingerZeit = e.timeStamp;
      _scrollRest = 0;
    }
  }

  void _langGedrueckt(Size g) {
    if (_geste != _Geste.wartet || !mounted) return;
    _geste = _Geste.fertig;
    HapticFeedback.mediumImpact();
    final p = _touchpad ? _zeiger : _gast(_fingerStart, g);
    if (p != null) _klick(p, 4);
  }

  void _fingerBewegt(PointerEvent e, Size g) {
    if (!_finger.containsKey(e.pointer)) return;
    final vorher = _finger[e.pointer]!;
    _finger[e.pointer] = e.localPosition;
    switch (_geste) {
      case _Geste.wartet:
        if ((e.localPosition - _fingerStart).distance < _ruhe) return;
        _langTimer?.cancel();
        if (_touchpad) {
          _geste = _Geste.zeiger;
          _zeigerSchieben(e.localPosition - _fingerStart, g);
        } else if (_zoom > 1.01) {
          _geste = _Geste.verschieben;
          _verschieben(e.localPosition - _fingerStart, g);
        } else {
          // Ziehen mit gedrueckter Taste (markieren, Fenster verschieben)
          _geste = _Geste.ziehen;
          final s = _gast(_fingerStart, g);
          if (s != null) _hin(s);
          _tastenSetzen(1);
          final p = _gast(e.localPosition, g);
          if (p != null) _hin(p);
        }
      case _Geste.ziehen:
        final p = _gast(e.localPosition, g);
        if (p != null) _hin(p);
      case _Geste.zeiger:
        _zeigerSchieben(e.localPosition - vorher, g);
      case _Geste.verschieben:
        _verschieben(e.localPosition - vorher, g);
      case _Geste.zweiFinger || _Geste.scrollen || _Geste.zoomen:
        if (_finger.length < 2) return;
        final mitte = _mitte(), abstand = _abstand();
        if (_geste == _Geste.zweiFinger) {
          if ((abstand - _startAbstand).abs() > 24) {
            _geste = _Geste.zoomen;
          } else if ((mitte - _startMitte).distance > _ruhe) {
            _geste = _Geste.scrollen;
            _letzteMitte = mitte;
          }
        }
        if (_geste == _Geste.zoomen && _startAbstand > 0) {
          final z = (_startZoom * abstand / _startAbstand).clamp(1.0, 5.0);
          // Die Stelle unter den Fingern bleibt unter den Fingern.
          setState(() {
            _zoom = z;
            _versatz = _begrenzt(mitte - (_startMitte - _startVersatz) * (z / _startZoom), g);
          });
        } else if (_geste == _Geste.scrollen) {
          _scrollRest -= (mitte - _letzteMitte).dy;
          _letzteMitte = mitte;
          final n = (_scrollRest / _schrittPx).truncate();
          if (n != 0) {
            _scrollRest -= n * _schrittPx;
            if (_touchpad) {
              _hin(_zeiger);
            } else {
              final p = _gast(_startMitte, g);
              if (p != null) _hin(p);
            }
            _radSchritte(n);
          }
        }
      case _Geste.keine || _Geste.fertig:
        break;
    }
  }

  void _fingerHoch(PointerEvent e, Size g) {
    if (!_finger.containsKey(e.pointer)) return;
    _finger.remove(e.pointer);
    final abgebrochen = e is PointerCancelEvent;
    switch (_geste) {
      case _Geste.wartet:
        _langTimer?.cancel();
        if (!abgebrochen) _tippen(g, e.timeStamp);
      case _Geste.ziehen:
        final p = _gast(e.localPosition, g);
        if (p != null && !abgebrochen) _hin(p);
        _tastenSetzen(0);
      case _Geste.zweiFinger:
        // Kurz mit zwei Fingern getippt: Rechtsklick (wie am Touchpad)
        if (!abgebrochen && e.timeStamp - _fingerZeit < const Duration(milliseconds: 300)) {
          final p = _touchpad ? _zeiger : _gast(_startMitte, g);
          if (p != null) {
            HapticFeedback.mediumImpact();
            _klick(p, 4);
          }
        }
      default:
        break;
    }
    // Ein Finger von zweien weg: Rest der Geste nicht als neue werten.
    _geste = _finger.isEmpty ? _Geste.keine : _Geste.fertig;
  }

  void _tippen(Size g, Duration zeit) {
    var p = _touchpad ? _zeiger : _gast(_fingerStart, g);
    if (p == null) return;
    final l = _letzterTipp;
    if (l != null &&
        zeit - _letzterTippZeit < _doppeltippZeit &&
        (_widget(l, g) - _widget(p, g)).distance < _doppeltippWeg) {
      p = l; // Doppeltipp: dieselbe Stelle, damit der Gast einen Doppelklick sieht
      _letzterTipp = null;
    } else {
      _letzterTipp = p;
    }
    _letzterTippZeit = zeit;
    _klick(p, 1);
  }

  void _zeigerSchieben(Offset delta, Size g) {
    if (_breite == 0) return;
    // Der Zeiger folgt dem Finger auf dem Bildschirm (1:1 im Bild).
    final s = _einpassung(g).s * _zoom;
    final d = delta / s;
    final neu = Offset((_zeiger.dx + d.dx).clamp(0, _breite - 1).toDouble(), (_zeiger.dy + d.dy).clamp(0, _hoehe - 1).toDouble());
    if (!_absolut) _spice.mausBewegung((neu.dx - _zeiger.dx).round(), (neu.dy - _zeiger.dy).round(), _tasten);
    setState(() => _zeiger = neu);
    _hin(neu);
    // Vergroessert: das Bild laeuft mit, wenn der Zeiger an den Rand kommt.
    if (_zoom > 1.01) {
      final w = _widget(neu, g);
      var v = Offset.zero;
      if (w.dx < 24) v += Offset(24 - w.dx, 0);
      if (w.dx > g.width - 24) v -= Offset(w.dx - g.width + 24, 0);
      if (w.dy < 24) v += Offset(0, 24 - w.dy);
      if (w.dy > g.height - 24) v -= Offset(0, w.dy - g.height + 24);
      if (v != Offset.zero) _verschieben(v, g);
    }
  }

  void _verschieben(Offset delta, Size g) => setState(() => _versatz = _begrenzt(_versatz + delta, g));

  /// Das vergroesserte Bild deckt die Flaeche immer ganz (kein Rand ins Leere).
  Offset _begrenzt(Offset v, Size g) => Offset(
        v.dx.clamp(g.width * (1 - _zoom), 0).toDouble(),
        v.dy.clamp(g.height * (1 - _zoom), 0).toDouble(),
      );

  void _zoomZurueck() => setState(() {
        _zoom = 1;
        _versatz = Offset.zero;
      });

  void _bedienungGeaendert() {
    if (mounted) setState(() {});
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
          if (g != _flaeche) {
            // Flaeche anders (Drehen, Tastatur): Zoom behalten, aber im Rahmen.
            _flaeche = g;
            _versatz = _begrenzt(_versatz, g);
          }
          final zeigerDa = _touchpad && bild != null && _breite > 0;
          return Listener(
            onPointerHover: (e) => _bewegen(e, g),
            onPointerMove: (e) => _bewegen(e, g),
            onPointerDown: (e) => _taste(e, g, true),
            onPointerUp: (e) => _taste(e, g, false),
            onPointerCancel: (e) {
              if (e.kind == PointerDeviceKind.touch) _fingerHoch(e, g);
            },
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
                    : Stack(
                        fit: StackFit.expand,
                        children: [
                          ClipRect(
                            child: Transform(
                              transform: Matrix4.translationValues(_versatz.dx, _versatz.dy, 0) *
                                  Matrix4.diagonal3Values(_zoom, _zoom, 1),
                              child: RawImage(
                                image: bild,
                                fit: BoxFit.contain,
                                filterQuality: _zoom > 1.5 ? FilterQuality.none : FilterQuality.medium,
                              ),
                            ),
                          ),
                          if (zeigerDa)
                            Positioned(
                              left: _widget(_zeiger, g).dx,
                              top: _widget(_zeiger, g).dy,
                              child: const IgnorePointer(
                                child: CustomPaint(key: ValueKey('touchpad-zeiger'), size: Size(18, 26), painter: _Zeiger()),
                              ),
                            ),
                          if (_zoom > 1.01)
                            Positioned(
                              right: 8,
                              top: 8,
                              child: ActionChip(
                                key: const ValueKey('zoom-zurueck'),
                                avatar: const Icon(Icons.zoom_out_map, size: 18),
                                label: Text('${(_zoom * 100).round()} %'),
                                tooltip: 'Ganzes Bild zeigen',
                                onPressed: _zoomZurueck,
                              ),
                            ),
                        ],
                      ),
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _langTimer?.cancel();
    _bedienung.removeListener(_bedienungGeaendert);
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

enum _Geste { keine, wartet, ziehen, zeiger, verschieben, zweiFinger, scrollen, zoomen, fertig }

/// Mauszeiger im Touchpad-Modus: Pfeil mit Spitze oben links.
class _Zeiger extends CustomPainter {
  const _Zeiger();
  @override
  void paint(Canvas canvas, Size size) {
    final p = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 20)
      ..lineTo(5, 15)
      ..lineTo(9, 24)
      ..lineTo(12.5, 22.5)
      ..lineTo(8.5, 14)
      ..lineTo(15, 14)
      ..close();
    canvas.drawPath(p, Paint()..color = Colors.white);
    canvas.drawPath(p, Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);
  }

  @override
  bool shouldRepaint(_Zeiger old) => false;
}
