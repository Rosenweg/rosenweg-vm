// SPDX-License-Identifier: GPL-3.0-or-later
package ch.rosenweg4303.vm

import android.content.Context
import android.net.ConnectivityManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // DNS-Server des aktiven Netzes fuer die Erkennung "im Haus"
        // (lib/netz/haus_erkennung.dart). Android hat keine resolv.conf; die
        // Server stehen in den LinkProperties des aktiven Netzes.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "ch.rosenweg4303.vm/netz")
            .setMethodCallHandler { call, result ->
                if (call.method != "dnsServer") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val netz = cm.activeNetwork
                val server = netz?.let { cm.getLinkProperties(it)?.dnsServers }
                    ?.mapNotNull { it.hostAddress } ?: emptyList()
                result.success(server)
            }
    }
}
