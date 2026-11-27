// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:rosenweg_basis/rosenweg_basis.dart';

import 'anmeldung/linux_schluesselbund.dart';

/// Was die App von sich sagt; Anmeldung, Schluesselbund, Protokoll und
/// Updater kommen aus rosenweg_basis.
const vmApp = RosenwegApp(
  kennung: 'ch.rosenweg4303.vm',
  name: 'Rosenweg Virtuelle Computer',
  ordner: 'rosenweg-vm',
  beschreibung: 'Die eigenen virtuellen Computer im Haus öffnen – im Haus und unterwegs.',
  quelle: 'https://github.com/Rosenweg/rosenweg-vm',
  logo: AssetImage('assets/logo/rosenweg-vm-512.png'),
);

/// EIN Schluesselbund-Eintrag fuer alles (Anmeldung, Karten-Sitzung,
/// Geraetekennung, Tastatur) – derselbe Eintrag `rosenweg_vm` wie bis 1.1.0,
/// niemand muss sich neu anmelden. Die alten Einzel-Eintraege von 1.0 werden
/// beim ersten Lesen uebernommen.
///
/// Unter Linux zuerst den Secret Service fragen ([PruefenderSpeicher]): ohne
/// nutzbaren Schluesselbund nur im Speicher, ohne Fenster von libsecret.
final vmSpeicher = Schluesselbund('rosenweg_vm', speicher: Platform.isLinux ? PruefenderSpeicher() : null, alteEintraege: const {
  'refresh_token': 'rosenweg_refresh_token',
  'angemeldet_am': 'rosenweg_angemeldet_am',
  'geraet': 'rosenweg_geraet',
});
