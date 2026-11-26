// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/foundation.dart';

import 'anmeldung/rosenweg_konto.dart';
import 'gateway/gateway.dart';
import 'netz/netzlage.dart';
import 'protokoll.dart';

enum Phase {
  /// Start: gespeicherte Anmeldung pruefen, sonst still mit Kerberos
  /// anmelden (Stationen, Windows in der Domaene).
  pruefen,

  /// Keine (oder eine ueber 30 Tage alte) Anmeldung: Knopf "Anmelden".
  kontoNoetig,

  /// Anmeldeseite ist im Browser offen.
  anmelden,

  /// Verbindung zum Haus wird aufgebaut.
  tunnel,

  /// Liste steht.
  liste,

  /// Etwas ging schief; Text in [AppZustand.fehler], Knopf "Nochmals".
  fehler,
}

/// Der ganze Ablauf an einer Stelle — EINE Anmeldung fuer alles:
///   Rosenweg-Konto (gespeichert <= 30 Tage, sonst still per Kerberos, sonst
///   Knopf/Browser) → Tunnel zum vm-gateway → Liste
class AppZustand extends ChangeNotifier {
  AppZustand({RosenwegKonto? konto}) : konto = konto ?? RosenwegKonto() {
    netz = Netzlage(this.konto)..addListener(notifyListeners);
  }

  final RosenwegKonto konto;
  late final Netzlage netz;

  Phase phase = Phase.pruefen;
  bool _neuStill = false;
  String? fehler;
  List<Computer> computer = const [];

  Gateway? get gateway => netz.gateway;

  /// Nur fuer die Entwicklung: --dart-define=RW_TEST_SPICE=127.0.0.1:5912
  /// zeigt einen Testcomputer (z. B. spice-server/test-display-no-ssl),
  /// ohne Anmeldung und ohne Hausnetz.
  static const testSpice = String.fromEnvironment('RW_TEST_SPICE');

  void _setzen(Phase p, [String? f]) {
    if (p != phase || f != null) Protokoll.schreiben('Phase ${p.name}${f != null ? ' — $f' : ''}');
    phase = p;
    fehler = f;
    notifyListeners();
  }

  Future<void> starten() async {
    try {
      _setzen(Phase.pruefen);
      if (testSpice.isNotEmpty) {
        netz.lage = Lage.test;
        computer = [Computer(vmid: 0, name: 'Testcomputer (lokal)', laeuft: true)];
        _setzen(Phase.liste);
        return;
      }
      // An einer Station (Domaenenanmeldung) ist die Person schon bekannt:
      // ohne Knopf und ohne Browser direkt zu den eigenen Computern.
      if (!await konto.angemeldet && !await konto.stillAnmelden()) {
        _setzen(Phase.kontoNoetig);
        return;
      }
      await _verbinden();
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  /// Nicht aufgefangener Fehler (main.dart): sichtbar machen statt still
  /// weiterlaufen oder enden. Den Pfad der Logdatei mit anzeigen.
  void unerwartet(Object e) {
    final p = Protokoll.pfad;
    _setzen(Phase.fehler, '$e${p != null ? '\n\nEinzelheiten: $p' : ''}');
  }

  /// Knopf "Mit Rosenweg-Konto anmelden". Erst still (Kerberos; z. B. nach
  /// "Abmelden" in der App), sonst im Browser.
  Future<void> anmelden() async {
    try {
      _setzen(Phase.pruefen);
      if (await konto.stillAnmelden()) {
        await _verbinden();
        return;
      }
      _setzen(Phase.anmelden);
      await konto.anmelden();
      await _verbinden();
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  Future<void> _verbinden() async {
    _setzen(Phase.tunnel);
    await netz.aufbauen();
    await aktualisieren();
  }

  Future<void> aktualisieren() async {
    final g = gateway;
    if (g == null) return;
    try {
      computer = await g.computer();
      _setzen(Phase.liste);
    } on GatewayFehler catch (e) {
      if (e.status == 401) {
        // Anmeldung abgelaufen oder widerrufen: einmal still neu (Kerberos),
        // sonst ehrlich zurueck zum Knopf.
        await netz.abbauen();
        await konto.abmelden();
        if (!_neuStill && await konto.stillAnmelden()) {
          _neuStill = true;
          try {
            await _verbinden();
          } finally {
            _neuStill = false;
          }
          return;
        }
        _setzen(Phase.kontoNoetig);
        return;
      }
      _setzen(Phase.fehler, '$e');
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  Future<void> einschalten(Computer c) async {
    await gateway?.einschalten(c);
    // Proxmox meldet "laeuft" erst nach ein paar Sekunden.
    await Future<void>.delayed(const Duration(seconds: 3));
    await aktualisieren();
  }

  /// Knopf "Abmelden". Bewusst ohne neuen Start: der wuerde an einer
  /// Station sofort wieder still anmelden. Der Knopf "Anmelden" danach
  /// versucht es zuerst still.
  Future<void> abmelden() async {
    await netz.abbauen();
    await konto.abmelden();
    computer = const [];
    _setzen(Phase.kontoNoetig);
  }

  /// Beim Schliessen der App: Peer abmelden, damit der Tunnel-Schluessel
  /// sofort ungueltig ist. Die Anmeldung (Refresh-Token) bleibt fuer den
  /// naechsten Start.
  Future<void> schliessen() => netz.abbauen();
}
