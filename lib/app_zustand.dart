import 'package:flutter/foundation.dart';

import 'anmeldung/rosenweg_konto.dart';
import 'netz/netzlage.dart';
import 'proxmox/proxmox.dart';

enum Phase {
  /// Netz wird geprueft.
  pruefen,

  /// Unterwegs und noch kein Rosenweg-Konto: Knopf "Anmelden" zeigen.
  kontoNoetig,

  /// Tunnel wird aufgebaut.
  tunnel,

  /// Anmeldeseite von Proxmox ist im Browser offen.
  anmelden,

  /// Liste steht.
  liste,

  /// Etwas ging schief; Text in [AppZustand.fehler], Knopf "Nochmals".
  fehler,
}

/// Der ganze Ablauf an einer Stelle:
///   Netz pruefen → (unterwegs: Konto + Tunnel) → Proxmox-Anmeldung → Liste
class AppZustand extends ChangeNotifier {
  AppZustand() : konto = RosenwegKonto() {
    netz = Netzlage(konto)..addListener(notifyListeners);
  }

  final RosenwegKonto konto;
  late final Netzlage netz;
  Proxmox? proxmox;

  Phase phase = Phase.pruefen;
  String? fehler;
  List<Computer> computer = const [];

  /// Nur fuer die Entwicklung: --dart-define=RW_TEST_SPICE=127.0.0.1:5912
  /// zeigt zusaetzlich einen Testcomputer (z. B. spice-server/test-display-no-ssl),
  /// ohne Anmeldung und ohne Hausnetz.
  static const testSpice = String.fromEnvironment('RW_TEST_SPICE');

  void _setzen(Phase p, [String? f]) {
    phase = p;
    fehler = f;
    notifyListeners();
  }

  Future<void> starten() async {
    try {
      _setzen(Phase.pruefen);
      if (testSpice.isNotEmpty) {
        netz.lage = Lage.test;
        computer = [Computer(vmid: 0, knoten: '', name: 'Testcomputer (lokal)', laeuft: true)];
        _setzen(Phase.liste);
        return;
      }
      if (!await netz.direktPruefen()) {
        if (!await konto.angemeldet) {
          _setzen(Phase.kontoNoetig);
          return;
        }
        _setzen(Phase.tunnel);
        await netz.tunnelAufbauen();
      }
      await _proxmoxAnmelden();
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  /// Knopf "Mit Rosenweg-Konto anmelden" (nur unterwegs noetig).
  Future<void> kontoAnmelden() async {
    try {
      _setzen(Phase.anmelden);
      await konto.anmelden();
      _setzen(Phase.tunnel);
      await netz.tunnelAufbauen();
      await _proxmoxAnmelden();
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  Future<void> _proxmoxAnmelden() async {
    _setzen(Phase.anmelden);
    final p = Proxmox(netz.host!, proxy: netz.proxyFuerHttp);
    await p.anmelden();
    proxmox = p;
    await aktualisieren();
  }

  Future<void> aktualisieren() async {
    final p = proxmox;
    if (p == null) return;
    try {
      await p.ticketErneuern();
      computer = await p.computer();
      _setzen(Phase.liste);
    } catch (e) {
      _setzen(Phase.fehler, '$e');
    }
  }

  Future<void> einschalten(Computer c) async {
    await proxmox?.einschalten(c);
    // Proxmox meldet "running" erst nach ein paar Sekunden.
    await Future<void>.delayed(const Duration(seconds: 3));
    await aktualisieren();
  }

  Future<void> abmelden() async {
    await netz.abbauen(peerLoeschen: true);
    await konto.abmelden();
    proxmox = null;
    computer = const [];
    await starten();
  }

  @override
  void dispose() {
    netz.abbauen();
    super.dispose();
  }
}
