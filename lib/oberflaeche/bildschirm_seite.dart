// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';

import 'package:flutter/material.dart';

import '../app_zustand.dart';
import '../native/rwspice.dart';
import '../protokoll.dart';
import '../gateway/gateway.dart';
import '../spice/bildschirm.dart';
import '../spice/scancodes.dart';

/// Der Bildschirm eines Computers. Oben eine schmale Leiste mit dem Noetigsten:
/// Ton, Mikrofon, USB, Strg+Alt+Entf. Alles andere gehoert in den Gast.
class BildschirmSeite extends StatefulWidget {
  const BildschirmSeite({super.key, required this.computer, required this.zustand});
  final Computer computer;
  final AppZustand zustand;

  @override
  State<BildschirmSeite> createState() => _BildschirmSeiteState();
}

enum _Stand { verbinden, verbunden, getrennt }

class _BildschirmSeiteState extends State<BildschirmSeite> {
  final _spice = RwSpice.i;
  StreamSubscription<SpiceEreignis>? _abo;
  _Stand _stand = _Stand.verbinden;
  String? _meldung;
  bool _ton = true;
  // Mikrofon ist aus, bis die Person es einschaltet: ein Gast soll nicht
  // ungefragt mithoeren koennen.
  bool _mikrofon = false;
  bool _gastNimmtAuf = false;

  @override
  void initState() {
    super.initState();
    _abo = _spice.ereignisse.listen(_ereignis);
    _verbinden();
  }

  Future<void> _verbinden() async {
    setState(() {
      _stand = _Stand.verbinden;
      _meldung = null;
    });
    try {
      if (AppZustand.testSpice.isNotEmpty) {
        final teile = AppZustand.testSpice.split(':');
        _spice.verbinden(host: teile[0], port: int.parse(teile[1]));
      } else {
        // Das Ticket gilt nur kurz: fuer jede Verbindung ein frisches holen.
        // Ticket ueber den Gateway; die Verbindung geht durch den Tunnel zu
        // ihm (Port 3128), und er reicht sie zu Proxmox weiter.
        final z = await widget.zustand.gateway!.spice(widget.computer);
        _spice.verbinden(
          host: z.host,
          tlsPort: z.tlsPort,
          passwort: z.passwort,
          proxy: widget.zustand.netz.spiceProxy,
          ca: z.ca,
          hostSubject: z.hostSubject,
        );
      }
      _spice.ton(wiedergabe: _ton, mikrofon: _mikrofon);
    } catch (e, s) {
      Protokoll.schreiben('Bildschirm ${widget.computer.vmid} (${widget.computer.name}): Oeffnen fehlgeschlagen', e,
          e is GatewayFehler ? null : s);
      if (!mounted) return;
      setState(() {
        _stand = _Stand.getrennt;
        _meldung = '$e';
      });
    }
  }

