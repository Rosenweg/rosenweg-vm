// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:ui' show AppExitResponse, PlatformDispatcher;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart';

import 'app_zustand.dart';
import 'native/rwtunnel.dart';
import 'oberflaeche/start_seite.dart';
import 'vm_app.dart';

/// Wie `rosenwegStarten` der Basis (Logdatei, Fehlerfang, Anmeldung,
/// Updater, Rahmen mit Anmeldetor) – dazu, was nur die VM-App braucht:
/// Absturzdatei der Go-Laufzeit vor dem ersten Tunnel und das Abmelden des
/// Tunnels beim Schliessen.
void main() {
  Protokoll.einrichten(vmApp.ordner);
  RosenwegSitzung? s;
  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      Protokoll.schreiben('Start ${vmApp.name} (${kDebugMode ? 'Debug' : 'Release'})');
      // Go-Laufzeit: nicht aufgefangene panics zusaetzlich in die Logdatei.
      final p = Protokoll.pfad;
      if (p != null) {
        try {
          RwTunnel.i.absturzdatei(p);
        } catch (e, st) {
          Protokoll.schreiben('librwtunnel nicht geladen', e, st);
        }
      }
      FlutterError.onError = (d) {
        FlutterError.presentError(d);
        Protokoll.schreiben('Flutter-Fehler', d.exception, d.stack);
      };
      PlatformDispatcher.instance.onError = (e, st) {
        Protokoll.schreiben('Unerwarteter Fehler', e, st);
        s?.unerwartet(e);
        return true; // behandelt: App laeuft weiter
      };
      s = vmSitzung();
      s!.starten();
      final a = RosenwegAktualisierung(vmApp)..starten();
      runApp(RosenwegVm(sitzung: s!, aktualisierung: a));
    },
    (e, st) {
      Protokoll.schreiben('Unerwarteter Fehler', e, st);
      s?.unerwartet(e);
    },
  );
}

/// Anmeldung wie Salz/Profil: Karte, QR, „Mit dem Handy anmelden“,
/// Rosenweg-Konto; still per Kerberos an Stationen und in der Domaene.
/// Im Testbetrieb (RW_TEST_SPICE) ohne Anmeldung.
RosenwegSitzung vmSitzung() => AppZustand.testSpice.isNotEmpty
    ? RosenwegSitzung(vmApp, speicher: vmSpeicher, transport: const _OhneApi())
    : RosenwegSitzung(vmApp, speicher: vmSpeicher);

/// Die laufende Seite hinter dem Anmeldetor (fuer das Abmelden des Tunnels
/// beim Schliessen der App).
AppZustand? _aktuell;

class RosenwegVm extends StatefulWidget {
  const RosenwegVm({super.key, required this.sitzung, this.aktualisierung});
  final RosenwegSitzung sitzung;
  final RosenwegAktualisierung? aktualisierung;

  @override
  State<RosenwegVm> createState() => _RosenwegVmState();
}

class _RosenwegVmState extends State<RosenwegVm> {
  late final AppLifecycleListener _lebenslauf;

  @override
  void initState() {
    super.initState();
    // Beim Schliessen (Desktop: Fenster zu, Cmd+Q) den Tunnel-Peer abmelden,
    // damit der Schluessel sofort ungueltig ist. Hoechstens 3 Sekunden — eine
    // haengende Verbindung soll das Schliessen nicht aufhalten; dann raeumt
    // der Gateway nach wenigen Minuten ohne Lebenszeichen selbst auf.
    _lebenslauf = AppLifecycleListener(
      onExitRequested: () async {
        Protokoll.schreiben('Beenden angefordert (Fenster zu / Cmd+Q)');
        await _aktuell?.schliessen().timeout(const Duration(seconds: 3), onTimeout: () {});
        return AppExitResponse.exit;
      },
      // Telefone beenden Apps oft ohne Rueckfrage; dort zaehlt "abgetrennt".
      onDetach: () => _aktuell?.schliessen(),
    );
  }

  @override
  void dispose() {
    _lebenslauf.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RosenwegRahmen(
        sitzung: widget.sitzung,
        aktualisierung: widget.aktualisierung,
        inhalt: (_) => VmHaupt(sitzung: widget.sitzung),
      );
}

/// Inhalt, sobald angemeldet: baut den Tunnel auf und zeigt die Liste. Geht
/// die Anmeldung verloren (Abmelden, abgelaufen), verschwindet diese Seite
/// und mit ihr der Tunnel.
class VmHaupt extends StatefulWidget {
  const VmHaupt({super.key, required this.sitzung});
  final RosenwegSitzung sitzung;

  @override
  State<VmHaupt> createState() => _VmHauptState();
}

class _VmHauptState extends State<VmHaupt> {
  late final AppZustand _zustand = AppZustand(widget.sitzung);

  @override
  void initState() {
    super.initState();
    _aktuell = _zustand;
    _zustand.starten();
  }

  @override
  void dispose() {
    if (identical(_aktuell, _zustand)) _aktuell = null;
    final z = _zustand;
    z.schliessen().whenComplete(z.dispose);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => StartSeite(zustand: _zustand);
}

/// Testbetrieb: keine Haupt-API.
class _OhneApi implements Transport {
  const _OhneApi();
  @override
  Future<ApiAntwort> senden(String methode, String pfad, {Object? koerper}) async => (status: 503, json: null);
}
