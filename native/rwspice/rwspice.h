// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * rwspice — duenne C-Schicht zwischen spice-client-glib und der Flutter-App.
 *
 * Warum eine eigene Schicht statt spice-glib direkt per dart:ffi:
 *  - spice-glib ist GObject mit Signalen und Koroutinen; das alles in Dart
 *    nachzubauen waere viel Bindungscode fuer wenig Nutzen.
 *  - spice-glib verlangt, dass alle Aufrufe im GLib-Hauptkontext laufen. Diese
 *    Schicht nimmt Aufrufe aus jedem Thread an und reicht sie dorthin.
 *  - Bild, Ton und USB werden hier zu ein paar flachen Funktionen; die
 *    Plattformteile (Texture, Audiogeraet) haengen nur an dieser Schicht.
 *
 * Lizenz: spice-client-glib, GLib, usbredir und libusb stehen unter der LGPL.
 * Deshalb wird spice-glib immer DYNAMISCH gelinkt (auch rwspice selbst ist
 * eine eigene dynamische Bibliothek), damit sie austauschbar bleibt.
 *
 * Eine Sitzung zur Zeit: die App zeigt immer einen Computer im Vordergrund.
 */
#ifndef RWSPICE_H
#define RWSPICE_H

#include <stdint.h>

#if defined(_WIN32)
#define RW_EXPORT __declspec(dllexport)
#else
#define RW_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define RW_SPICE_ABI 6

/* Kanalarten fuer RW_E_KANAL: was der Computer anbietet (Ton nur mit
 * audio0 driver=spice, USB nur mit usbN: spice in Proxmox). */
enum {
    RW_K_WIEDERGABE = 1,
    RW_K_AUFNAHME   = 2,
    RW_K_USB        = 3,
    RW_K_ORDNER     = 4, /* WebDAV (im Gast spice-webdavd) */
};

/* Ereignisse an die App. Kommen aus dem GLib-Thread; Dart nimmt sie mit
 * NativeCallable.listener entgegen (asynchron, threadsicher). */
enum {
    RW_E_VERBUNDEN   = 1,  /* Hauptkanal steht */
    RW_E_BILD_GROESSE = 2, /* a = Breite, b = Hoehe */
    RW_E_BILD_WEG    = 3,  /* Bildflaeche abgebaut (z. B. Neustart der Maschine) */
    RW_E_GETRENNT    = 4,  /* a = Grund (RW_G_*) */
    RW_E_MAUSMODUS   = 5,  /* a = 1 Server (relativ), 2 Client (absolut) */
    RW_E_TON         = 6,  /* a = 1 Wiedergabe laeuft, 0 steht */
    RW_E_MIKROFON    = 7,  /* a = 1 Gast nimmt auf, 0 nicht; b = 1 Mikrofon offen */
    RW_E_USB         = 8,  /* USB-Liste hat sich geaendert */
    RW_E_USB_FEHLER  = 9,  /* Durchreichen fehlgeschlagen; Text via rw_spice_letzter_fehler */
    RW_E_AGENT       = 10, /* a = 1 Gast-Agent da (Groesse anpassen, Zwischenablage) */
    RW_E_KANAL       = 11, /* Kanal angeboten: a = RW_K_*, b = 1 neu / 0 weg */
    RW_E_ORDNER      = 12, /* a = 1 Ordner freigegeben, 0 nicht; b = 1 Fehler (Text via rw_spice_letzter_fehler) */
    RW_E_ZWISCHENABLAGE = 13, /* Gast hat Text in die Zwischenablage gelegt; holen mit rw_spice_zwischenablage_holen */
};

enum {
    RW_G_NORMAL     = 0,
    RW_G_TLS        = 1,
    RW_G_ANMELDUNG  = 2, /* Ticket falsch/abgelaufen */
    RW_G_VERBINDUNG = 3, /* nicht erreichbar, Proxy */
    RW_G_ANDERES    = 4,
};

typedef void (*rw_spice_ereignis_fn)(int32_t art, int32_t a, int32_t b, int32_t c, int32_t d);

RW_EXPORT int32_t rw_spice_abi(void);

/* Einmal beim Start. eigene_schleife = 1: rwspice startet einen Thread mit der
 * GLib-Hauptschleife (macOS, Windows, Android, iOS). 0: die Schleife laeuft
 * schon (Linux: das GTK-Fenster von Flutter dreht den GLib-Standardkontext). */
RW_EXPORT void rw_spice_start(int32_t eigene_schleife, rw_spice_ereignis_fn cb);

