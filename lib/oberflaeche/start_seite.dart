// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';

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
            _LageAnzeige(netz: zustand.netz),
            if (zustand.phase == Phase.liste)
              IconButton(
                tooltip: 'Liste neu laden',
                icon: const Icon(Icons.refresh),
                onPressed: zustand.aktualisieren,
              ),
            PopupMenuButton<String>(
              tooltip: 'Konto',
              icon: const Icon(Icons.account_circle_outlined),
              itemBuilder: (_) => [
                if (zustand.konto.name != null)
                  PopupMenuItem(enabled: false, child: Text(zustand.konto.name!)),
                if (zustand.konto.email != null)
                  PopupMenuItem(enabled: false, child: Text(zustand.konto.email!)),
                const PopupMenuItem(value: 'ueber', child: Text('Über diese App')),
                const PopupMenuItem(value: 'ab', child: Text('Abmelden')),
              ],
              onSelected: (wahl) => wahl == 'ueber' ? _ueber(context) : zustand.abmelden(),
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
      case Phase.pruefen:
        return const _Hinweis(warten: true, text: 'Einen Moment …');
      case Phase.tunnel:
        return const _Hinweis(warten: true, text: 'Sichere Verbindung ins Haus wird aufgebaut …');
      case Phase.anmelden:
        return const _Hinweis(
            warten: true,
            text: 'Die Anmeldeseite wurde im Browser geoeffnet.\nNach der Anmeldung geht es hier weiter.');
      case Phase.kontoNoetig:
        return _Hinweis(
          logo: true,
          text: 'Bitte mit dem Rosenweg-Konto anmelden.\nDie App merkt sich die Anmeldung 30 Tage.',
          knopf: 'Mit Rosenweg-Konto anmelden',
          aktion: zustand.anmelden,
        );
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

/// Kurz und klar: im Haus / unterwegs (sicher verbunden).
class _LageAnzeige extends StatelessWidget {
  const _LageAnzeige({required this.netz});
  final Netzlage netz;

  @override
  Widget build(BuildContext context) {
    final (icon, farbe) = switch (netz.lage) {
      Lage.imHaus => (Icons.home_outlined, Colors.green),
      Lage.unterwegs => (Icons.lock_outline, Colors.blue),
      Lage.keinZugang => (Icons.cloud_off, Colors.red),
      Lage.unbekannt => (Icons.sync, Colors.grey),
      Lage.test => (Icons.science_outlined, Colors.orange),
    };
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Chip(avatar: Icon(icon, color: farbe, size: 18), label: Text(netz.beschreibung)),
    );
  }
}

class _Hinweis extends StatelessWidget {
  const _Hinweis({required this.text, this.warten = false, this.logo = false, this.knopf, this.aktion});
  final String text;
  final bool warten;
  final bool logo;
  final String? knopf;
  final VoidCallback? aktion;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (logo) const Padding(padding: EdgeInsets.only(bottom: 24), child: _Logo(groesse: 128)),
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
