// SPDX-License-Identifier: GPL-3.0-or-later
package ch.rosenweg4303.rwtunnel;

/**
 * Telefonseite der Fernwartung (rwtunnel, Hoermodus) fuer Java. Gehoert zu
 * native/rwtunnel/jni/main.go (Rosenweg/rosenweg-vm) und wird von Rosenweg Geraet
 * unveraendert uebernommen, samt librwtunnel_jni.so.
 *
 * Alle Methoden liefern JSON; bei Fehlern {"fehler": "..."}. Blockierend nur warte().
 */
public final class RwFernwartung {
	private static boolean geladen;
	private static String ladeFehler = "";

	static {
		try {
			System.loadLibrary("rwtunnel_jni");
			geladen = true;
		} catch (Throwable t) {
			ladeFehler = t.getClass().getSimpleName() + ": " + t.getMessage();
		}
	}

	private RwFernwartung() {}

	/** Ist die Bibliothek fuer diese Architektur da? */
	public static boolean verfuegbar() { return geladen; }

	public static String ladeFehler() { return ladeFehler; }

	/** {"privat","oeffentlich"} (Base64, Curve25519). */
	public static native String schluesselpaar();

	/** {"oeffentlich"} zum privaten Schluessel. */
	public static native String oeffentlich(String privat);

	/** konfig: {private_key, peer_public, endpoint, adresse, gateway, keepalive}. */
	public static native String start(String konfig);

	/** {letzter_handshake, empfangen, gesendet, offen, verbindungen, letzte_zu, sitzung, anzeige, abgewiesen}. */
	public static native String zustand();

	/** Naechstes Ereignis {art: auf|zu|anzeige|stop, offen, zeit, anzeige} oder {art:""} nach ms. */
	public static native String warte(int ms);

	public static native String anstossen();

	public static native String netzWechsel();

	public static native String endpunkt(String endpoint);

	public static native String keepalive(int sekunden);

	public static native void stop();
}
