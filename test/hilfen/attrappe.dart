// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ffi';

import 'package:rosenweg_vm/native/rwspice.dart';
import 'package:rosenweg_vm/spice/spice_ziel.dart';

/// SPICE-Ziel fuer Tests: schreibt jede Eingabe mit.
class AttrappeZiel implements SpiceZiel {
  final ereignisseC = StreamController<SpiceEreignis>.broadcast();
  final tasten = <(int, bool)>[];
  final maus = <String>[];
  final groessen = <(int, int)>[];

  @override
  Stream<SpiceEreignis> get ereignisse => ereignisseC.stream;

  void melden(SpiceEreignisArt art, [int a = 0, int b = 0]) => ereignisseC.add(SpiceEreignis(art, a, b));

  @override
  int bildAbholen(Pointer<Uint8> ziel, int bytes, Pointer<Int32> breite, Pointer<Int32> hoehe) => 0;

  @override
  void mausPosition(int x, int y, int tasten) => maus.add('pos $x,$y');
  @override
  void mausBewegung(int dx, int dy, int tasten) => maus.add('bew $dx,$dy');
  @override
  void mausTaste(int taste, int gedrueckt, int tasten) => maus.add('taste $taste ${gedrueckt == 1 ? 'ab' : 'auf'}');
  @override
  void taste(int scancode, int gedrueckt) => tasten.add((scancode, gedrueckt == 1));
  @override
  void feststellAus() {}
  @override
  void bildschirmGroesse(int breite, int hoehe) => groessen.add((breite, hoehe));

  /// Nur die Tastendruecke (ohne Loslassen), lesbarer in Erwartungen.
  List<int> get gedrueckt => [for (final t in tasten) if (t.$2) t.$1];

  void leeren() {
    tasten.clear();
    maus.clear();
  }
}
