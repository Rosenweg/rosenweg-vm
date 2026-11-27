// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/services.dart';

/// USB-HID-Nutzungen (wie Flutter sie in PhysicalKeyboardKey liefert) auf
/// PC-Scancodes Satz 1, wie SPICE sie erwartet; E0-Tasten als 0x100 | code.
///
/// Gebraucht im Modus "Tasten direkt" und fuer Tasten ohne Zeichen
/// (Pfeile, F-Tasten, Enter …). Druckbare Zeichen uebersetzt sonst
/// tastatur.dart aus dem getippten Zeichen.
///
/// [macIsoTausch]: macOS meldet auf ISO-Tastaturen die Taste links oben (§)
/// als 0x64 und die Taste neben der linken Umschalttaste (<) als 0x35 —
/// umgekehrt wie ein PC. [cmdAlsStrg]: Cmd (GUI) als Strg senden.
int? scancode(PhysicalKeyboardKey k, {bool macIsoTausch = false, bool cmdAlsStrg = false}) {
  final hid = k.usbHidUsage;
  if ((hid >> 16) != 0x07) return null;
  var u = hid & 0xFFFF;
  if (macIsoTausch && (u == 0x35 || u == 0x64)) u = u == 0x35 ? 0x64 : 0x35;
  if (cmdAlsStrg && u == 0xe3) return 0x1d;
  if (cmdAlsStrg && u == 0xe7) return 0x11d;
  return _tabelle[u];
}

/// Umschalter (HID 0xe0–0xe7).
bool istUmschalter(PhysicalKeyboardKey k) {
  final u = k.usbHidUsage;
  return (u >> 16) == 0x07 && (u & 0xFFFF) >= 0xe0 && (u & 0xFFFF) <= 0xe7;
}

/// Tasten, die auch im Zeichenmodus physisch gehen (kein Text): Enter, Esc,
/// Rueckschritt, Tab, F-Tasten, Druck/Rollen/Pause,
/// Einfg/Pos1/BildAuf/Entf/Ende/BildAb, Pfeile, Num-Taste, Ziffernblock-
/// Enter, Kontextmenue.
bool istSteuertaste(PhysicalKeyboardKey k) {
  final hid = k.usbHidUsage;
  if ((hid >> 16) != 0x07) return false;
  final u = hid & 0xFFFF;
  return (u >= 0x28 && u <= 0x2b) || (u >= 0x3a && u <= 0x53) || u == 0x58 || u == 0x65;
}

/// Taste ohne Scancode (scanCode 0): Bildschirmtastaturen, `adb shell input`
/// und manche Bluetooth-Tastaturen melden dann nur die LOGISCHE Taste; Flutter
/// liefert einen physicalKey ausserhalb der HID-Seite 0x07. Fuer alles, was
/// keinen Text ergibt (Rueckschritt, Enter, Pfeile, F-Tasten, Umschalter …),
/// gilt dann die Stelle dieser Taste auf einer PC-Tastatur.
int? scancodeLogisch(LogicalKeyboardKey k) => _logisch[k.keyId];

/// Scancode fuer ein Tastenereignis: zuerst die physische Taste, ohne sie
/// die logische (siehe [scancodeLogisch]).
int? tastenScancode(KeyEvent e, {bool macIsoTausch = false, bool cmdAlsStrg = false}) {
  if (_hid(e.physicalKey)) return scancode(e.physicalKey, macIsoTausch: macIsoTausch, cmdAlsStrg: cmdAlsStrg);
  final sc = scancodeLogisch(e.logicalKey);
  if (cmdAlsStrg && sc == 0x15b) return 0x1d;
  if (cmdAlsStrg && sc == 0x15c) return 0x11d;
  return sc;
}

/// [istSteuertaste] fuer ein Ereignis, auch ohne Scancode.
bool istSteuertasteEreignis(KeyEvent e) =>
    _hid(e.physicalKey) ? istSteuertaste(e.physicalKey) : _logischSteuer.contains(e.logicalKey.keyId);

/// [istUmschalter] fuer ein Ereignis, auch ohne Scancode.
bool istUmschalterEreignis(KeyEvent e) =>
    _hid(e.physicalKey) ? istUmschalter(e.physicalKey) : _logischUmschalter.contains(e.logicalKey.keyId);

bool _hid(PhysicalKeyboardKey k) => (k.usbHidUsage >> 16) == 0x07 && _tabelle.containsKey(k.usbHidUsage & 0xFFFF);

