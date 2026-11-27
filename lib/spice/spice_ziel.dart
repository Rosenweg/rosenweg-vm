// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';

import '../native/rwspice.dart';

/// Wohin der Bildschirm Eingaben schickt und woher er Bild und Ereignisse
/// bekommt. In der App ist das [RwSpice] (librwspice); Tests geben eine
/// Attrappe, die nur mitschreibt.
abstract interface class SpiceZiel {
  Stream<SpiceEreignis> get ereignisse;

  /// Siehe rw_spice_bild_abholen: 1 = neues Bild, 0 = unveraendert, -1 = keins.
  int bildAbholen(Pointer<Uint8> ziel, int bytes, Pointer<Int32> breite, Pointer<Int32> hoehe);

  void mausPosition(int x, int y, int tasten);
  void mausBewegung(int dx, int dy, int tasten);

  /// [taste] 1 links, 2 mitte, 3 rechts, 4 Rad hoch, 5 Rad runter.
  void mausTaste(int taste, int gedrueckt, int tasten);

  /// PC-Scancode Satz 1, E0-Tasten als 0x100 | code.
  void taste(int scancode, int gedrueckt);
  void feststellAus();

  /// Bitte an den Gast, diese Aufloesung zu nehmen (nur mit spice-vdagent).
  void bildschirmGroesse(int breite, int hoehe);
}
