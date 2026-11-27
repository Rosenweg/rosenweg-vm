// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show rosenwegThema;
import 'package:rosenweg_vm/app_zustand.dart';
import 'package:rosenweg_vm/gateway/gateway.dart';
import 'package:rosenweg_vm/oberflaeche/start_seite.dart';

Future<void> zeigen(WidgetTester t, Size groesse) async {
  t.view.physicalSize = groesse;
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.reset);
  final z = AppZustand()
    ..computer = [Computer(vmid: 101, name: 'Büro-PC', laeuft: true)]
    ..phase = Phase.liste;
  await t.pumpWidget(MaterialApp(theme: rosenwegThema(Brightness.light), home: StartSeite(zustand: z)));
  await t.pumpAndSettle();
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
}