final _logischUmschalter = {
  for (final k in [
    LogicalKeyboardKey.controlLeft,
    LogicalKeyboardKey.controlRight,
    LogicalKeyboardKey.shiftLeft,
    LogicalKeyboardKey.shiftRight,
    LogicalKeyboardKey.altLeft,
    LogicalKeyboardKey.altRight,
    LogicalKeyboardKey.metaLeft,
    LogicalKeyboardKey.metaRight,
    LogicalKeyboardKey.control,
    LogicalKeyboardKey.shift,
    LogicalKeyboardKey.alt,
    LogicalKeyboardKey.meta,
    LogicalKeyboardKey.altGraph,
  ])
    k.keyId,
};

final _logischSteuer = {
  for (final k in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.numpadEnter,
    LogicalKeyboardKey.escape,
    LogicalKeyboardKey.backspace,
    LogicalKeyboardKey.tab,
    LogicalKeyboardKey.delete,
    LogicalKeyboardKey.insert,
    LogicalKeyboardKey.home,
    LogicalKeyboardKey.end,
    LogicalKeyboardKey.pageUp,
    LogicalKeyboardKey.pageDown,
    LogicalKeyboardKey.arrowLeft,
    LogicalKeyboardKey.arrowRight,
    LogicalKeyboardKey.arrowUp,
    LogicalKeyboardKey.arrowDown,
    LogicalKeyboardKey.contextMenu,
    LogicalKeyboardKey.printScreen,
    LogicalKeyboardKey.scrollLock,
    LogicalKeyboardKey.numLock,
    LogicalKeyboardKey.f1,
    LogicalKeyboardKey.f2,
    LogicalKeyboardKey.f3,
    LogicalKeyboardKey.f4,
    LogicalKeyboardKey.f5,
    LogicalKeyboardKey.f6,
    LogicalKeyboardKey.f7,
    LogicalKeyboardKey.f8,
    LogicalKeyboardKey.f9,
    LogicalKeyboardKey.f10,
    LogicalKeyboardKey.f11,
    LogicalKeyboardKey.f12,
  ])
    k.keyId,
};

final _logisch = <int, int>{
  LogicalKeyboardKey.enter.keyId: 0x1c,
  LogicalKeyboardKey.numpadEnter.keyId: 0x11c,
  LogicalKeyboardKey.escape.keyId: 0x01,
  LogicalKeyboardKey.backspace.keyId: 0x0e,
  LogicalKeyboardKey.tab.keyId: 0x0f,
  LogicalKeyboardKey.space.keyId: 0x39,
  LogicalKeyboardKey.capsLock.keyId: 0x3a,
  LogicalKeyboardKey.f1.keyId: 0x3b,
  LogicalKeyboardKey.f2.keyId: 0x3c,
  LogicalKeyboardKey.f3.keyId: 0x3d,
  LogicalKeyboardKey.f4.keyId: 0x3e,
  LogicalKeyboardKey.f5.keyId: 0x3f,
  LogicalKeyboardKey.f6.keyId: 0x40,
  LogicalKeyboardKey.f7.keyId: 0x41,
  LogicalKeyboardKey.f8.keyId: 0x42,
  LogicalKeyboardKey.f9.keyId: 0x43,
  LogicalKeyboardKey.f10.keyId: 0x44,
  LogicalKeyboardKey.f11.keyId: 0x57,
  LogicalKeyboardKey.f12.keyId: 0x58,
  LogicalKeyboardKey.printScreen.keyId: 0x137,
  LogicalKeyboardKey.scrollLock.keyId: 0x46,
  LogicalKeyboardKey.numLock.keyId: 0x45,
  LogicalKeyboardKey.insert.keyId: 0x152,
  LogicalKeyboardKey.home.keyId: 0x147,
  LogicalKeyboardKey.pageUp.keyId: 0x149,
  LogicalKeyboardKey.delete.keyId: 0x153,
  LogicalKeyboardKey.end.keyId: 0x14f,
  LogicalKeyboardKey.pageDown.keyId: 0x151,
  LogicalKeyboardKey.arrowRight.keyId: 0x14d,
  LogicalKeyboardKey.arrowLeft.keyId: 0x14b,
  LogicalKeyboardKey.arrowDown.keyId: 0x150,
  LogicalKeyboardKey.arrowUp.keyId: 0x148,
  LogicalKeyboardKey.contextMenu.keyId: 0x15d,
  LogicalKeyboardKey.controlLeft.keyId: 0x1d,
  LogicalKeyboardKey.control.keyId: 0x1d,
  LogicalKeyboardKey.controlRight.keyId: 0x11d,
  LogicalKeyboardKey.shiftLeft.keyId: 0x2a,
  LogicalKeyboardKey.shift.keyId: 0x2a,
  LogicalKeyboardKey.shiftRight.keyId: 0x36,
  LogicalKeyboardKey.altLeft.keyId: 0x38,
  LogicalKeyboardKey.alt.keyId: 0x38,
  LogicalKeyboardKey.altRight.keyId: 0x138,
  LogicalKeyboardKey.altGraph.keyId: 0x138,
  LogicalKeyboardKey.metaLeft.keyId: 0x15b,
  LogicalKeyboardKey.meta.keyId: 0x15b,
  LogicalKeyboardKey.metaRight.keyId: 0x15c,
};

