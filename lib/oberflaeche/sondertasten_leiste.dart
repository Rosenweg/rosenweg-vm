// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../spice/bildschirm.dart';
import '../spice/bildschirm_tastatur.dart';
import '../spice/scancodes.dart';

/// Tasten, die eine Bildschirmtastatur nicht hat: Umschalter (gelten fuer den
/// naechsten Tastendruck, leuchten solange), Esc, Tab, Pfeile, Pos1/Ende,
/// Bild auf/ab, Rueckschritt, Entf, F1–F12, Strg+Alt+Entf. Eine Zeile, seitlich
/// verschiebbar; Pfeile und Rueckschritt wiederholen beim Halten.
class SondertastenLeiste extends StatelessWidget {
  const SondertastenLeiste({super.key, required this.steuerung});
  final BildschirmSteuerung steuerung;

  @override
  Widget build(BuildContext context) {
    final f = Theme.of(context).colorScheme;
    return ListenableBuilder(
      listenable: steuerung,
      builder: (context, _) => Material(
        color: f.surfaceContainerHigh,
        child: SafeArea(
          top: false,
          child: SizedBox(
            height: 48,
            child: ListView(
              key: const ValueKey('sondertasten'),
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              children: [
                for (final u in Umschalter.values)
                  _Taste(
                    key: ValueKey('umschalter-${u.name}'),
                    text: u.anzeige,
                    hilfe: u == Umschalter.shift ? 'Umschalt' : u.anzeige,
                    aktiv: steuerung.gehalten.contains(u),
                    onTap: () => steuerung.umschalten(u),
                  ),
                const _Trenner(),
                for (final t in sondertasten)
                  _Taste(
                    key: ValueKey('taste-${t.name}'),
                    text: t.name,
                    hilfe: t.hilfe ?? t.name,
                    wiederholen: const {0x14b, 0x148, 0x150, 0x14d, 0x0e, 0x153}.contains(t.sc),
                    onTap: () => steuerung.tippen(t.sc),
                  ),
                const _Trenner(),
                for (final t in fTasten)
                  _Taste(
                    key: ValueKey('taste-${t.name}'),
                    text: t.name,
                    hilfe: t.name,
                    onTap: () => steuerung.tippen(t.sc),
                  ),
                const _Trenner(),
                _Taste(
                  key: const ValueKey('taste-strg-alt-entf'),
                  text: 'Strg+Alt+Entf',
                  hilfe: 'Strg+Alt+Entf senden',
                  onTap: () => steuerung.kombination(strgAltEntf),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Trenner extends StatelessWidget {
  const _Trenner();
  @override
  Widget build(BuildContext context) => const VerticalDivider(width: 12, indent: 10, endIndent: 10);
}

class _Taste extends StatefulWidget {
  const _Taste({
    super.key,
    required this.text,
    required this.hilfe,
    required this.onTap,
    this.aktiv = false,
    this.wiederholen = false,
  });
  final String text, hilfe;
  final VoidCallback onTap;
  final bool aktiv, wiederholen;

  @override
  State<_Taste> createState() => _TasteState();
}

class _TasteState extends State<_Taste> {
  Timer? _wdh;

  void _stop() {
    _wdh?.cancel();
    _wdh = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final f = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 5),
      child: Tooltip(
        message: widget.hilfe,
        child: Material(
          color: widget.aktiv ? f.primary : f.surface,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            // Kein Fokus: die Tasten sollen ihn dem Bild nicht wegnehmen.
            canRequestFocus: false,
            borderRadius: BorderRadius.circular(8),
            onTap: widget.onTap,
            onLongPress: widget.wiederholen
                ? () {
                    widget.onTap();
                    _wdh = Timer.periodic(const Duration(milliseconds: 80), (_) => widget.onTap());
                  }
                : null,
            onTapCancel: _stop,
            child: Listener(
              onPointerUp: (_) => _stop(),
              onPointerCancel: (_) => _stop(),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Center(
                    child: Text(
                      widget.text,
                      style: TextStyle(
                        fontWeight: widget.aktiv ? FontWeight.bold : FontWeight.w500,
                        color: widget.aktiv ? f.onPrimary : f.onSurface,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