/* Verbindet mit den Angaben aus /nodes/{node}/qemu/{vmid}/spiceproxy.
 * Leere/NULL-Zeichenketten und 0-Ports werden weggelassen. */
RW_EXPORT int32_t rw_spice_verbinden(const char *host, int32_t port, int32_t tls_port,
                                     const char *passwort, const char *proxy,
                                     const char *ca_pem, const char *host_subject);
RW_EXPORT void rw_spice_trennen(void);

/* Kopiert das aktuelle Bild (BGRA, Alpha 0xFF, Zeilenlaenge = Breite*4) nach ziel.
 * Rueckgabe 1 = neues Bild, 0 = unveraendert, -1 = kein Bild oder ziel zu klein
 * (breite/hoehe sind dann trotzdem gesetzt). Darf aus jedem Thread kommen. */
RW_EXPORT int32_t rw_spice_bild_abholen(uint8_t *ziel, int32_t ziel_bytes,
                                        int32_t *breite, int32_t *hoehe);

/* Eingaben. tasten = SPICE_MOUSE_BUTTON_MASK_* (links 1, mitte 2, rechts 4). */
RW_EXPORT void rw_spice_maus_position(int32_t x, int32_t y, int32_t tasten);
RW_EXPORT void rw_spice_maus_bewegung(int32_t dx, int32_t dy, int32_t tasten);
/* taste = SPICE_MOUSE_BUTTON_* (1 links, 2 mitte, 3 rechts, 4 Rad hoch, 5 Rad runter) */
RW_EXPORT void rw_spice_maus_taste(int32_t taste, int32_t gedrueckt, int32_t tasten);
/* PC-Scancode Satz 1; erweiterte Tasten (E0) als 0x100 | code. */
RW_EXPORT void rw_spice_taste(int32_t scancode, int32_t gedrueckt);
/* Feststelltaste im Gast ausschalten, falls an (Zeichenmodus). */
RW_EXPORT void rw_spice_feststell_aus(void);
/* Bitte an den Gast, die Aufloesung anzupassen (braucht den spice-vdagent;
 * VDAgentMonitorsConfig ueber den Hauptkanal). Breite wird auf Achterschritte
 * abgerundet; unter 320x200 geschieht nichts. */
RW_EXPORT void rw_spice_bildschirm_groesse(int32_t breite, int32_t hoehe);

/* Zwischenablage (Text, spice-vdagent). an = 0: in keine Richtung.
 * setzen: Text vom Geraet dem Gast anbieten (NULL/leer = nichts anbieten).
 * holen: zuletzt vom Gast gekommener Text (mit rw_spice_frei freigeben). */
RW_EXPORT void rw_spice_zwischenablage_an(int32_t an);
RW_EXPORT void rw_spice_zwischenablage_setzen(const char *text);
RW_EXPORT char *rw_spice_zwischenablage_holen(void);

/* Ton: Wiedergabe an/aus; Mikrofon nur, wenn die Person es erlaubt hat. */
RW_EXPORT void rw_spice_ton(int32_t wiedergabe, int32_t mikrofon);

/* USB: JSON-Liste [{"id":"<bus>-<adresse>","name":"…","verbunden":true,"moeglich":true,"grund":""}] */
RW_EXPORT char *rw_spice_usb_liste(void);
RW_EXPORT void rw_spice_usb_schalten(const char *id, int32_t an);

/* Ordner freigeben (SPICE WebDAV). pfad NULL/leer = Freigabe beenden.
 * rw_spice_ordner_moeglich: 0, wenn spice-glib ohne phodav gebaut ist. */
RW_EXPORT int32_t rw_spice_ordner_moeglich(void);
RW_EXPORT void rw_spice_ordner(const char *pfad, int32_t nur_lesen);

/* Letzte Fehlermeldung (Text gehoert dem Aufrufer, mit rw_spice_frei freigeben). */
RW_EXPORT char *rw_spice_letzter_fehler(void);

/* Meldungen von spice-glib (Warnungen, Fehler; mit debug != 0 auch Debug)
 * und Kanalfehler zusaetzlich an diese Datei anhaengen. Vor rw_spice_start
 * aufrufen; nur einmal wirksam. Passwoerter/Tickets schreibt rwspice nie. */
RW_EXPORT void rw_spice_logdatei(const char *pfad, int32_t debug);
RW_EXPORT void rw_spice_frei(char *p);

#ifdef __cplusplus
}
#endif
#endif
