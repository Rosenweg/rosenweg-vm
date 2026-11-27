// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show FehlerDetails, Fensterklasse;

import '../app_zustand.dart';
import '../native/rwspice.dart';
import '../protokoll.dart';
import '../gateway/gateway.dart';
import '../spice/bedien_einstellung.dart';
import '../spice/bildschirm.dart';
import '../spice/belegungen.dart';
import '../spice/scancodes.dart';
import '../spice/tastatur_einstellung.dart';
import 'sondertasten_leiste.dart';

/// Der Bildschirm eines Computers. Oben eine schmale Leiste mit dem Noetigsten:
/// Tastatur (immer sichtbar, oeffnet Bildschirmtastatur und Sondertasten),
/// Ton, Mikrofon, USB, Ordner, Einstellungen, Strg+Alt+Entf. Alles andere
/// gehoert in den Gast.
class BildschirmSeite extends StatefulWidget {
  const BildschirmSeite({super.key, required this.computer, required this.zustand});
  final Computer computer;
  final AppZustand zustand;

  @override
  State<BildschirmSeite> createState() => _BildschirmSeiteState();
}

enum _Stand { verbinden, verbunden, getrennt }

class _BildschirmSeiteState extends State<BildschirmSeite> with WidgetsBindingObserver {
  final _spice = RwSpice.i;
  final _steuerung = BildschirmSteuerung();

  /// Bildschirmtastatur war schon sichtbar (fuer "System hat sie geschlossen").
  bool _imeSichtbar = false;
  StreamSubscription<SpiceEreignis>? _abo;
  _Stand _stand = _Stand.verbinden;
  String? _meldung;

  /// Technik zur [_meldung] (aufklappbar unter "Details").
  String? _details;
  bool _ton = true;
  // Mikrofon ist aus, bis die Person es einschaltet: ein Gast soll nicht
  // ungefragt mithoeren koennen.
  bool _mikrofon = false;
  bool _gastNimmtAuf = false;

  /// Was der Computer anbietet (Ton nur mit audio0 driver=spice, USB nur mit
  /// usbN: spice). Erst nach dem Verbinden bekannt.
  final _kanaele = <SpiceKanal>{};
  bool _kanaeleBekannt = false;
  Timer? _kanalWarten;

  /// Freigegebener Ordner (null = keiner) und ob nur lesend.
  String? _ordner;
  bool _ordnerNurLesen = false;

  static const _ohne = {
    SpiceKanal.wiedergabe: 'Dieser Computer hat keine Tonausgabe über SPICE – Technik: Audio-Gerät „SPICE“ hinzufügen.',
    SpiceKanal.aufnahme: 'Dieser Computer hat keinen Toneingang über SPICE – Technik: Audio-Gerät „SPICE“ hinzufügen.',
    SpiceKanal.usb: 'Dieser Computer hat keine USB-Weiterleitung über SPICE – Technik: USB-Gerät „Spice-Port“ hinzufügen.',
    SpiceKanal.ordner: 'Dieser Computer kann keine Ordner annehmen – Technik: spice-webdavd installieren.',
  };

  bool _fehlt(SpiceKanal k) => _kanaeleBekannt && !_kanaele.contains(k);

  /// Die Kanalliste kommt mit dem Hauptkanal, vor dem ersten Bild. Kurz nach
  /// dem Verbinden gilt sie als vollstaendig.
  void _kanaeleFestlegen() {
    if (_kanaeleBekannt || !mounted) return;
    _kanalWarten?.cancel();
    setState(() => _kanaeleBekannt = true);
    String jn(SpiceKanal k) => _kanaele.contains(k) ? 'ja' : 'nein';
    Protokoll.schreiben('Bildschirm ${widget.computer.vmid}: Ton ${jn(SpiceKanal.wiedergabe)}, '
        'Mikrofon ${jn(SpiceKanal.aufnahme)}, USB ${jn(SpiceKanal.usb)}, Ordner ${jn(SpiceKanal.ordner)}');
  }

