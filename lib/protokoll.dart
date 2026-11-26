// SPDX-License-Identifier: GPL-3.0-or-later
import 'dart:io';

/// Logdatei der App, damit Fehler nicht still verschwinden.
///
/// - macOS:   ~/Library/Logs/Rosenweg Virtuelle Computer/app.log
/// - Linux:   $XDG_STATE_HOME (sonst ~/.local/state)/rosenweg-vm/app.log
/// - Windows: %LOCALAPPDATA%\Rosenweg Virtuelle Computer\app.log
/// - Telefone: temporaerer Ordner der App
///
/// Nie Tokens, Schluessel oder Tickets hineinschreiben. Die Datei wird bei
/// ueber 1 MB beim Start einmal nach app.log.1 verschoben.
class Protokoll {
  Protokoll._();

  static String? _pfad;

  static String? get pfad => _pfad ??= _bestimmen();

  static String? _bestimmen() {
    try {
      final env = Platform.environment;
      final home = env['HOME'] ?? '';
      final String ordner;
      if (Platform.isMacOS && home.isNotEmpty) {
        ordner = '$home/Library/Logs/Rosenweg Virtuelle Computer';
      } else if (Platform.isLinux && home.isNotEmpty) {
        ordner = '${env['XDG_STATE_HOME'] ?? '$home/.local/state'}/rosenweg-vm';
      } else if (Platform.isWindows && (env['LOCALAPPDATA'] ?? '').isNotEmpty) {
        ordner = '${env['LOCALAPPDATA']}\\Rosenweg Virtuelle Computer';
      } else {
        ordner = '${Directory.systemTemp.path}/rosenweg-vm';
      }
      Directory(ordner).createSync(recursive: true);
      final datei = File('$ordner${Platform.pathSeparator}app.log');
      if (datei.existsSync() && datei.lengthSync() > 1024 * 1024) {
        datei.renameSync('${datei.path}.1');
      }
      return datei.path;
    } catch (_) {
      return null;
    }
  }

  /// Eine Zeile mit Zeitstempel. Wirft nie.
  static void schreiben(String text, [Object? fehler, StackTrace? stapel]) {
    final zeile = StringBuffer('${DateTime.now().toIso8601String()} $text');
    if (fehler != null) zeile.write(': $fehler');
    if (stapel != null) zeile.write('\n$stapel');
    // ignore: avoid_print
    stderr.writeln(zeile);
    final p = pfad;
    if (p == null) return;
    try {
      File(p).writeAsStringSync('$zeile\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}
