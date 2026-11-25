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

  @override
  void initState() {
    super.initState();
    _zustand.starten();
  }

  @override
  void dispose() {
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