  void _ereignis(SpiceEreignis e) {
    if (!mounted) return;
    switch (e.art) {
      case SpiceEreignisArt.verbunden:
      case SpiceEreignisArt.bildGroesse:
        if (_stand != _Stand.verbunden) Protokoll.schreiben('Bildschirm ${widget.computer.vmid}: verbunden');
        setState(() => _stand = _Stand.verbunden);
      case SpiceEreignisArt.getrennt:
        final grund = TrennGrund.values[e.a.clamp(0, TrennGrund.values.length - 1)];
        // Ein zweites "getrennt" (Sitzung zu nach Kanalfehler) soll den
        // ersten, genaueren Grund nicht ueberschreiben.
        if (_stand == _Stand.getrennt && grund == TrennGrund.normal) return;
        final technik = _spice.letzterFehler();
        Protokoll.schreiben('Bildschirm ${widget.computer.vmid}: getrennt (${grund.name})'
            '${technik.isNotEmpty ? ' — $technik' : ''}');
        setState(() {
          _stand = _Stand.getrennt;
          final text = switch (grund) {
            TrennGrund.normal => 'Die Verbindung wurde beendet.',
            TrennGrund.tls => 'Die Verbindung war nicht vertrauenswuerdig und wurde abgebrochen.',
            TrennGrund.anmeldung => 'Die Freigabe war abgelaufen.',
            TrennGrund.verbindung => 'Der Computer war nicht erreichbar.',
            TrennGrund.anderes => 'Die Verbindung ist abgebrochen.',
          };
          // Technischer Grund sichtbar mit dazu, damit man ihn melden kann.
          _meldung = technik.isNotEmpty && grund != TrennGrund.normal ? '$text\n\nTechnisch: $technik' : text;
        });
      case SpiceEreignisArt.mikrofon:
        setState(() => _gastNimmtAuf = e.a == 1);
      case SpiceEreignisArt.usbFehler:
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('USB-Geraet: ${_spice.letzterFehler()}')));
      default:
        break;
    }
  }

  void _tonSetzen() => _spice.ton(wiedergabe: _ton, mikrofon: _mikrofon);

  Future<void> _usbMenue() async {
    final liste = _spice.usbListe();
    await showModalBottomSheet<void>(
      context: context,
      builder: (context) => StatefulBuilder(builder: (context, neu) {
        final aktuell = _spice.usbListe();
        return ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('USB-Geraete an diesen Computer weitergeben')),
          if (liste.isEmpty)
            const ListTile(title: Text('Keine USB-Geraete gefunden.')),
          for (final g in aktuell)
            SwitchListTile(
              title: Text(g.name.isEmpty ? 'USB-Geraet ${g.id}' : g.name),
              subtitle: g.moeglich ? null : Text(g.grund.isEmpty ? 'nicht moeglich' : g.grund),
              value: g.verbunden,
              onChanged: g.moeglich
                  ? (an) {
                      _spice.usbSchalten(g.id, an);
                      Future<void>.delayed(const Duration(milliseconds: 500), () => neu(() {}));
                    }
                  : null,
            ),
        ]);
      }),
    );
  }

  void _strgAltEntf() {
    for (final sc in strgAltEntf) {
      _spice.taste(sc, 1);
    }
    for (final sc in strgAltEntf.reversed) {
      _spice.taste(sc, 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        title: Text(widget.computer.name),
        actions: [
          IconButton(
            tooltip: _ton ? 'Ton aus' : 'Ton an',
            icon: Icon(_ton ? Icons.volume_up : Icons.volume_off),
            onPressed: () {
              setState(() => _ton = !_ton);
              _tonSetzen();
            },
          ),
          IconButton(
            tooltip: _mikrofon ? 'Mikrofon aus' : 'Mikrofon an',
            icon: Icon(_mikrofon ? Icons.mic : Icons.mic_off,
                color: _mikrofon && _gastNimmtAuf ? Colors.red : null),
            onPressed: () {
              setState(() => _mikrofon = !_mikrofon);
              _tonSetzen();
            },
          ),
          IconButton(tooltip: 'USB-Geraete', icon: const Icon(Icons.usb), onPressed: _usbMenue),
          IconButton(tooltip: 'Strg+Alt+Entf senden', icon: const Icon(Icons.keyboard), onPressed: _strgAltEntf),
        ],
      ),
      body: Stack(children: [
        const Positioned.fill(child: SpiceBildschirm()),
        if (_stand != _Stand.verbunden)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black54,
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(mainAxisSize: MainAxisSize.min, children: [
                      if (_stand == _Stand.verbinden) ...[
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        const Text('Bildschirm wird geoeffnet …'),
                      ] else ...[
                        Text(_meldung ?? 'Getrennt', textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _verbinden, child: const Text('Neu verbinden')),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
      ]),
    );
  }

  @override
  void dispose() {
    _abo?.cancel();
    _spice.trennen();
    super.dispose();
  }
}
