// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/konfig.dart';
import 'package:rosenweg_vm/netz/haus_erkennung.dart';
import 'package:rosenweg_vm/netz/netzlage.dart';

/// Nachgebauter DNS-Server auf 127.0.0.1: antwortet je nach [art].
Future<RawDatagramSocket> dnsServer(String art, {List<String> txt = const []}) async {
  final s = await RawDatagramSocket.bind(InternetAddress.loopbackIPv4, 0);
  s.listen((ev) {
    if (ev != RawSocketEvent.read) return;
    final d = s.receive();
    if (d == null || art == 'stumm') return;
    final q = d.data;
    final antwort = BytesBuilder()
      // ID (bei 'fremde-id' verfaelscht), Flags: Antwort + RD + RA, RCODE
      ..add([art == 'fremde-id' ? q[0] ^ 0xff : q[0], q[1], 0x81, art == 'nxdomain' ? 0x83 : 0x80])
      ..add([0, 1, 0, art == 'nxdomain' ? 0 : 1, 0, 0, 0, 0])
      ..add(q.sublist(12)); // Frage zurueck
    if (art != 'nxdomain') {
      final rdata = BytesBuilder();
      for (final t in txt) {
        rdata
          ..addByte(t.length)
          ..add(t.codeUnits);
      }
      final r = rdata.toBytes();
      antwort
        ..add([0xc0, 0x0c, 0, 16, 0, 1, 0, 0, 0, 60, r.length >> 8, r.length & 0xff])
        ..add(r);
    }
    s.send(antwort.toBytes(), d.address, d.port);
  });
  return s;
}

Future<bool> pruefen(RawDatagramSocket s, {Duration zeit = const Duration(milliseconds: 1500)}) =>
    HausErkennung(server: () async => [InternetAddress.loopbackIPv4], zeit: zeit, port: s.port).imHaus();

void main() {
  test('Treffer: exakter Wert', () async {
    final s = await dnsServer('ok', txt: [Konfig.hausDnsWert]);
    expect(await pruefen(s), isTrue);
    s.close();
  });

  test('Treffer: Wert in zwei Teilstrings', () async {
    final s = await dnsServer('ok', txt: ['Rosenweg', ' GBT']);
    expect(await pruefen(s), isTrue);
    s.close();
  });

  test('fremder Wert', () async {
    for (final w in ['Anderes Haus', 'rosenweg gbt', 'Rosenweg GBT ']) {
      final s = await dnsServer('ok', txt: [w]);
      expect(await pruefen(s), isFalse, reason: w);
      s.close();
    }
  });

  test('keine Antwort: nach der Zeitgrenze unterwegs', () async {
    final s = await dnsServer('stumm');
    final uhr = Stopwatch()..start();
    expect(await pruefen(s, zeit: const Duration(milliseconds: 300)), isFalse);
    expect(uhr.elapsedMilliseconds, lessThan(1500));
    s.close();
  });

  test('NXDOMAIN (oeffentlicher DNS) und fremde ID', () async {
    for (final art in ['nxdomain', 'fremde-id']) {
      final s = await dnsServer(art, txt: [Konfig.hausDnsWert]);
      expect(await pruefen(s, zeit: const Duration(milliseconds: 400)), isFalse, reason: art);
      s.close();
    }
  });

  test('keine DNS-Server bekannt (z. B. iOS heute)', () async {
    expect(await HausErkennung(server: () async => const []).imHaus(), isFalse);
  });

  test('resolv.conf lesen', () {
    final l = resolvConfLesen('# x\nsearch a\nnameserver 100.64.2.1\nnameserver fe80::1%en0\n nameserver 127.0.0.53\n');
    expect(l.map((a) => a.address), ['100.64.2.1', 'fe80::1', '127.0.0.53']);
  });

  group('Endpunkt waehlen', () {
    Future<(Lage?, List<String>)> waehlen(bool dns, {required bool internGeht, required bool externGeht}) async {
      final gesetzt = <String>[];
      final l = await endpunktWaehlen(
        dnsImHaus: dns,
        intern: '100.64.2.36:51831',
        extern: 'kooperation.rosenweg4303.ch:51831',
        setzen: gesetzt.add,
        erreichbar: (l) async => l == Lage.imHaus ? internGeht : externGeht,
      );
      return (l, gesetzt);
    }

    test('DNS-Treffer, Handshake intern geht: im Haus', () async {
      final (l, g) = await waehlen(true, internGeht: true, externGeht: true);
      expect(l, Lage.imHaus);
      expect(g, ['100.64.2.36:51831']);
    });

    test('DNS vorgetaeuscht, Handshake intern scheitert: zurueck auf oeffentlich', () async {
      final (l, g) = await waehlen(true, internGeht: false, externGeht: true);
      expect(l, Lage.unterwegs);
      expect(g, ['100.64.2.36:51831', 'kooperation.rosenweg4303.ch:51831']);
    });

    test('kein Treffer: oeffentlich zuerst', () async {
      final (l, g) = await waehlen(false, internGeht: true, externGeht: true);
      expect(l, Lage.unterwegs);
      expect(g, ['kooperation.rosenweg4303.ch:51831']);
    });

    test('kein Treffer, oeffentlich geht nicht: LAN nur als Rueckfall', () async {
      final (l, g) = await waehlen(false, internGeht: true, externGeht: false);
      expect(l, Lage.imHaus);
      expect(g.last, '100.64.2.36:51831');
    });

    test('nichts geht', () async {
      final (l, _) = await waehlen(true, internGeht: false, externGeht: false);
      expect(l, isNull);
    });
  });

  test('echter System-Resolver antwortet ohne Absturz', () async {
    // Auf dem Entwicklungsrechner ausser Haus: false; im Haus mit Eintrag: true.
    final r = await HausErkennung().imHaus();
    expect(r, isA<bool>());
  });
}
