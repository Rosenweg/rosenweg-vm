import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rosenweg_vm/proxmox/proxmox.dart';
import 'package:rosenweg_vm/spice/scancodes.dart';

void main() {
  test('Scancodes: physische Tasten, nicht Zeichen', () {
    expect(scancode(PhysicalKeyboardKey.keyA), 0x1e);
    // Auf CH-Tastaturen liegt Z dort, wo US Y hat: die App schickt die Taste,
    // das Layout macht der Gast.
    expect(scancode(PhysicalKeyboardKey.keyZ), 0x2c);
    expect(scancode(PhysicalKeyboardKey.delete), 0x153);
    expect(scancode(PhysicalKeyboardKey.intlBackslash), 0x56);
    expect(scancode(PhysicalKeyboardKey.metaLeft), 0x15b);
  });

  test('SpiceZugang aus spiceproxy: Zeilenumbrueche im Zertifikat', () {
    final z = SpiceZugang.aus({
      'host': 'pvespiceproxy:abc:107:pve1:x',
      'tls-port': 61000,
      'password': 'geheim',
      'proxy': 'http://pve1.rosenweg4303.ch:3128',
      'ca': r'-----BEGIN CERTIFICATE-----\nAAA\n-----END CERTIFICATE-----\n',
      'host-subject': 'OU=PVE Cluster Node,O=Proxmox Virtual Environment,CN=pve1.rosenweg4303.ch',
    });
    expect(z.tlsPort, 61000);
    expect(z.ca, contains('\nAAA\n'));
    expect(z.ca, isNot(contains(r'\n')));
  });
}
