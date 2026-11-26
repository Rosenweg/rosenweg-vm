#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Erzeugt lib/spice/belegungen.g.dart aus xkeyboard-config.

Fuer jede Gastbelegung: welches Zeichen mit welcher Taste (PC-Scancode
Satz 1) und welchen Umschaltern (keine, Shift, AltGr, Shift+AltGr) entsteht,
dazu Zeichen ueber Tottasten (Compose-Tabelle: Tottaste, dann Grundzeichen).

Quellen (MacPorts: xkeyboard-config, libxkbcommon/xkbcli, xorg-libX11):
  xkbcli compile-keymap   loest Includes und Varianten auf
  X11/keysymdef.h         Keysym-Name -> Unicode
  X11/locale/en_US.UTF-8/Compose   Tottasten-Folgen

Aufruf (im Repo): python3 tool/belegungen_erzeugen.py [--prefix /opt/local]
"""
import argparse
import os
import re
import subprocess
import sys

# Gastbelegungen: (xkb-Layout, Variante, Anzeigename). Reihenfolge = Liste in der App.
BELEGUNGEN = [
    ("ch", "", "Schweiz (Deutsch)"),
    ("ch", "fr", "Schweiz (Französisch)"),
    ("de", "", "Deutschland"),
    ("de", "nodeadkeys", "Deutschland (ohne Tottasten)"),
    ("at", "", "Österreich"),
    ("at", "nodeadkeys", "Österreich (ohne Tottasten)"),
    ("fr", "", "Frankreich (AZERTY)"),
    ("fr", "oss", "Frankreich (alternativ)"),
    ("be", "", "Belgien"),
    ("it", "", "Italien"),
    ("es", "", "Spanien"),
    ("pt", "", "Portugal"),
    ("us", "", "USA"),
    ("us", "intl", "USA (international, Tottasten)"),
    ("us", "altgr-intl", "USA (international, AltGr)"),
    ("gb", "", "Grossbritannien"),
    ("ie", "", "Irland"),
    ("nl", "", "Niederlande"),
    ("se", "", "Schweden"),
    ("no", "", "Norwegen"),
    ("dk", "", "Dänemark"),
    ("fi", "", "Finnland"),
    ("is", "", "Island"),
    ("ee", "", "Estland"),
    ("lv", "", "Lettland"),
    ("lt", "", "Litauen"),
    ("pl", "", "Polen"),
    ("cz", "", "Tschechien"),
    ("sk", "", "Slowakei"),
    ("hu", "", "Ungarn"),
    ("si", "", "Slowenien"),
    ("hr", "", "Kroatien"),
    ("ro", "std", "Rumänien"),
    ("tr", "", "Türkei"),
    ("ca", "fr", "Kanada (Französisch)"),
    ("latam", "", "Lateinamerika"),
    ("br", "", "Brasilien"),
]

# Tasten des Schreibblocks. Fuer sie ist der Linux-Tastencode (evdev - 8)
# gleich dem PC-Scancode Satz 1 (ohne E0).
TASTEN = (["TLDE"] + [f"AE{i:02d}" for i in range(1, 13)] + [f"AD{i:02d}" for i in range(1, 13)]
          + [f"AC{i:02d}" for i in range(1, 13)] + ["BKSL", "LSGT"]
          + [f"AB{i:02d}" for i in range(1, 11)] + ["SPCE"])


def keysym_tabelle(prefix):
    t = {}
    with open(os.path.join(prefix, "include/X11/keysymdef.h"), encoding="utf-8", errors="replace") as f:
        for z in f:
            m = re.match(r"#define XK_(\w+)\s+0x[0-9a-fA-F]+\s*/\*[ (]*U\+([0-9A-Fa-f]{4,6})", z)
            if m:
                t.setdefault(m.group(1), chr(int(m.group(2), 16)))
    return t


def zeichen(sym, ks):
    if sym in ks:
        return ks[sym]
    m = re.fullmatch(r"U([0-9A-Fa-f]{4,6})", sym)
    if m:
        return chr(int(m.group(1), 16))
    return None


def compose_tabelle(prefix):
    """(tottaste, grund-keysym) -> zeichen"""
    t = {}
    with open(os.path.join(prefix, "share/X11/locale/en_US.UTF-8/Compose"), encoding="utf-8") as f:
        for z in f:
            m = re.match(r'\s*<(dead_\w+)>\s*<(\w+)>\s*:\s*"((?:[^"\\]|\\.)+)"', z)
            if m:
                w = m.group(3).encode().decode("unicode_escape").encode("latin-1").decode("utf-8") \
                    if "\\" in m.group(3) else m.group(3)
                if len(w) == 1:
                    t.setdefault((m.group(1), m.group(2)), w)
    return t


def keymap(layout, variante):
    r = subprocess.run(["xkbcli", "compile-keymap", "--layout", layout, "--variant", variante,
                        "--options", ""], capture_output=True, text=True)
    if r.returncode != 0 or "xkb_symbols" not in r.stdout:
        raise RuntimeError(f"{layout}({variante}): {r.stderr.strip()[:200]}")
    text = r.stdout
    codes = {m.group(1): int(m.group(2)) for m in re.finditer(r"<(\w+)>\s*=\s*(\d+);", text)}
    sym = text[text.index("xkb_symbols"):]
    tasten = {}
    for m in re.finditer(r"key <(\w+)>\s*\{(.*?)\};", sym, re.S):
        inhalt = m.group(2)
        # Mehrzeilig: "symbols[1]= [ ... ]" (nicht das "[1]" erwischen),
        # einzeilig: "{ [ ... ] }".
        g = re.search(r"symbols\[\w+\]\s*=\s*\[([^\]]*)\]", inhalt) or re.match(r"\s*\[([^\]]*)\]", inhalt)
        if g:
            tasten[m.group(1)] = [s.strip() for s in g.group(1).split(",")]
    return codes, tasten


def belegung(layout, variante, ks, comp):
    codes, tasten = keymap(layout, variante)
    mit_altgr = "ISO_Level3_Shift" in tasten.get("RALT", [])
    stufen = 4 if mit_altgr else 2
    direkt = {}   # zeichen -> (sc, stufe)
    tot = {}      # dead_x -> (sc, stufe)
    for stufe in range(stufen):
        for name in TASTEN:
            syms = tasten.get(name)
            if not syms or stufe >= len(syms) or name not in codes:
                continue
            sc = codes[name] - 8
            s = syms[stufe]
            if s.startswith("dead_"):
                tot.setdefault(s, (sc, stufe))
                continue
            c = zeichen(s, ks)
            if c and c not in direkt:
                direkt[c] = [(sc, stufe)]
    # Grund-Keysym-Namen der direkt erreichbaren Zeichen (fuer Compose)
    grund = {}
    for stufe in range(stufen):
        for name in TASTEN:
            syms = tasten.get(name)
            if syms and stufe < len(syms) and not syms[stufe].startswith("dead_"):
                grund.setdefault(syms[stufe], None)
    folgen = dict(direkt)
    for (d, g), c in sorted(comp.items()):
        if d in tot and g in grund and c not in folgen:
            gz = zeichen(g, ks)
            if gz and gz in direkt:
                folgen[c] = [tot[d]] + direkt[gz]
    return folgen, mit_altgr


def dart_text(s):
    return "'" + s.replace("\\", "\\\\").replace("'", "\\'").replace("$", "\\$") + "'"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="/opt/local")
    ap.add_argument("--aus", default=os.path.join(os.path.dirname(__file__), "..", "lib", "spice", "belegungen.g.dart"))
    a = ap.parse_args()
    ks = keysym_tabelle(a.prefix)
    comp = compose_tabelle(a.prefix)
    zeilen = [
        "// SPDX-License-Identifier: GPL-3.0-or-later",
        "// ERZEUGT von tool/belegungen_erzeugen.py aus xkeyboard-config — nicht von Hand aendern.",
        "// Je Belegung: Unicode-Zeichen -> Tastenfolge; ein Schritt = Scancode | (Stufe << 9),",
        "// Stufe 0 ohne, 1 Shift, 2 AltGr, 3 Shift+AltGr. Mehrere Schritte = Tottaste + Grundzeichen.",
        "// ignore_for_file: lines_longer_than_80_chars",
        "",
        "part of 'belegungen.dart';",
        "",
        "const _erzeugt = <GastBelegung>[",
    ]
    for layout, variante, name in BELEGUNGEN:
        try:
            folgen, altgr = belegung(layout, variante, ks, comp)
        except RuntimeError as e:
            print("uebersprungen:", e, file=sys.stderr)
            continue
        kennung = layout + (f"({variante})" if variante else "")
        eintraege = ", ".join(
            f"{ord(c)}: [{', '.join(str(sc | (st << 9)) for sc, st in f)}]" for c, f in sorted(folgen.items()))
        zeilen.append(f"  GastBelegung({dart_text(kennung)}, {dart_text(name)}, {{{eintraege}}}),")
        print(f"{kennung:18} {len(folgen):4} Zeichen{' (AltGr)' if altgr else ''}", file=sys.stderr)
    zeilen.append("];")
    with open(a.aus, "w", encoding="utf-8") as f:
        f.write("\n".join(zeilen) + "\n")


if __name__ == "__main__":
    main()
