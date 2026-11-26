// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:ffi';
import 'dart:io';

/// Laedt eine der beiden nativen Bibliotheken (rwspice, rwtunnel).
///
/// Reihenfolge:
///  1. neben der App (so wird ausgeliefert: macOS Contents/Frameworks,
///     Linux lib/, Windows neben der .exe, Android jniLibs),
///  2. Entwicklungsordner aus --dart-define=RW_NATIVE_DIR=…/native,
///  3. Suchpfad des Systems.
///
/// iOS linkt statisch (Go c-archive, spice-glib als Framework); dort genuegt
/// DynamicLibrary.process().
DynamicLibrary bibliothekLaden(String name) {
  if (Platform.isIOS) return DynamicLibrary.process();

  final datei = switch (Platform.operatingSystem) {
    'macos' => 'lib$name.dylib',
    'windows' => '$name.dll',
    _ => 'lib$name.so',
  };
  final versuche = <String>[];
  final exe = File(Platform.resolvedExecutable).parent.path;
  if (Platform.isMacOS) versuche.add('$exe/../Frameworks/$datei');
  if (Platform.isLinux) versuche.add('$exe/lib/$datei');
  if (Platform.isWindows) versuche.add('$exe\\$datei');

  const entwicklung = String.fromEnvironment('RW_NATIVE_DIR');
  if (entwicklung.isNotEmpty) {
    final unter = Platform.isMacOS ? 'macos' : Platform.isWindows ? 'windows' : 'linux';
    versuche.add('$entwicklung/$name/build/$unter/$datei');
  }
  versuche.add(datei);

  Object? letzter;
  for (final pfad in versuche) {
    try {
      return DynamicLibrary.open(pfad);
    } catch (e) {
      letzter = e;
    }
  }
  throw StateError('Bibliothek $datei nicht gefunden ($letzter)');
}
