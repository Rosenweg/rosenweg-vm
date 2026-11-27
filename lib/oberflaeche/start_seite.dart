// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart'
    show AnmeldeArt, FehlerAnzeige, Fensterklasse, RosenwegGeruest, zeigeAnmeldung, zeigeUeber;

import '../app_zustand.dart';
import '../vm_app.dart';
import '../netz/netzlage.dart';
import '../gateway/gateway.dart';
import 'bildschirm_seite.dart';

/// "Meine Computer": eine Liste, ein Tipp oeffnet den Bildschirm.
/// Projektregel: einfach bedienbar, keine Proxmox-Begriffe.
/// Gerüst aus rosenweg_basis: am Desktop steht die Liste mit lesbarer Breite
/// in der Mitte, auf dem Handy wie bisher ueber die ganze Breite.
class StartSeite extends StatelessWidget {
  const StartSeite({super.key, required this.zustand});
  final AppZustand zustand;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: zustand,
      builder: (context, _) => RosenwegGeruest(
        // Bei 400 px wurde der Titel zu „Mein…“ (Test win11-1): die Lage
        // steht dort nur als Symbol, der Titel darf umbrechen.
        titel: const Text('Meine Computer', maxLines: 2, softWrap: true, overflow: TextOverflow.fade),
        aktionen: [
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
              'ueber' => zeigeUeber(context, vmApp),
              _ => zustand.abmelden(),
            },
          ),
        ],
        inhalt: _inhalt(context),
      ),
    );
  }

  Widget _inhalt(BuildContext context) {
    switch (zustand.phase) {
      case Phase.tunnel:
        return const _Hinweis(warten: true, text: 'Sichere Verbindung ins Haus wird aufgebaut …');
      case Phase.fehler:
        return FehlerAnzeige(text: zustand.fehler ?? '', details: zustand.fehlerDetails, nochmals: zustand.starten);
      case Phase.liste:
        if (zustand.computer.isEmpty) {
          return const _Hinweis(text: 'Für Sie ist noch kein Computer freigegeben.');
        }
        final breit = Fensterklasse.von(context).istBreit;
        final liste = ListView.separated(
          shrinkWrap: breit,
          physics: breit ? const NeverScrollableScrollPhysics() : null,
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: zustand.computer.length,
          separatorBuilder: (_, _) => const Divider(height: 1),
          itemBuilder: (context, i) => _Zeile(c: zustand.computer[i], zustand: zustand),
        );
        // Desktop: die Liste als Karte mit Abstand, nicht randlos ueber das Fenster.
        if (!breit) return liste;
        return SingleChildScrollView(padding: const EdgeInsets.all(24), child: Card(child: liste));
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
      // Name ganz lesbar, auch schmal: umbrechen statt kuerzen.
      title: Text(c.name, style: const TextStyle(fontSize: 18), softWrap: true),
      subtitle: Text(c.laeuft ? (c.darfOeffnen ? 'läuft' : 'läuft · nur Anzeige in der Liste') : 'ausgeschaltet'),
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
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Einschalten ging nicht. ${vmFehler(e).text}')));
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
    // Schmal (Handy, Fenster unter 600 px): nur das Symbol, der Text als
    // Tooltip - sonst bleibt fuer den Titel nichts uebrig.
    if (Fensterklasse.von(context) == Fensterklasse.kompakt) {
      return Tooltip(
        message: text,
        triggerMode: TooltipTriggerMode.tap,
        child: Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Icon(icon, color: farbe, semanticLabel: text)),
      );
    }
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
  const _Hinweis({required this.text, this.warten = false});
  final String text;
  final bool warten;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (warten) const Padding(padding: EdgeInsets.only(bottom: 24), child: CircularProgressIndicator()),
          Text(text, textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium),
        ]),
      ),
    );
  }
}
