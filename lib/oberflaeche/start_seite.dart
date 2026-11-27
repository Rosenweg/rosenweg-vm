// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show AnmeldeArt, zeigeAnmeldung;

import '../app_zustand.dart';
import '../netz/netzlage.dart';
import '../gateway/gateway.dart';
import 'bildschirm_seite.dart';

/// "Meine Computer": eine Liste, ein Tipp oeffnet den Bildschirm.
/// Projektregel: einfach bedienbar, keine Proxmox-Begriffe.
class StartSeite extends StatelessWidget {
  const StartSeite({super.key, required this.zustand});
  final AppZustand zustand;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: zustand,
      builder: (context, _) => Scaffold(
        appBar: AppBar(
          title: const Text('Meine Computer'),
          actions: [
            _LageAnzeige(zustand: zustand),
            if (zustand.phase == Phase.liste)
              IconButton(
                tooltip: 'Liste neu laden',
                icon: const Icon(Icons.refresh),
                onPressed: zustand.aktualisieren,
              ),
            PopupMenuButton<String>(
              tooltip: 'Konto',
              icon: const Icon(Icons.account_circle_outlined),
              itemBuilder: (_) {
                // Immer der echte Stand der Sitzung (rosenweg_basis), nie eine Vermutung.
                final st = zustand.sitzung.stand;
                return [
                  if ((st.name ?? '').isNotEmpty) PopupMenuItem(enabled: false, child: Text(st.name!)),
                  PopupMenuItem(enabled: false, child: Text(st.art.text)),
                  const PopupMenuItem(value: 'anmeldung', child: Text('Anmeldung')),
                  const PopupMenuItem(value: 'ueber', child: Text('Über diese App')),
                  if (st.angemeldet && st.art != AnmeldeArt.geteiltesTelefon)
                    const PopupMenuItem(value: 'ab', child: Text('Abmelden')),
                ];
              },
              onSelected: (wahl) => switch (wahl) {
                'anmeldung' => zeigeAnmeldung(context, zustand.sitzung),
                'ueber' => _ueber(context),
                _ => zustand.abmelden(),
              },
            ),
          ],
        ),
        body: _inhalt(context),
      ),
    );
  }

  void _ueber(BuildContext context) {
    showAboutDialog(
      context: context,
      applicationName: 'Rosenweg Virtuelle Computer',
      applicationIcon: const _Logo(groesse: 64),
      applicationLegalese: 'Freie Software unter der GPL-3.0-or-later.',
    );
  }

  Widget _inhalt(BuildContext context) {
    switch (zustand.phase) {
      case Phase.tunnel:
        return const _Hinweis(warten: true, text: 'Sichere Verbindung ins Haus wird aufgebaut …');
      case Phase.fehler:
        return _Hinweis(text: 'Es hat nicht geklappt:\n${zustand.fehler}', knopf: 'Nochmals', aktion: zustand.starten);
      case Phase.liste:
        if (zustand.computer.isEmpty) {
          return const _Hinweis(text: 'Fuer Sie ist noch kein Computer freigegeben.');
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: zustand.computer.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _Zeile(c: zustand.computer[i], zustand: zustand),
        );
    }
  }
}

class _Zeile extends StatelessWidget {
  const _Zeile({required this.c, required this.zustand});
  final Computer c;
  final AppZustand zustand;

  @override
  Widget build(BuildContext context) {
    final farbe = Theme.of(context).colorScheme;
    return ListTile(
      leading: Icon(Icons.computer, size: 32, color: c.laeuft ? farbe.primary : farbe.outline),
      title: Text(c.name, style: const TextStyle(fontSize: 18)),
      subtitle: Text(c.laeuft ? (c.darfOeffnen ? 'laeuft' : 'laeuft · nur Anzeige in der Liste') : 'ausgeschaltet'),
      trailing: c.laeuft
          ? (c.darfOeffnen ? const Icon(Icons.chevron_right) : null)
          : (c.darfEinschalten ? const Icon(Icons.power_settings_new) : null),
      enabled: c.laeuft ? c.darfOeffnen : c.darfEinschalten,
      onTap: () => c.laeuft ? _oeffnen(context) : _einschalten(context),
    );
  }

