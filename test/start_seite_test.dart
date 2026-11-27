// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart'
    show ApiAntwort, RosenwegSitzung, Schluesselbund, Transport, rosenwegThema;
import 'package:rosenweg_vm/app_zustand.dart';
import 'package:rosenweg_vm/gateway/gateway.dart';
import 'package:rosenweg_vm/native/rwtunnel.dart';
import 'package:rosenweg_vm/oberflaeche/start_seite.dart';
import 'package:rosenweg_vm/vm_app.dart';

class _OhneApi implements Transport {
  const _OhneApi();
  @override
  Future<ApiAntwort> senden(String methode, String pfad, {Object? koerper}) async => (status: 503, json: null);
}

Future<AppZustand> zeigen(WidgetTester t, Size groesse, {String name = 'Büro-PC'}) async {
  t.view.physicalSize = groesse;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  FlutterSecureStorage.setMockInitialValues({});
  final sitzung = RosenwegSitzung(vmApp, speicher: Schluesselbund('rosenweg_vm_test'), transport: const _OhneApi());
  final z = AppZustand(sitzung)
    ..computer = [Computer(vmid: 101, name: name, laeuft: true)]
    ..phase = Phase.liste;
  await t.pumpWidget(MaterialApp(theme: rosenwegThema(Brightness.light), home: StartSeite(zustand: z)));
  await t.pumpAndSettle();
  return z;
}

void main() {
  testWidgets('Desktop: Liste als Karte mittig, hoechstens 760 px breit', (t) async {
    await zeigen(t, const Size(1920, 1080));
    final zeile = t.getRect(find.byType(ListTile));
    expect(find.byType(Card), findsOneWidget);
    expect(zeile.width, lessThanOrEqualTo(760));
    expect(zeile.center.dx, closeTo(960, 1));
  });

  testWidgets('schmal (unter 840 px): Liste ueber die ganze Breite wie bisher', (t) async {
    await zeigen(t, const Size(800, 800));
    expect(find.byType(Card), findsNothing);
    expect(t.getRect(find.byType(ListTile)).width, 800);
  });

  testWidgets('400 px (Test win11-1): Titel und Namen ungekuerzt, Lage nur als Symbol', (t) async {
    await zeigen(t, const Size(400, 700), name: 'display-test-mit-langem-namen');
    final titel = t.renderObject<RenderParagraph>(find.text('Meine Computer'));
    expect(titel.didExceedMaxLines, isFalse);
    final name = t.renderObject<RenderParagraph>(find.text('display-test-mit-langem-namen'));
    expect(name.didExceedMaxLines, isFalse);
    expect(find.byType(Chip), findsNothing);
    expect(find.text('läuft'), findsOneWidget);
  });

  testWidgets('Fehler: verstaendlicher Satz, Technik unter "Details"', (t) async {
    final z = await zeigen(t, const Size(800, 800));
    final f = vmFehler(StateError('innen kaputt'));
    z
      ..phase = Phase.fehler
      ..fehler = f.text
      ..fehlerDetails = f.details;
    z.notifyListeners();
    await t.pumpAndSettle();
    expect(find.textContaining('Bad state'), findsNothing);
    expect(find.text('Nochmals'), findsOneWidget);
    await t.tap(find.text('Details'));
    await t.pumpAndSettle();
    expect(find.textContaining('innen kaputt'), findsOneWidget);
  });

  test('vmFehler: Fehler der App bleiben, Go-Fehler nur in Details', () {
    expect(vmFehler(GatewayFehler(403, 'Kein Zugriff')).details, isNull);
    final t = vmFehler(TunnelFehler('wireguard: handshake did not complete', technisch: true));
    expect(t.text, contains('sichere Verbindung'));
    expect(t.details, contains('handshake'));
  });
}