const _tabelle = <int, int>{
  // Buchstaben a–z
  0x04: 0x1e, 0x05: 0x30, 0x06: 0x2e, 0x07: 0x20, 0x08: 0x12, 0x09: 0x21, 0x0a: 0x22,
  0x0b: 0x23, 0x0c: 0x17, 0x0d: 0x24, 0x0e: 0x25, 0x0f: 0x26, 0x10: 0x32, 0x11: 0x31,
  0x12: 0x18, 0x13: 0x19, 0x14: 0x10, 0x15: 0x13, 0x16: 0x1f, 0x17: 0x14, 0x18: 0x16,
  0x19: 0x2f, 0x1a: 0x11, 0x1b: 0x2d, 0x1c: 0x15, 0x1d: 0x2c,
  // Ziffern 1–0
  0x1e: 0x02, 0x1f: 0x03, 0x20: 0x04, 0x21: 0x05, 0x22: 0x06, 0x23: 0x07, 0x24: 0x08,
  0x25: 0x09, 0x26: 0x0a, 0x27: 0x0b,
  // Enter, Esc, Rueckschritt, Tab, Leertaste
  0x28: 0x1c, 0x29: 0x01, 0x2a: 0x0e, 0x2b: 0x0f, 0x2c: 0x39,
  // - = [ ] \ (#) ; ' ` , . /
  0x2d: 0x0c, 0x2e: 0x0d, 0x2f: 0x1a, 0x30: 0x1b, 0x31: 0x2b, 0x32: 0x2b, 0x33: 0x27,
  0x34: 0x28, 0x35: 0x29, 0x36: 0x33, 0x37: 0x34, 0x38: 0x35,
  // Feststell, F1–F12
  0x39: 0x3a, 0x3a: 0x3b, 0x3b: 0x3c, 0x3c: 0x3d, 0x3d: 0x3e, 0x3e: 0x3f, 0x3f: 0x40,
  0x40: 0x41, 0x41: 0x42, 0x42: 0x43, 0x43: 0x44, 0x44: 0x57, 0x45: 0x58,
  // Druck, Rollen
  // Pause ist eine E1-Folge, die SPICE so nicht kennt; bewusst weg (0x45
  // waere die Num-Taste).
  0x46: 0x137, 0x47: 0x46,
  // Einfg, Pos1, BildAuf, Entf, Ende, BildAb, Pfeile
  0x49: 0x152, 0x4a: 0x147, 0x4b: 0x149, 0x4c: 0x153, 0x4d: 0x14f, 0x4e: 0x151,
  0x4f: 0x14d, 0x50: 0x14b, 0x51: 0x150, 0x52: 0x148,
  // Ziffernblock
  0x53: 0x45, 0x54: 0x135, 0x55: 0x37, 0x56: 0x4a, 0x57: 0x4e, 0x58: 0x11c,
  0x59: 0x4f, 0x5a: 0x50, 0x5b: 0x51, 0x5c: 0x4b, 0x5d: 0x4c, 0x5e: 0x4d,
  0x5f: 0x47, 0x60: 0x48, 0x61: 0x49, 0x62: 0x52, 0x63: 0x53,
  // < > neben der linken Umschalttaste (CH/DE-Tastaturen), Kontextmenue
  0x64: 0x56, 0x65: 0x15d,
  // Modifikatoren
  0xe0: 0x1d, 0xe1: 0x2a, 0xe2: 0x38, 0xe3: 0x15b,
  0xe4: 0x11d, 0xe5: 0x36, 0xe6: 0x138, 0xe7: 0x15c,
};

/// Strg+Alt+Entf — fuer Windows-Gaeste, die damit die Anmeldung verlangen.
/// Das eigene System faengt die Kombination sonst selbst ab.
const strgAltEntf = [0x1d, 0x38, 0x153];