  void _oeffnen(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => BildschirmSeite(computer: c, zustand: zustand),
    ));
  }

  Future<void> _einschalten(BuildContext context) async {
    final ja = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('${c.name} einschalten?'),
        content: const Text('Der Computer ist ausgeschaltet. Er startet in etwa einer Minute.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Abbrechen')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Einschalten')),
        ],
      ),
    );
    if (ja != true) return;
    try {
      await zustand.einschalten(c);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Einschalten ging nicht: $e')));
      }
    }
  }
}

/// Kurz und klar, was gerade ist: im Haus / unterwegs (sicher verbunden) —
/// und solange es keine Verbindung gibt, warum nicht. Frueher stand hier vor
/// jeder Verbindung "Verbindung wird aufgebaut …", auch wenn die App nur auf
/// den Knopf "Anmelden" wartete (Pruefung desktop-test, 27.11.2026).
class _LageAnzeige extends StatelessWidget {
  const _LageAnzeige({required this.zustand});
  final AppZustand zustand;

  @override
  Widget build(BuildContext context) {
    final (icon, farbe, text) = lageAnzeige(zustand.phase, zustand.netz);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Chip(avatar: Icon(icon, color: farbe, size: 18), label: Text(text)),
    );
  }
}

/// Symbol, Farbe und Text oben rechts. Sobald die Netzlage etwas weiss, gilt
/// sie; vorher sagt die Phase, worauf die App wartet.
///
/// Seit 1.2.0 steht die Anmeldung (Anmeldetor aus rosenweg_basis) vor dieser
/// Seite; hier bleiben nur noch Tunnel, Liste und Fehler.
(IconData, Color, String) lageAnzeige(Phase phase, Netzlage netz) {
  final lage = netz.lage;
  if (lage != Lage.unbekannt) {
    final (icon, farbe) = switch (lage) {
      Lage.imHaus => (Icons.home_outlined, Colors.green),
      Lage.unterwegs => (Icons.lock_outline, Colors.blue),
      Lage.keinZugang => (Icons.cloud_off, Colors.red),
      Lage.test => (Icons.science_outlined, Colors.orange),
      Lage.unbekannt => (Icons.sync, Colors.grey),
    };
    return (icon, farbe, netz.beschreibung);
  }
  return switch (phase) {
    Phase.tunnel => (Icons.sync, Colors.grey, netz.beschreibung),
    Phase.fehler => (Icons.cloud_off, Colors.grey, 'Nicht verbunden'),
    Phase.liste => (Icons.sync, Colors.grey, netz.beschreibung),
  };
}

class _Hinweis extends StatelessWidget {
  const _Hinweis({required this.text, this.warten = false, this.knopf, this.aktion});
  final String text;
  final bool warten;
  final String? knopf;
  final VoidCallback? aktion;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (warten) const Padding(padding: EdgeInsets.only(bottom: 24), child: CircularProgressIndicator()),
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
          if (knopf != null)
            Padding(
              padding: const EdgeInsets.only(top: 24),
              child: FilledButton(onPressed: aktion, child: Text(knopf!)),
            ),
        ]),
      ),
    );
  }
}

/// App-Logo (Turm, Weg, Rose mit Monitor-Plakette), assets/logo/erzeugen.sh.
class _Logo extends StatelessWidget {
  const _Logo({required this.groesse});
  final double groesse;

  @override
  Widget build(BuildContext context) => Image.asset(
        'assets/logo/rosenweg-vm-512.png',
        width: groesse,
        height: groesse,
        filterQuality: FilterQuality.medium,
        semanticLabel: 'Rosenweg Virtuelle Computer',
      );
}
