// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'app_zustand.dart';
import 'native/rwtunnel.dart';
import 'oberflaeche/start_seite.dart';
import 'protokoll.dart';

/// Fehler, die nirgends aufgefangen wurden, landen hier: in der Logdatei und
/// sichtbar in der App (Phase.fehler). Nie still beenden.
void Function(Object fehler, StackTrace stapel)? unerwartet;

void main() {
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      Protokoll.schreiben('Start (${kDebugMode ? 'Debug' : 'Release'})');
      // Go-Laufzeit: nicht aufgefangene panics zusaetzlich in die Logdatei.
      final p = Protokoll.pfad;
      if (p != null) {
        try {
          RwTunnel.i.absturzdatei(p);
        } catch (e, s) {
          Protokoll.schreiben('librwtunnel nicht geladen', e, s);
        }
      }
      FlutterError.onError = (d) {
        FlutterError.presentError(d);
        Protokoll.schreiben('Flutter-Fehler', d.exception, d.stack);
      };
      PlatformDispatcher.instance.onError = (e, s) {
        Protokoll.schreiben('Unerwarteter Fehler', e, s);
        unerwartet?.call(e, s);
        return true; // behandelt: App laeuft weiter
      };
      runApp(const RosenwegVm());
    },
    (e, s) {
      Protokoll.schreiben('Unerwarteter Fehler', e, s);
      unerwartet?.call(e, s);
    },
  );
}

class RosenwegVm extends StatefulWidget {
  const RosenwegVm({super.key});

  @override
  State<RosenwegVm> createState() => _RosenwegVmState();
}

class _RosenwegVmState extends State<RosenwegVm> {
  final _zustand = AppZustand();
  late final AppLifecycleListener _lebenslauf;

  @override
  void initState() {
    super.initState();
    unerwartet = (e, _) => _zustand.unerwartet(e);
    _zustand.starten();
    // Beim Schliessen (Desktop: Fenster zu, Cmd+Q) den Tunnel-Peer abmelden,
    // damit der Schluessel sofort ungueltig ist. Hoechstens 3 Sekunden — eine
    // haengende Verbindung soll das Schliessen nicht aufhalten; dann raeumt
    // der Gateway nach wenigen Minuten ohne Lebenszeichen selbst auf.
    _lebenslauf = AppLifecycleListener(
      onExitRequested: () async {
        Protokoll.schreiben('Beenden angefordert (Fenster zu / Cmd+Q)');
        await _zustand.schliessen().timeout(const Duration(seconds: 3), onTimeout: () {});
        return AppExitResponse.exit;
      },
      // Telefone beenden Apps oft ohne Rueckfrage; dort zaehlt "abgetrennt".
      onDetach: () => _zustand.schliessen(),
    );
  }

  @override
  void dispose() {
    _lebenslauf.dispose();
    _zustand.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Rosenweg Virtuelle Computer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF8B1E3F), useMaterial3: true),
      darkTheme: ThemeData(colorSchemeSeed: const Color(0xFF8B1E3F), brightness: Brightness.dark, useMaterial3: true),
      home: StartSeite(zustand: _zustand),
    );
  }
}
