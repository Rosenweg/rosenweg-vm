// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:rosenweg_basis/rosenweg_basis.dart' show RosenwegPlattform;

import '../konfig.dart';

/// "Im Haus?" — per DNS (Entscheid Stefan, 26.11.2026).
///
/// Der interne DNS (UniFi-Gateway) beantwortet den TXT-Eintrag
/// [Konfig.hausDnsName] mit [Konfig.hausDnsWert]; oeffentlich gibt es den
/// Eintrag nicht. Gefragt wird der Resolver, den das GERAET gerade benutzt —
/// nicht ein fest eingestellter Server: genau der sagt, in welchem Netz man ist.
///
/// Die Sicherheit haengt NICHT daran. Taeuscht ein fremdes Netz den Eintrag
/// vor, versucht die App den LAN-Endpunkt des Gateways, der WireGuard-Handshake
/// scheitert (der Schluessel des Gateways ist nicht faelschbar), und die App
/// faellt auf den oeffentlichen Endpunkt zurueck. Das Ergebnis ist nur ein
/// Hinweis fuer die Reihenfolge.
class HausErkennung {
  HausErkennung({Future<List<InternetAddress>> Function()? server, this.zeit = const Duration(milliseconds: 1500), this.port = 53})
      : _server = server ?? systemDnsServer;

  final Future<List<InternetAddress>> Function() _server;
  final Duration zeit;

  /// Nur fuer Tests anders als 53.
  final int port;

  Future<bool> imHaus() async {
    try {
      final server = await _server().timeout(zeit);
      if (server.isEmpty) return false;
      final werte = await txtAbfragen(Konfig.hausDnsName, server, zeit: zeit, port: port);
      return werte.contains(Konfig.hausDnsWert);
    } catch (_) {
      return false; // keine Antwort / Fehler = unterwegs
    }
  }
}

// ── System-DNS-Server je Plattform ───────────────────────────────────────

/// Die DNS-Server, die das Betriebssystem gerade benutzt.
///
/// - Linux: /etc/resolv.conf. Mit systemd-resolved steht dort 127.0.0.53 —
///   das ist gewollt: der lokale Resolver fragt dann die Server des aktuellen
///   Netzes.
/// - macOS: /etc/resolv.conf (von configd fuer das Hauptnetz gepflegt), sonst
///   `scutil --dns`.
/// - Windows: `Get-DnsClientServerAddress` (PowerShell), sonst `ipconfig /all`.
/// - Android: ConnectivityManager → LinkProperties.getDnsServers() des aktiven
///   Netzes, ueber das Plugin von rosenweg_basis (RosenwegPlattform.dnsServer).
/// - iOS: noch keiner (Kanal folgt mit der iOS-App, res_9_getservers aus
///   libresolv). Ohne Server gilt "unterwegs" — das ist sicher, nur der Weg
///   ist im Haus dann etwas laenger.
Future<List<InternetAddress>> systemDnsServer() async {
  if (Platform.isAndroid) return _adressen(await RosenwegPlattform.dnsServer());
  if (Platform.isIOS) return const [];
  if (Platform.isWindows) {
    try {
      final r = await Process.run('powershell', [
        '-NoProfile',
        '-Command',
        'Get-DnsClientServerAddress | Where-Object { \$_.ServerAddresses } | Select-Object -ExpandProperty ServerAddresses',
      ]);
      final l = _adressen(LineSplitter.split('${r.stdout}'));
      if (l.isNotEmpty) return l;
    } catch (_) {}
    final r = await Process.run('ipconfig', ['/all']);
    return _adressen(RegExp(r'DNS[^:\n]*:\s*([0-9a-fA-F.:%]+)').allMatches('${r.stdout}').map((m) => m[1]!));
  }
  final datei = File('/etc/resolv.conf');
  if (await datei.exists()) {
    final l = resolvConfLesen(await datei.readAsString());
    if (l.isNotEmpty) return l;
  }
  if (Platform.isMacOS) {
    final r = await Process.run('scutil', ['--dns']);
    return _adressen(RegExp(r'nameserver\[\d+\]\s*:\s*(\S+)').allMatches('${r.stdout}').map((m) => m[1]!));
  }
  return const [];
}

/// "nameserver X"-Zeilen; Zonen-Angabe (%en0) wird abgeschnitten.
List<InternetAddress> resolvConfLesen(String text) => _adressen(RegExp(r'^\s*nameserver\s+(\S+)', multiLine: true)
    .allMatches(text)
    .map((m) => m[1]!));

