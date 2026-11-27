// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart';

import 'gateway/gateway.dart';
import 'native/rwtunnel.dart';
import 'netz/netzlage.dart';

/// Was nach der Anmeldung kommt. Die Anmeldung selbst (Karte, QR, „Mit dem
/// Handy anmelden“, Rosenweg-Konto, still per Kerberos an Stationen und in
/// der Windows-Domaene) macht [RosenwegSitzung] aus rosenweg_basis; davor
/// steht ihr [AnmeldeTor]. Seit 1.2.0 hat die App keine eigenen Anmelde-Phasen.
enum Phase {
  /// Verbindung zum Haus wird aufgebaut.
  tunnel,

  /// Liste steht.
  liste,

  /// Etwas ging schief; Text in [AppZustand.fehler], Knopf "Nochmals".
  fehler,
}

/// Der Ablauf hinter dem Anmeldetor an einer Stelle:
///   angemeldet (RosenwegSitzung) → Tunnel zum vm-gateway → Liste
class AppZustand extends ChangeNotifier {
  AppZustand(this.sitzung) {
    netz = Netzlage(sitzung.zugang)..addListener(notifyListeners);
  }

  final RosenwegSitzung sitzung;
  late final Netzlage netz;

  Phase phase = Phase.tunnel;

  /// Satz fuer die Person; [fehlerDetails] = Technik unter "Details".
  String? fehler;
  String? fehlerDetails;
  List<Computer> computer = const [];

  Gateway? get gateway => netz.gateway;

  /// Nur fuer die Entwicklung: --dart-define=RW_TEST_SPICE=127.0.0.1:5912
  /// zeigt einen Testcomputer (z. B. spice-server/test-display-no-ssl),
  /// ohne Anmeldung und ohne Hausnetz.
  static const testSpice = String.fromEnvironment('RW_TEST_SPICE');

  bool _weg = false;

  @override
  void notifyListeners() {
    if (!_weg) super.notifyListeners();
  }

  /// Nach [schliessen] aufrufen; laeuft noch ein Aufbau, kommt er still ins Leere.
  @override
  void dispose() {
    _weg = true;
    netz.removeListener(notifyListeners);
    super.dispose();
  }

  void _setzen(Phase p, [String? f, String? details]) {
    if (_weg) return;
    if (p != phase || f != null) {
      Protokoll.schreiben('Phase ${p.name}${f != null ? ' — $f' : ''}${details != null ? ' ($details)' : ''}');
    }
    phase = p;
    fehler = f;
    fehlerDetails = details;
    notifyListeners();
  }

  void _fehler(Object e) {
    final f = vmFehler(e);
    _setzen(Phase.fehler, f.text, f.details);
  }

  /// Sobald die Sitzung bereit ist (VmHaupt): Tunnel, dann Liste.
  Future<void> starten() async {
    try {
      if (testSpice.isNotEmpty) {
        netz.lage = Lage.test;
        computer = [Computer(vmid: 0, name: 'Testcomputer (lokal)', laeuft: true)];
        _setzen(Phase.liste);
        return;
      }
      if (sitzung.geteiltesTelefon) {
        // Kein eigenes Token auf geteilten Telefonen (Rosenweg Geraet meldet an);
        // einen Tunnel mit dem Token der Person gibt es dort nicht.
        _setzen(Phase.fehler, 'Auf den geteilten Rosenweg-Telefonen gibt es die virtuellen Computer nicht.');
        return;
      }
      _setzen(Phase.tunnel);
      await netz.aufbauen();
      if (_weg) {
        // Seite schon weg (abgemeldet, waehrend der Tunnel entstand): gleich wieder zu.
        await netz.abbauen();
        return;
      }
      await aktualisieren();
    } on TunnelFehler catch (e) {
      if (e.status == 401) {
        _abgelehnt();
        return;
      }
      _fehler(e);
    } catch (e) {
      _fehler(e);
    }
  }

  Future<void> aktualisieren() async {
    final g = gateway;
    if (g == null) return;
    try {
      computer = await g.computer();
      _setzen(Phase.liste);
    } on GatewayFehler catch (e) {
      if (e.status == 401) {
        await netz.abbauen();
        _abgelehnt();
        return;
      }
      _fehler(e);
    } catch (e) {
      _fehler(e);
    }
  }

  /// Anmeldung trotz Erneuern abgelehnt (abgelaufen, widerrufen, Karte
  /// entzogen): die Sitzung meldet einmal still neu an (Kerberos), sonst
  /// zeigt das Anmeldetor den Anmeldeschirm. Diese Seite wird dabei neu gebaut.
  void _abgelehnt() {
    Protokoll.schreiben('Anmeldung abgelehnt (401)');
    sitzung.nichtMehrAngemeldet();
  }

  Future<void> einschalten(Computer c) async {
    await gateway?.einschalten(c);
    // Proxmox meldet "laeuft" erst nach ein paar Sekunden.
    await Future<void>.delayed(const Duration(seconds: 3));
    await aktualisieren();
  }

  /// Knopf "Abmelden": Tunnel zu, dann die Sitzung (das Anmeldetor zeigt den
  /// Anmeldeschirm; "Mit Rosenweg-Konto anmelden" versucht es dort zuerst still).
  Future<void> abmelden() async {
    await netz.abbauen();
    computer = const [];
    await sitzung.abmelden();
  }

  /// Beim Schliessen der App und wenn die Anmeldung wegfaellt: Peer abmelden,
  /// damit der Tunnel-Schluessel sofort ungueltig ist. Die Anmeldung bleibt
  /// fuer den naechsten Start.
  Future<void> schliessen() => netz.abbauen();
}

/// Fehler → Satz fuer die Person und Technik fuer "Details" (wie
/// [fehlerFuerPerson] der Basis, dazu die Fehler der VM-App). Vorher stand
/// der rohe Text auf dem Schirm (Test win11-1: "Bad state: …").
({String text, String? details}) vmFehler(Object e) {
  if (e is TunnelFehler && e.technisch) {
    return (text: 'Die sichere Verbindung ins Haus kam nicht zustande. Bitte nochmals versuchen.', details: e.text);
  }
  if (e is TunnelFehler || e is GatewayFehler) return (text: '$e', details: null);
  return fehlerFuerPerson(e);
}
