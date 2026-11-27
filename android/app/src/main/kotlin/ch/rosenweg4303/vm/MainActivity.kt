// SPDX-License-Identifier: GPL-3.0-or-later
package ch.rosenweg4303.vm

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// Anmeldung (Ruecksprung) und DNS-Server des aktiven Netzes liefert das
// Plugin von rosenweg_basis (RosenwegBasisPlugin, RuecksprungActivity).
//
// Kanal "rosenweg_vm/ordner": "Ordner freigeben" braucht einen echten Pfad
// (der WebDAV-Server phodav liest das Dateisystem, keine content://-URIs).
// Ab Android 11 geht das nur mit "Zugriff auf alle Dateien", den die Person
// in den Einstellungen selbst erteilt; davor mit den alten Speicherrechten.
class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "rosenweg_vm/ordner").setMethodCallHandler { call, ergebnis ->
            when (call.method) {
                "speicher" -> ergebnis.success(Environment.getExternalStorageDirectory().absolutePath)
                "erlaubt" -> ergebnis.success(erlaubt())
                "erlauben" -> {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                        val i = Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, Uri.parse("package:$packageName"))
                        try {
                            startActivity(i)
                        } catch (e: Exception) {
                            startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
                        }
                    } else {
                        requestPermissions(arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE, Manifest.permission.WRITE_EXTERNAL_STORAGE), 41)
                    }
                    ergebnis.success(null)
                }
                else -> ergebnis.notImplemented()
            }
        }
    }

    private fun erlaubt(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) Environment.isExternalStorageManager()
        else checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) == PackageManager.PERMISSION_GRANTED
}