List<InternetAddress> _adressen(Iterable<String> roh) {
  final aus = <InternetAddress>[];
  for (final r in roh) {
    final a = InternetAddress.tryParse(r.trim().split('%').first);
    if (a != null && !aus.contains(a)) aus.add(a);
  }
  return aus;
}

// ── Kleiner DNS-Client (nur TXT, UDP) ────────────────────────────────────

/// Fragt [name] (TXT) bei allen [server] gleichzeitig; die erste gueltige
/// Antwort gilt. Liefert die TXT-Werte (Teilstrings eines Eintrags
/// zusammengesetzt). Leere Liste bei NXDOMAIN oder ohne Eintrag; wirft bei
/// Zeitueberschreitung.
///
/// Eigener Client statt Paket: es braucht genau eine Frage und eine Antwort,
/// und die gaengigen Dart-DNS-Pakete fragen feste Server (Google,
/// Cloudflare) — genau das darf hier nicht sein.
Future<List<String>> txtAbfragen(String name, List<InternetAddress> server,
    {Duration zeit = const Duration(milliseconds: 1500), int port = 53}) async {
  final id = Random.secure().nextInt(0x10000);
  final frage = dnsFrage(id, name, 16);
  final ergebnis = Completer<List<String>>();
  final sockel = <RawDatagramSocket>[];
  var offen = server.length;
  try {
    for (final s in server) {
      final sock = await RawDatagramSocket.bind(
          s.type == InternetAddressType.IPv6 ? InternetAddress.anyIPv6 : InternetAddress.anyIPv4, 0);
      sockel.add(sock);
      sock.listen((ev) {
        if (ev != RawSocketEvent.read) return;
        final d = sock.receive();
        if (d == null || d.address != s || ergebnis.isCompleted) return;
        final werte = dnsTxtLesen(d.data, id);
        if (werte != null) {
          ergebnis.complete(werte);
        } else if (--offen == 0) {
          ergebnis.completeError(const FormatException('keine gueltige Antwort'));
        }
      });
      sock.send(frage, s, port);
    }
    return await ergebnis.future.timeout(zeit);
  } finally {
    for (final s in sockel) {
      s.close();
    }
  }
}

/// DNS-Anfrage (RFC 1035), Rekursion erwuenscht.
Uint8List dnsFrage(int id, String name, int typ) {
  final b = BytesBuilder()
    ..add([id >> 8, id & 0xff, 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]);
  for (final teil in name.split('.').where((t) => t.isNotEmpty)) {
    final t = ascii.encode(teil);
    b
      ..addByte(t.length)
      ..add(t);
  }
  b.add([0, typ >> 8, typ & 0xff, 0, 1]);
  return b.toBytes();
}

/// Liest TXT-Werte aus einer Antwort. null = nicht unsere/kaputte Antwort.
List<String>? dnsTxtLesen(Uint8List d, int id) {
  try {
    if (d.length < 12 || ((d[0] << 8) | d[1]) != id || d[2] & 0x80 == 0) return null;
    final rcode = d[3] & 0x0f;
    if (rcode == 3) return const []; // NXDOMAIN: gibt es nicht
    if (rcode != 0) return null;
    // Abgeschnitten (TC): ueber UDP unvollstaendig. Fuer unseren kurzen Eintrag
    // kommt das nicht vor; dann lieber "keine Antwort" als ein halbes Ergebnis.
    if (d[2] & 0x02 != 0) return null;
    final qd = (d[4] << 8) | d[5], an = (d[6] << 8) | d[7];
    var p = 12;
    int nameUeberspringen(int p) {
      while (true) {
        final l = d[p];
        if (l == 0) return p + 1;
        if (l & 0xc0 == 0xc0) return p + 2;
        p += l + 1;
      }
    }

    for (var i = 0; i < qd; i++) {
      p = nameUeberspringen(p) + 4;
    }
    final werte = <String>[];
    for (var i = 0; i < an; i++) {
      p = nameUeberspringen(p);
      final typ = (d[p] << 8) | d[p + 1];
      final laenge = (d[p + 8] << 8) | d[p + 9];
      p += 10;
      if (typ == 16) {
        final sb = StringBuffer();
        var q = p;
        while (q < p + laenge) {
          final l = d[q];
          sb.write(utf8.decode(d.sublist(q + 1, q + 1 + l), allowMalformed: true));
          q += l + 1;
        }
        werte.add(sb.toString());
      }
      p += laenge;
    }
    return werte;
  } on RangeError {
    return null;
  }
}
