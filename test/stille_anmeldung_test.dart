// SPDX-License-Identifier: GPL-3.0-or-later
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart' show KeinKerberos, KerberosTicket, StilleAnmeldung, StilleAntwort;
import 'package:rosenweg_vm/anmeldung/rosenweg_konto.dart';
import 'package:rosenweg_vm/anmeldung/schluesselbund.dart';
import 'package:rosenweg_vm/konfig.dart';

/// Leerer Speicher im Arbeitsspeicher (statt libsecret/Keychain).
class _Speicher extends FlutterSecureStorage {
  _Speicher();
  final werte = <String, String>{};
  @override
  Future<String?> read({required String key, AppleOptions? iOptions, AndroidOptions? aOptions,
          LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async =>
      werte[key];
  @override
  Future<void> write({required String key, required String? value, AppleOptions? iOptions,
      AndroidOptions? aOptions, LinuxOptions? lOptions, WebOptions? webOptions,
      AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    if (value == null) {
      werte.remove(key);
    } else {
      werte[key] = value;
    }
  }

  @override
  Future<void> delete({required String key, AppleOptions? iOptions, AndroidOptions? aOptions,
      LinuxOptions? lOptions, WebOptions? webOptions, AppleOptions? mOptions, WindowsOptions? wOptions}) async {
    werte.remove(key);
  }
}

class _Ticket implements KerberosTicket {
  final gefragt = <String>[];
  @override
  Future<String?> token(String dienst, {Duration zeit = const Duration(seconds: 8)}) async {
    gefragt.add(dienst);
    return 'c3BuZWdv';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ohne stille Anmeldung (macOS, Telefone): false, nichts gespeichert', () async {
    final s = _Speicher();
    final konto = RosenwegKonto(speicher: Schluesselbund(s), still: () => null);
    expect(await konto.stillAnmelden(), isFalse);
    expect(s.werte, isEmpty);
  });

  test('ohne Ticket (nicht in der Domaene): false, kein Browser, nichts gespeichert', () async {
    final s = _Speicher();
    final urls = <Uri>[];
    final konto = RosenwegKonto(
      speicher: Schluesselbund(s),
      still: () => StilleAnmeldung(
        authentik: Uri.parse('https://authentik.rosenweg4303.ch/'),
        quelle: Konfig.kerberosQuelle,
        dienst: Konfig.kerberosDienst,
        ticket: const KeinKerberos(),
        holen: (url, kopf) async {
          urls.add(url);
          return StilleAntwort(401, kopf: {'www-authenticate': 'Negotiate'});
        },
      ),
    );
    expect(await konto.stillAnmelden(), isFalse);
    expect(urls.single.path, '/source/kerberos/ad-kerberos/');
    expect(s.werte, isEmpty);
  });

  test('mit Ticket: SPNEGO fuer den Authentik-Dienst, dann Autorisierung mit localhost:0', () async {
    final ticket = _Ticket();
    final urls = <Uri>[];
    final kopfe = <Map<String, String>>[];
    final konto = RosenwegKonto(
      speicher: Schluesselbund(_Speicher()),
      still: () => StilleAnmeldung(
        authentik: Uri.parse('https://authentik.rosenweg4303.ch/'),
        quelle: Konfig.kerberosQuelle,
        dienst: Konfig.kerberosDienst,
        ticket: ticket,
        holen: (url, kopf) async {
          urls.add(url);
          kopfe.add(kopf);
          if (url.path == '/source/kerberos/ad-kerberos/') {
            if (kopf['Authorization'] == null) return StilleAntwort(401, kopf: {'www-authenticate': 'Negotiate'});
            return StilleAntwort(302, kopf: {'location': '/if/user/'});
          }
          // Autorisierung: Authentik will hier zustimmen lassen -> nicht still.
          return StilleAntwort(302, kopf: {'location': '/if/flow/default-provider-authorization-explicit-consent/?x=1'});
        },
      ),
    );
    // Der Zustimmungs-Ablauf antwortet nicht (holen liefert wieder 302 auf
    // dieselbe Oberflaeche) -> bricht nach hoechstens 25 Schritten ab.
    expect(await konto.stillAnmelden(), isFalse);
    expect(ticket.gefragt, [Konfig.kerberosDienst]);
    expect(kopfe[1]['Authorization'], 'Negotiate c3BuZWdv');
    final auth = urls.firstWhere((u) => u.path == '/application/o/authorize/');
    expect(auth.queryParameters['client_id'], 'rosenweg-apps');
    expect(auth.queryParameters['redirect_uri'], RosenwegKonto.stillerRuecksprung);
    expect(auth.queryParameters['code_challenge_method'], 'S256');
  });
}
