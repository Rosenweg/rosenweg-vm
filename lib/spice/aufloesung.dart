// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui';

/// Aufloesung, um die die App den Gast bittet (VDAgent MonitorsConfig), aus
/// der Flaeche fuer das Bild in logischen Pixeln und der Pixeldichte.
///
/// Logische Pixel 1:1 waeren auf dem Handy zu wenig (412 px breit kann kaum
/// ein Desktop), Geraetepixel zu fein (Schrift winzig). Darum: die kurze
/// Seite mindestens 720 Pixel, aber nie feiner als das Geraet selbst. Am
/// Rechner ergibt das das Fenster in logischen Pixeln. Breite in
/// Achterschritten (QXL), Hoehe gerade; unter 640x480 nichts.
Size? gastAufloesung(Size logisch, double pixeldichte) {
  if (logisch.width <= 0 || logisch.height <= 0) return null;
  final kurz = math.min(logisch.width, logisch.height);
  final f = math.min(math.max(1.0, 720 / kurz), math.max(1.0, pixeldichte));
  final b = (logisch.width * f).floor() & ~7, h = (logisch.height * f).floor() & ~1;
  if (math.max(b, h) < 640 || math.min(b, h) < 480) return null;
  return Size(b.toDouble(), h.toDouble());
}
