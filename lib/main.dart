// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ui' show AppExitResponse;

import 'package:flutter/material.dart';

import 'app_zustand.dart';
import 'oberflaeche/start_seite.dart';

void main() {
  runApp(const RosenwegVm());
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
    _zustand.starten();
    // Beim Schliessen (Desktop: Fenster zu, Cmd+Q) den Tunnel-Peer abmelden,
    // damit der Schluessel sofort ungueltig ist. Hoechstens 3 Sekunden — eine
    // haengende Verbindung soll das Schliessen nicht aufhalten; dann raeumt
    // der Gateway nach wenigen Minuten ohne Lebenszeichen selbst auf.
    _lebenslauf = AppLifecycleListener(
      onExitRequested: () async {
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