  void _hinweis(SpiceKanal k) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(_ohne[k]!)));

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _abo = _spice.ereignisse.listen(_ereignis);
    TastaturEinstellung.i.laden();
    BedienEinstellung.i.laden();
    _verbinden();
  }

  Future<void> _verbinden() async {
    _kanalWarten?.cancel();
    _kanalWarten = null;
    setState(() {
      _stand = _Stand.verbinden;
      _meldung = null;
      _details = null;
      _kanaele.clear();
      _kanaeleBekannt = false;
      _ordner = null; // neue Sitzung: Freigabe ist weg
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
        final f = vmFehler(e);
        _meldung = f.text;
        _details = f.details;
      });
    }
  }

  void _ereignis(SpiceEreignis e) {
    if (!mounted) return;
    switch (e.art) {
      case SpiceEreignisArt.ordner:
        if (e.b == 1) {
          final t = _spice.letzterFehler();
          Protokoll.schreiben('Ordner freigeben fehlgeschlagen: $t');
          setState(() => _ordner = null);
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Ordner freigeben ging nicht: $t')));
        }
      case SpiceEreignisArt.kanal:
        final k = SpiceKanal.aus(e.a);
        if (k != null) setState(() => e.b == 1 ? _kanaele.add(k) : _kanaele.remove(k));
      case SpiceEreignisArt.verbunden:
      case SpiceEreignisArt.bildGroesse:
        if (e.art == SpiceEreignisArt.bildGroesse) {
          _kanaeleFestlegen();
          _ersteHilfe();
        } else {
          _kanalWarten ??= Timer(const Duration(seconds: 3), _kanaeleFestlegen);
        }
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
            TrennGrund.tls => 'Die Verbindung war nicht vertrauenswürdig und wurde abgebrochen.',
            TrennGrund.anmeldung => 'Die Freigabe war abgelaufen.',
            TrennGrund.verbindung => 'Der Computer war nicht erreichbar.',
            TrennGrund.anderes => 'Die Verbindung ist abgebrochen.',
          };
          // Technischer Grund sichtbar mit dazu, damit man ihn melden kann.
          _meldung = text;
          _details = technik.isNotEmpty && grund != TrennGrund.normal ? technik : null;
        });
      case SpiceEreignisArt.mikrofon:
        setState(() => _gastNimmtAuf = e.a == 1);
      case SpiceEreignisArt.usbFehler:
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('USB-Gerät: ${_spice.letzterFehler()}')));
      default:
        break;
    }
  }

  /// Schliesst die Person die Bildschirmtastatur selbst (Zurueck-Taste,
  /// Pfeil nach unten), geht auch die Sondertasten-Leiste zu.
  @override
  void didChangeMetrics() {
    if (!mounted) return;
    final unten = View.of(context).viewInsets.bottom;
    if (unten > 0) {
      _imeSichtbar = true;
    } else if (_imeSichtbar) {
      _imeSichtbar = false;
      if (_steuerung.tastaturOffen && (Platform.isAndroid || Platform.isIOS)) _steuerung.tastatur(false);
    }
  }

  /// Blatt von unten: scrollbar, nie unter der Navigationsleiste, danach
  /// Tastaturfokus zurueck aufs Bild.
  Future<void> _blatt(WidgetBuilder inhalt) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.85),
      builder: (context) => SafeArea(top: false, child: inhalt(context)),
    );
    _steuerung.fokus();
  }

  void _tonSetzen() => _spice.ton(wiedergabe: _ton, mikrofon: _mikrofon);

  Future<void> _usbMenue() async {
    final liste = _spice.usbListe();
    for (final g in liste.where((g) => g.macTreiber.isNotEmpty)) {
      Protokoll.schreiben('USB ${g.id} (${g.name}) nicht angeboten: ${g.macTreiber} (macOS-Treiber)');
    }
    await _blatt((context) => StatefulBuilder(builder: (context, neu) {
        final aktuell = _spice.usbListe();
        return ListView(shrinkWrap: true, children: [
          const ListTile(title: Text('USB-Geräte an diesen Computer weitergeben')),
          if (liste.isEmpty)
            const ListTile(title: Text('Keine USB-Geräte gefunden.')),
          for (final g in aktuell)
            SwitchListTile(
              title: Text(g.name.isEmpty ? 'USB-Gerät ${g.id}' : g.name),
              subtitle: g.macTreiber.isNotEmpty
                  ? Text('${g.macTreiber}: nutzt der Mac selbst. USB-Sticks bitte über „Ordner freigeben“ einbinden.')
                  : g.moeglich
                      ? null
                      : Text(g.grund.isEmpty ? 'nicht möglich' : g.grund),
              value: g.verbunden,
              onChanged: g.moeglich
                  ? (an) {
                      _spice.usbSchalten(g.id, an);
                      Future<void>.delayed(const Duration(milliseconds: 500), () => neu(() {}));
                    }
                  : null,
            ),
        ]);
      }));
  }

  /// Ordner (oder Stick unter /Volumes) per SPICE-WebDAV an den Gast geben.
  Future<void> _ordnerMenue() async {
    if (!_spice.ordnerMoeglich) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Ordner freigeben geht mit diesem App-Bau noch nicht (spice-glib ohne WebDAV/phodav).')));
      return;
    }
    if (_fehlt(SpiceKanal.ordner)) return _hinweis(SpiceKanal.ordner);
    await _blatt((context) => StatefulBuilder(
        builder: (context, neu) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Text('Ordner freigeben', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(_ordner == null ? 'Kein Ordner freigegeben.' : 'Freigegeben: $_ordner${_ordnerNurLesen ? ' (nur lesen)' : ''}'),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Nur lesen'),
            value: _ordnerNurLesen,
            onChanged: (v) => neu(() => setState(() => _ordnerNurLesen = v)),
          ),
          Wrap(spacing: 8, children: [
            FilledButton.icon(
              icon: const Icon(Icons.folder_open),
              label: Text(_ordner == null ? 'Ordner wählen …' : 'Anderen Ordner …'),
              onPressed: () async {
                final pfad = await getDirectoryPath(
                  confirmButtonText: 'Freigeben',
                  initialDirectory: Platform.isMacOS ? '/Volumes' : null,
                );
                if (pfad == null) return;
                _spice.ordner(pfad, nurLesen: _ordnerNurLesen);
                Protokoll.schreiben('Ordner freigeben: $pfad${_ordnerNurLesen ? ' (nur lesen)' : ''}');
                neu(() => setState(() => _ordner = pfad));
              },
            ),
            if (_ordner != null)
              OutlinedButton(
                onPressed: () {
                  _spice.ordner(null);
                  Protokoll.schreiben('Ordnerfreigabe beendet');
                  neu(() => setState(() => _ordner = null));
                },
                child: const Text('Freigabe beenden'),
              ),
          ]),
          const SizedBox(height: 12),
          Text(
            'So erscheint der Ordner im Computer:\n'
            '• Linux: im Dateimanager unter „Spice client folder“ (oder Netzwerk → '
            'dav://localhost:9843/). Braucht das Paket spice-webdavd.\n'
            '• Windows: als Netzlaufwerk (z. B. Z:) nach dem Start von „Spice webdav proxy“ '
            '(in den SPICE Guest Tools).\n'
            'USB-Sticks am Mac: den Stick unter /Volumes wählen.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ]),
      ));
  }

  /// Telefon/Tablet: beim ersten Bild einmal kurz die Gesten zeigen.
  void _ersteHilfe() {
    if (!(Platform.isAndroid || Platform.isIOS) || BedienEinstellung.i.hilfeGesehen || _hilfeOffen) return;
    _hilfeOffen = true;
    Future<void>.delayed(const Duration(milliseconds: 600), () async {
      if (!mounted) return;
      await _gestenHilfe();
      await BedienEinstellung.i.setzen(hilfeGesehen: true);
    });
  }

  bool _hilfeOffen = false;

  Future<void> _gestenHilfe() async {
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Bedienung mit dem Finger'),
        content: const SingleChildScrollView(child: GestenHilfe()),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Verstanden'))],
      ),
    );
    _steuerung.fokus();
  }

  /// Einstellungen: Tastatur (Modus, Gastbelegung mit Suche, Cmd als Strg,
  /// Mac-ISO) und Beruehrung (direkt / Touchpad, Hilfe).
  Future<void> _tastaturMenue() async {
    final t = TastaturEinstellung.i;
    final bed = BedienEinstellung.i;
    await _blatt((context) => ListenableBuilder(
        listenable: Listenable.merge([t, bed]),
        builder: (context, _) => ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Text('Tastatur', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<TastaturModus>(
            segments: const [
              ButtonSegment(value: TastaturModus.zeichen, label: Text('Zeichen übersetzen')),
              ButtonSegment(value: TastaturModus.direkt, label: Text('Tasten direkt')),
            ],
            selected: {t.modus},
            onSelectionChanged: (m) => t.setzen(modus: m.first),
          ),
          const SizedBox(height: 4),
          Text(
            t.modus == TastaturModus.zeichen
                ? 'Was du tippst, kommt im Computer so an — egal welche Tastatur du hast.'
                : 'Jede Taste geht 1:1. Nur richtig, wenn deine Tastatur dieselbe Belegung hat wie der Computer.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Belegung des Computers'),
            subtitle: Text(t.belegung.name),
            trailing: const Icon(Icons.chevron_right),
            onTap: () async {
              final b = await _belegungWaehlen(t.belegung);
              if (b != null) await t.setzen(belegung: b);
            },
          ),
          if (Platform.isMacOS) ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Cmd wie Strg'),
              subtitle: const Text('Cmd+C, Cmd+V … werden im Computer zu Strg+C, Strg+V'),
              value: t.cmdAlsStrg,
              onChanged: (v) => t.setzen(cmdAlsStrg: v),
            ),
            if (t.modus == TastaturModus.direkt)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Mac-Tastatur mit § links oben (ISO)'),
                subtitle: const Text('Tauscht § und < wie bei einer PC-Tastatur'),
                value: t.macIsoTausch,
                onChanged: (v) => t.setzen(macIsoTausch: v),
              ),
          ],
          const Divider(height: 24),
          Text('Berührung', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 12),
          SegmentedButton<TouchModus>(
            key: const ValueKey('touch-modus'),
            segments: const [
              ButtonSegment(value: TouchModus.direkt, icon: Icon(Icons.touch_app), label: Text('Direkt')),
              ButtonSegment(value: TouchModus.touchpad, icon: Icon(Icons.mouse), label: Text('Touchpad')),
            ],
            selected: {bed.touch},
            onSelectionChanged: (m) => bed.setzen(touch: m.first),
          ),
          const SizedBox(height: 4),
          Text(
            bed.touch == TouchModus.direkt
                ? 'Tippen klickt genau dort, wo der Finger ist.'
                : 'Der Finger schiebt den Mauszeiger, Tippen klickt dort, wo der Zeiger steht.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.help_outline),
            title: const Text('Gesten anzeigen'),
            onTap: () {
              Navigator.pop(context);
              _gestenHilfe();
            },
          ),
        ]),
      ));
  }

  Future<GastBelegung?> _belegungWaehlen(GastBelegung aktuell) => showDialog<GastBelegung>(
        context: context,
        builder: (context) {
          var suche = '';
          return StatefulBuilder(builder: (context, neu) {
            final q = suche.toLowerCase();
            final liste = alleBelegungen
                .where((b) => q.isEmpty || b.name.toLowerCase().contains(q) || b.kennung.contains(q))
                .toList();
            return AlertDialog(
              title: const Text('Belegung des Computers'),
              content: SizedBox(
                width: 360,
                height: 420,
                child: Column(children: [
                  TextField(
                    autofocus: true,
                    decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Suchen'),
                    onChanged: (v) => neu(() => suche = v),
                  ),
                  Expanded(
                    child: ListView(children: [
                      for (final b in liste)
                        ListTile(
                          title: Text(b.name),
                          subtitle: Text(b.kennung),
                          trailing: b.kennung == aktuell.kennung ? const Icon(Icons.check) : null,
                          onTap: () => Navigator.pop(context, b),
                        ),
                    ]),
                  ),
                ]),
              ),
            );
          });
        },
      );

  void _strgAltEntf() => _steuerung.kombination(strgAltEntf);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        // Name des Computers ganz (Tooltip), auch wenn er schmal gekuerzt wird.
        title: Tooltip(message: widget.computer.name, child: Text(widget.computer.name)),
        actions: _schmalOderBreit(context, immer: [
          ListenableBuilder(
            listenable: _steuerung,
            builder: (context, _) => IconButton(
              key: const ValueKey('tastatur-knopf'),
              tooltip: _steuerung.tastaturOffen ? 'Tastatur schliessen' : 'Tastatur',
              isSelected: _steuerung.tastaturOffen,
              icon: const Icon(Icons.keyboard),
              selectedIcon: const Icon(Icons.keyboard_hide),
              onPressed: () => _steuerung.tastatur(!_steuerung.tastaturOffen),
            ),
          ),
        ], [
          // Fehlt ein Kanal, bleibt der Knopf sichtbar, aber grau; ein Druck
          // sagt warum (statt still nichts zu tun).
          if (_fehlt(SpiceKanal.wiedergabe))
            IconButton(
              tooltip: _ohne[SpiceKanal.wiedergabe],
              icon: Icon(Icons.volume_off, color: Theme.of(context).disabledColor),
              onPressed: () => _hinweis(SpiceKanal.wiedergabe),
            )
          else
            IconButton(
              tooltip: _ton ? 'Ton aus' : 'Ton an',
              icon: Icon(_ton ? Icons.volume_up : Icons.volume_off),
              onPressed: () {
                setState(() => _ton = !_ton);
                _tonSetzen();
              },
            ),
          if (_fehlt(SpiceKanal.aufnahme))
            IconButton(
              tooltip: _ohne[SpiceKanal.aufnahme],
              icon: Icon(Icons.mic_off, color: Theme.of(context).disabledColor),
              onPressed: () => _hinweis(SpiceKanal.aufnahme),
            )
          else
            IconButton(
              tooltip: _mikrofon ? 'Mikrofon aus' : 'Mikrofon an',
              icon: Icon(_mikrofon ? Icons.mic : Icons.mic_off,
                  color: _mikrofon && _gastNimmtAuf ? Colors.red : null),
              onPressed: () {
                setState(() => _mikrofon = !_mikrofon);
                _tonSetzen();
              },
            ),
          if (_fehlt(SpiceKanal.usb))
            IconButton(
              tooltip: _ohne[SpiceKanal.usb],
              icon: Icon(Icons.usb_off, color: Theme.of(context).disabledColor),
              onPressed: () => _hinweis(SpiceKanal.usb),
            )
          else
            IconButton(tooltip: 'USB-Geräte', icon: const Icon(Icons.usb), onPressed: _usbMenue),
          IconButton(
            tooltip: _ordner == null ? 'Ordner freigeben' : 'Freigegeben: $_ordner',
            icon: Icon(_ordner == null ? Icons.folder_shared_outlined : Icons.folder_shared,
                color: !_spice.ordnerMoeglich || _fehlt(SpiceKanal.ordner) ? Theme.of(context).disabledColor : null),
            onPressed: _ordnerMenue,
          ),
          IconButton(tooltip: 'Einstellungen', icon: const Icon(Icons.tune), onPressed: _tastaturMenue),
          IconButton(tooltip: 'Strg+Alt+Entf senden', icon: const Icon(Icons.key), onPressed: _strgAltEntf),
        ]),
      ),
      body: Column(children: [
        Expanded(child: Stack(children: [
        Positioned.fill(
          child: SpiceBildschirm(
            steuerung: _steuerung,
            hinweis: (t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t))),
          ),
        ),
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
                        const Text('Bildschirm wird geöffnet …'),
                      ] else ...[
                        Text(_meldung ?? 'Getrennt', textAlign: TextAlign.center),
                        if (_details != null) ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: FehlerDetails(_details!)),
                        const SizedBox(height: 16),
                        FilledButton(onPressed: _verbinden, child: const Text('Neu verbinden')),
                      ],
                    ]),
                  ),
                ),
              ),
            ),
          ),
        ])),
        ListenableBuilder(
          listenable: _steuerung,
          builder: (context, _) =>
              _steuerung.tastaturOffen ? SondertastenLeiste(steuerung: _steuerung) : const SizedBox.shrink(),
        ),
      ]),
    );
  }

  /// Schmal (unter 600 px) passen die sieben Knoepfe nicht neben den Namen
  /// (Test win11-1 bei 400 px: „dis…“). Dann stehen sie mit Text in einem
  /// Menue „Mehr“; breit bleiben sie als Symbole.
  List<Widget> _schmalOderBreit(BuildContext context, List<IconButton> knoepfe, {List<Widget> immer = const []}) {
    if (Fensterklasse.von(context) != Fensterklasse.kompakt) return [...immer, ...knoepfe];
    return [
      ...immer,
      PopupMenuButton<int>(
        tooltip: 'Mehr',
        icon: const Icon(Icons.more_vert),
        onCanceled: _steuerung.fokus,
        onSelected: (i) {
          knoepfe[i].onPressed?.call();
          _steuerung.fokus();
        },
        itemBuilder: (_) => [
          for (var i = 0; i < knoepfe.length; i++)
            PopupMenuItem(
              value: i,
              child: ListTile(contentPadding: EdgeInsets.zero, leading: knoepfe[i].icon, title: Text(knoepfe[i].tooltip ?? '')),
            ),
        ],
      ),
    ];
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _steuerung.dispose();
    _kanalWarten?.cancel();
    _abo?.cancel();
    _spice.trennen();
    super.dispose();
  }
}

/// Die Gesten in Kurzform (Hilfe beim ersten Start und in den Einstellungen).
class GestenHilfe extends StatelessWidget {
  const GestenHilfe({super.key});

  static const zeilen = [
    (Icons.touch_app, 'Tippen', 'Klick'),
    (Icons.ads_click, 'Zweimal tippen', 'Doppelklick'),
    (Icons.back_hand_outlined, 'Lange drücken', 'Rechtsklick'),
    (Icons.swipe, 'Ziehen', 'Markieren, verschieben'),
    (Icons.swipe_vertical, 'Zwei Finger ziehen', 'Scrollen'),
    (Icons.pinch, 'Zwei Finger spreizen', 'Vergrössern, dann mit einem Finger verschieben'),
    (Icons.keyboard, 'Tastatur oben', 'Tippen, dazu Esc, Strg, Pfeile, F-Tasten'),
  ];

  @override
  Widget build(BuildContext context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (icon, geste, wirkung) in zeilen)
            ListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              leading: Icon(icon),
              title: Text(geste),
              subtitle: Text(wirkung),
            ),
          Text('Touchpad-Modus und diese Hilfe: Einstellungen (Regler oben).',
              style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}
