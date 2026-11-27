// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * rwspice — siehe rwspice.h fuer das Warum.
 *
 * Aufbau:
 *   Dart-Thread ──(Idle-Quelle)───────────► GLib-Thread: spice-glib
 *   GLib-Thread ──(Ereignis-Callback)──────► Dart (NativeCallable.listener)
 *   GLib-Thread ──(Kopie unter Mutex)──────► Bildpuffer ◄── Dart holt ab
 *   Audiothread (miniaudio) ◄─ Ringpuffer ◄─ GLib-Thread (Wiedergabe)
 *   Audiothread (miniaudio) ─► GLib-Thread ─► Gast (Mikrofon)
 */
#if defined(__linux__) && !defined(_GNU_SOURCE)
#define _GNU_SOURCE /* dladdr */
#endif
#include "rwspice.h"

#include <spice-client.h>
#include <spice/vd_agent.h>
#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <psapi.h>
#else
#include <dlfcn.h>
#endif
#ifdef __APPLE__
#include <TargetConditionals.h>
#if !TARGET_OS_IPHONE
#define RW_MACOS 1 /* macOS, nicht iOS/iPadOS (dort gibt es kein USB) */
#include <libusb.h>
#endif
#endif
#include <string.h>
#include <stdio.h>

#define MINIAUDIO_IMPLEMENTATION
/* Nur was gebraucht wird: kein Dekodieren von Dateien, keine Erzeugung. */
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_GENERATION
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#include "drittanbieter/miniaudio.h"

/* ── Zustand ─────────────────────────────────────────────────────────── */

static rw_spice_ereignis_fn ereignis_cb;
static GMainContext *kontext;
static GMainLoop *schleife;
static GThread *schleifen_thread;

static SpiceSession *sitzung;
static SpiceMainChannel *hauptkanal;
static SpiceInputsChannel *eingabekanal;
static SpiceChannel *bildkanal;
static SpiceRecordChannel *aufnahmekanal;
static SpiceChannel *webdavkanal;
static SpiceUsbDeviceManager *usb;

static GMutex fehler_mutex;
static char *letzter_fehler;

/* Bild: eigene Kopie, damit Dart lesen kann, ohne mit spice-glib um die
 * Primaerflaeche zu streiten. */
static GMutex bild_mutex;
static const guint8 *bild_quelle; /* gehoert spice-glib */
static int bild_breite, bild_hoehe, bild_zeile;
static guint8 *bild_puffer;       /* BGRA, Zeile = breite*4 */
static gboolean bild_neu;
static gint64 erstes_bild_seit; /* >0: neue Flaeche wartet auf ersten Inhalt */

/* Ton */
static gboolean ton_wiedergabe = TRUE;
static gboolean ton_mikrofon = FALSE;
static ma_device wiedergabe_geraet, aufnahme_geraet;
static gboolean wiedergabe_offen, aufnahme_offen;
static ma_pcm_rb wiedergabe_ring;
static gboolean wiedergabe_ring_da;
static int wiedergabe_kanaele, wiedergabe_rate;
static int aufnahme_kanaele, aufnahme_rate;
static gboolean gast_nimmt_auf;

static void melden(int32_t art, int32_t a, int32_t b, int32_t c, int32_t d) {
    if (ereignis_cb) ereignis_cb(art, a, b, c, d);
}

/* ── Logdatei ────────────────────────────────────────────────────────── */

static GMutex log_mutex;
static char *log_pfad;
static gboolean log_debug;

static void log_zeile(const char *bereich, const char *text) {
    if (!log_pfad) return;
    g_mutex_lock(&log_mutex);
    FILE *f = fopen(log_pfad, "a");
    if (f) {
        GDateTime *jetzt = g_date_time_new_now_local();
        char *zeit = g_date_time_format_iso8601(jetzt);
        fprintf(f, "%s rwspice %s: %s\n", zeit, bereich, text ? text : "");
        g_free(zeit);
        g_date_time_unref(jetzt);
        fclose(f);
    }
    g_mutex_unlock(&log_mutex);
}

static GLogWriterOutput log_schreiber(GLogLevelFlags stufe, const GLogField *felder, gsize n, gpointer _) {
    (void)_;
    gboolean wichtig = (stufe & (G_LOG_LEVEL_ERROR | G_LOG_LEVEL_CRITICAL | G_LOG_LEVEL_WARNING | G_LOG_LEVEL_MESSAGE)) != 0;
    if (wichtig || log_debug) {
        const char *bereich = "glib", *text = "";
        for (gsize i = 0; i < n; i++) {
            if (g_strcmp0(felder[i].key, "GLIB_DOMAIN") == 0 && felder[i].length < 0) bereich = felder[i].value;
            if (g_strcmp0(felder[i].key, "MESSAGE") == 0 && felder[i].length < 0) text = felder[i].value;
        }
        log_zeile(bereich, text);
    }
    return g_log_writer_default(stufe, felder, n, NULL);
}

void rw_spice_logdatei(const char *pfad, int32_t debug) {
    if (log_pfad || !pfad || !*pfad) return;
    log_pfad = g_strdup(pfad);
    log_debug = debug != 0;
    if (log_debug) spice_util_set_debug(TRUE);
    g_log_set_writer_func(log_schreiber, NULL, NULL);
}

static void fehler_setzen(const char *text) {
    g_mutex_lock(&fehler_mutex);
    g_free(letzter_fehler);
    letzter_fehler = g_strdup(text ? text : "");
    g_mutex_unlock(&fehler_mutex);
    log_zeile("fehler", text);
}

static const char *ereignis_name(SpiceChannelEvent ev) {
    switch (ev) {
    case SPICE_CHANNEL_OPENED: return "offen";
    case SPICE_CHANNEL_SWITCHING: return "wechselt";
    case SPICE_CHANNEL_CLOSED: return "geschlossen";
    case SPICE_CHANNEL_ERROR_CONNECT: return "ERROR_CONNECT";
    case SPICE_CHANNEL_ERROR_TLS: return "ERROR_TLS";
    case SPICE_CHANNEL_ERROR_LINK: return "ERROR_LINK";
    case SPICE_CHANNEL_ERROR_AUTH: return "ERROR_AUTH";
    case SPICE_CHANNEL_ERROR_IO: return "ERROR_IO";
    default: return "?";
    }
}

/* Jeder Kanal: Ereignis ins Log, Fehler mit Text von spice-glib. */
static void kanal_ereignis(SpiceChannel *k, SpiceChannelEvent ev, gpointer _) {
    (void)_;
    gint typ = 0, id = 0;
    g_object_get(k, "channel-type", &typ, "channel-id", &id, NULL);
    const GError *e = spice_channel_get_error(k);
    char *t = g_strdup_printf("Kanal %s#%d: %s%s%s", spice_channel_type_to_string(typ), id, ereignis_name(ev),
                              e ? " — " : "", e ? e->message : "");
    if (ev >= SPICE_CHANNEL_ERROR_CONNECT && !SPICE_IS_MAIN_CHANNEL(k)) fehler_setzen(t);
    else log_zeile("kanal", t);
    g_free(t);
}

/* Fuehrt fn im GLib-Thread aus; daten wird danach freigegeben.
 *
 * Bewusst eine Idle-Quelle und nicht g_main_context_invoke: invoke fuehrt die
 * Funktion SOFORT im aufrufenden Thread aus, wenn der Kontext gerade frei
 * ist — dann liefe spice-glib ploetzlich im Dart-Thread. Beim ersten Test am
 * 25.11.2026 genau so passiert (GLib-CRITICAL beim Start der Schleife). */
static void im_kontext_mit(GSourceFunc fn, gpointer daten, GDestroyNotify frei) {
    if (!kontext) { if (frei) frei(daten); return; }
    GSource *q = g_idle_source_new();
    g_source_set_priority(q, G_PRIORITY_DEFAULT);
    g_source_set_callback(q, fn, daten, frei);
    g_source_attach(q, kontext);
    g_source_unref(q);
}

static void im_kontext(GSourceFunc fn, gpointer daten) { im_kontext_mit(fn, daten, g_free); }

/* ── Hauptschleife ───────────────────────────────────────────────────── */

static gpointer schleife_laufen(gpointer _) {
    (void)_;
    /* spice-glib haengt alles an den Standardkontext; diesen hier drehen
     * genuegt, ein push_thread_default braucht es nicht. */
    g_main_loop_run(schleife);
    return NULL;
}

int32_t rw_spice_abi(void) { return RW_SPICE_ABI; }

#ifdef __APPLE__
/* Ausgelieferte App (macOS): spice-glib, GLib und GStreamer liegen als Kopie
 * in Contents/Frameworks. Ihre eingebauten Suchpfade zeigen aber noch auf den
 * Bau-Rechner (/opt/local/lib/gstreamer-1.0, /opt/local/lib/gio/modules).
 * Auf einem Mac mit MacPorts wuerden sonst fremde Module in den Prozess
 * geladen (falsche Version, mit Sandbox ohnehin verboten). Darum hier auf
 * Contents/PlugIns/{gstreamer-1.0,gio-modules} im Buendel umbiegen (gibt es
 * derzeit nicht = keine Module; Code gehoert dort hin, nicht in Resources). GStreamer-Plugins braucht rwspice nicht: Ton
 * macht miniaudio, Bild-Streams dekodiert spice-glib selbst (MJPEG); ohne
 * Plugins bietet spice-glib dem Server nur das an. Kein Hilfsprozess fuer den
 * Plugin-Scan (GST_REGISTRY_FORK=no). Im Entwicklungsbau (Bibliothek ausserhalb
 * eines .app) bleibt alles, wie es ist. */
static void buendel_pfade(void) {
    Dl_info info;
    if (!dladdr((const void *)buendel_pfade, &info) || !info.dli_fname) return;
    const char *f = info.dli_fname;
    const char *teil = strstr(f, ".app/Contents/Frameworks/");
    if (!teil) return;
    gchar *fw = g_strndup(f, (gsize)(teil - f) + strlen(".app/Contents"));
    gchar *gst = g_build_filename(fw, "PlugIns", "gstreamer-1.0", NULL);
    gchar *gio = g_build_filename(fw, "PlugIns", "gio-modules", NULL);
    g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0", gst, FALSE);
    g_setenv("GST_PLUGIN_PATH_1_0", gst, FALSE);
    g_setenv("GST_REGISTRY_FORK", "no", FALSE);
    g_setenv("GIO_MODULE_DIR", gio, FALSE);
    g_free(gst); g_free(gio); g_free(fw);
}
#endif

#ifdef _WIN32
/* Windows: spice-glib, GLib und GStreamer liegen als DLLs neben der .exe
 * (windows/installer/bauen.sh). Ihre eingebauten Suchpfade leiten sich aus
 * dem Ort der DLL ab (..\lib\gstreamer-1.0, ..\lib\gio\modules) und
 * koennten so fremde Module finden. Wie unter macOS auf leere Ordner neben
 * der DLL umbiegen; Plugins braucht rwspice nicht (siehe oben). */
static void buendel_pfade(void) {
    HMODULE ich = NULL;
    wchar_t w[MAX_PATH];
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                            (LPCWSTR)(void *)buendel_pfade, &ich)) return;
    DWORD n = GetModuleFileNameW(ich, w, MAX_PATH);
    if (n == 0 || n >= MAX_PATH) return;
    gchar *datei = g_utf16_to_utf8((const gunichar2 *)w, n, NULL, NULL, NULL);
    if (!datei) return;
    gchar *ordner = g_path_get_dirname(datei);
    gchar *gst = g_build_filename(ordner, "plugins", "gstreamer-1.0", NULL);
    gchar *gio = g_build_filename(ordner, "plugins", "gio-modules", NULL);
    g_setenv("GST_PLUGIN_SYSTEM_PATH_1_0", gst, FALSE);
    g_setenv("GST_PLUGIN_PATH_1_0", gst, FALSE);
    g_setenv("GST_REGISTRY_FORK", "no", FALSE);
    g_setenv("GIO_MODULE_DIR", gio, FALSE);
    g_free(gst); g_free(gio); g_free(ordner); g_free(datei);
}
#endif

void rw_spice_start(int32_t eigene_schleife, rw_spice_ereignis_fn cb) {
    ereignis_cb = cb;
    if (kontext) return;
#if defined(__APPLE__) || defined(_WIN32)
    buendel_pfade();
#endif
    /* spice-glib haengt seine Quellen an den Standardkontext. Darum genau den
     * drehen — im eigenen Thread, oder (Linux) gar nicht, weil GTK es tut. */
    kontext = g_main_context_default();
    if (eigene_schleife) {
        schleife = g_main_loop_new(kontext, FALSE);
        schleifen_thread = g_thread_new("rwspice", schleife_laufen, NULL);
    }
}

/* ── Bild ────────────────────────────────────────────────────────────── */

static void bild_kopieren(int x, int y, int w, int h) {
    /* Nur xRGB/ARGB (32 Bit) kommt bei QXL als Primaerflaeche vor. Das vierte
     * Byte ist bei xRGB beliebig (oft 0); Flutter wuerde das als durchsichtig
     * zeichnen. Deshalb hier fest auf 0xFF. */
    if (!bild_quelle || !bild_puffer) return;
    if (x < 0) { w += x; x = 0; }
    if (y < 0) { h += y; y = 0; }
    if (x + w > bild_breite) w = bild_breite - x;
    if (y + h > bild_hoehe) h = bild_hoehe - y;
    if (w <= 0 || h <= 0) return;
    for (int zy = y; zy < y + h; zy++) {
        const guint32 *q = (const guint32 *)(bild_quelle + (gsize)zy * bild_zeile) + x;
        guint32 *z = (guint32 *)(bild_puffer + (gsize)zy * bild_breite * 4) + x;
        for (int i = 0; i < w; i++) z[i] = q[i] | 0xFF000000u;
    }
    bild_neu = TRUE;
}

static void primaer_neu(SpiceChannel *k, gint format, gint w, gint h, gint zeile,
                        gint shmid, gpointer daten, gpointer _) {
    (void)k; (void)shmid; (void)_;
    if (format != SPICE_SURFACE_FMT_32_xRGB && format != SPICE_SURFACE_FMT_32_ARGB) {
        fehler_setzen("Bildformat wird nicht unterstuetzt");
        return;
    }
    g_mutex_lock(&bild_mutex);
    bild_quelle = daten;
    bild_breite = w;
    bild_hoehe = h;
    bild_zeile = zeile;
    g_free(bild_puffer);
    bild_puffer = g_malloc0((gsize)w * h * 4);
    /* Nicht sofort kopieren: die neue Flaeche ist noch leer (schwarz). Erst
     * das erste display-invalidate bringt Inhalt; bis dahin zeigt die App
     * "Bild wird aufgebaut". */
    bild_neu = FALSE;
    erstes_bild_seit = g_get_monotonic_time();
    g_mutex_unlock(&bild_mutex);
    char *t = g_strdup_printf("neue Bildflaeche %dx%d (Format %d, Zeile %d)", w, h, format, zeile);
    log_zeile("bild", t);
    g_free(t);
    melden(RW_E_BILD_GROESSE, w, h, 0, 0);
}

static void primaer_weg(SpiceChannel *k, gpointer _) {
    (void)k; (void)_;
    g_mutex_lock(&bild_mutex);
    bild_quelle = NULL;
    erstes_bild_seit = 0;
    g_mutex_unlock(&bild_mutex);
    log_zeile("bild", "Bildflaeche abgebaut");
    melden(RW_E_BILD_WEG, 0, 0, 0, 0);
}

static void bild_ungueltig(SpiceChannel *k, gint x, gint y, gint w, gint h, gpointer _) {
    (void)k; (void)_;
    g_mutex_lock(&bild_mutex);
    bild_kopieren(x, y, w, h);
    gint64 seit = erstes_bild_seit;
    erstes_bild_seit = 0;
    g_mutex_unlock(&bild_mutex);
    if (seit > 0) {
        char *t = g_strdup_printf("erstes Bild nach %lld ms (Bereich %dx%d bei %d,%d)",
                                  (long long)((g_get_monotonic_time() - seit) / 1000), w, h, x, y);
        log_zeile("bild", t);
        g_free(t);
    }
}

int32_t rw_spice_bild_abholen(uint8_t *ziel, int32_t ziel_bytes, int32_t *breite, int32_t *hoehe) {
    int32_t r;
    g_mutex_lock(&bild_mutex);
    if (breite) *breite = bild_breite;
    if (hoehe) *hoehe = bild_hoehe;
    gsize noetig = (gsize)bild_breite * bild_hoehe * 4;
    if (!bild_puffer || !ziel || (gsize)ziel_bytes < noetig || noetig == 0) {
        r = -1;
    } else if (!bild_neu) {
        r = 0;
    } else {
        memcpy(ziel, bild_puffer, noetig);
        bild_neu = FALSE;
        r = 1;
    }
    g_mutex_unlock(&bild_mutex);
    return r;
}

/* ── Ton: Wiedergabe ─────────────────────────────────────────────────── */
/* spice-glib dekodiert Opus selbst und liefert PCM (S16). Darum genuegt hier
 * ein Ringpuffer und ein Ausgabegeraet; kein GStreamer noetig. Das ist der
 * Grund, warum Android/iOS/Windows spice-glib ohne GStreamer bauen koennen. */

static void wiedergabe_daten(ma_device *g, void *aus, const void *ein, ma_uint32 frames) {
    (void)g; (void)ein;
    ma_uint32 bpf = ma_get_bytes_per_frame(ma_format_s16, (ma_uint32)wiedergabe_kanaele);
    ma_uint8 *ziel = aus;
    ma_uint32 rest = frames;
    while (rest > 0) {
        ma_uint32 n = rest;
        void *quelle;
        if (ma_pcm_rb_acquire_read(&wiedergabe_ring, &n, &quelle) != MA_SUCCESS || n == 0) break;
        memcpy(ziel, quelle, (size_t)n * bpf);
        ma_pcm_rb_commit_read(&wiedergabe_ring, n);
        ziel += (size_t)n * bpf;
        rest -= n;
    }
    /* Unterlauf: Stille statt Knacken. */
    if (rest) memset(ziel, 0, (size_t)rest * bpf);
}

static void wiedergabe_schliessen(void) {
    if (wiedergabe_offen) {
        ma_device_uninit(&wiedergabe_geraet);
        wiedergabe_offen = FALSE;
    }
    if (wiedergabe_ring_da) {
        ma_pcm_rb_uninit(&wiedergabe_ring);
        wiedergabe_ring_da = FALSE;
    }
}

static void wiedergabe_start(SpicePlaybackChannel *k, gint format, gint kanaele, gint rate, gpointer _) {
    (void)k; (void)_;
    wiedergabe_schliessen();
    if (format != SPICE_AUDIO_FMT_S16 || !ton_wiedergabe) return;
    wiedergabe_kanaele = kanaele;
    wiedergabe_rate = rate;
    /* 400 ms Puffer: genug gegen Netzschwankungen im Tunnel, kurz genug,
     * dass Ton und Bild nicht spuerbar auseinanderlaufen. */
    if (ma_pcm_rb_init(ma_format_s16, (ma_uint32)kanaele, (ma_uint32)(rate * 4 / 10), NULL, NULL,
                       &wiedergabe_ring) != MA_SUCCESS) return;
    wiedergabe_ring_da = TRUE;
    ma_device_config c = ma_device_config_init(ma_device_type_playback);
    c.playback.format = ma_format_s16;
    c.playback.channels = (ma_uint32)kanaele;
    c.sampleRate = (ma_uint32)rate;
    c.dataCallback = wiedergabe_daten;
    if (ma_device_init(NULL, &c, &wiedergabe_geraet) != MA_SUCCESS) {
        fehler_setzen("Tonausgabe liess sich nicht oeffnen");
        return;
    }
    wiedergabe_offen = TRUE;
    ma_device_start(&wiedergabe_geraet);
    melden(RW_E_TON, 1, 0, 0, 0);
}

static void wiedergabe_daten_spice(SpicePlaybackChannel *k, gpointer daten, gint groesse, gpointer _) {
    (void)k; (void)_;
    if (!wiedergabe_ring_da) return;
    ma_uint32 bpf = ma_get_bytes_per_frame(ma_format_s16, (ma_uint32)wiedergabe_kanaele);
    ma_uint32 frames = (ma_uint32)groesse / bpf;
    const ma_uint8 *q = daten;
    while (frames > 0) {
        ma_uint32 n = frames;
        void *ziel;
        if (ma_pcm_rb_acquire_write(&wiedergabe_ring, &n, &ziel) != MA_SUCCESS || n == 0) break; /* voll: verwerfen */
        memcpy(ziel, q, (size_t)n * bpf);
        ma_pcm_rb_commit_write(&wiedergabe_ring, n);
        q += (size_t)n * bpf;
        frames -= n;
    }
}

static void wiedergabe_stop(SpicePlaybackChannel *k, gpointer _) {
    (void)k; (void)_;
    wiedergabe_schliessen();
    melden(RW_E_TON, 0, 0, 0, 0);
}

/* ── Ton: Mikrofon ───────────────────────────────────────────────────── */

typedef struct { gsize n; guint8 daten[]; } Aufnahme;

static gboolean aufnahme_senden(gpointer p) {
    Aufnahme *a = p;
    if (aufnahmekanal && gast_nimmt_auf && ton_mikrofon)
        spice_record_channel_send_data(aufnahmekanal, a->daten, a->n, 0);
    return G_SOURCE_REMOVE;
}

static void aufnahme_daten(ma_device *g, void *aus, const void *ein, ma_uint32 frames) {
    (void)g; (void)aus;
    gsize n = (gsize)frames * ma_get_bytes_per_frame(ma_format_s16, (ma_uint32)aufnahme_kanaele);
    Aufnahme *a = g_malloc(sizeof(Aufnahme) + n);
    a->n = n;
    memcpy(a->daten, ein, n);
    /* Senden nur im GLib-Kontext — spice-glib ist nicht threadsicher. */
    im_kontext(aufnahme_senden, a);
}

static void aufnahme_schliessen(void) {
    if (aufnahme_offen) {
        ma_device_uninit(&aufnahme_geraet);
        aufnahme_offen = FALSE;
    }
}

static void aufnahme_oeffnen(void) {
    aufnahme_schliessen();
    if (!gast_nimmt_auf || !ton_mikrofon) return;
    ma_device_config c = ma_device_config_init(ma_device_type_capture);
    c.capture.format = ma_format_s16;
    c.capture.channels = (ma_uint32)aufnahme_kanaele;
    c.sampleRate = (ma_uint32)aufnahme_rate;
    c.dataCallback = aufnahme_daten;
    if (ma_device_init(NULL, &c, &aufnahme_geraet) != MA_SUCCESS) {
        /* Meist fehlende Erlaubnis (macOS/iOS/Android fragen die Person). */
        fehler_setzen("Mikrofon liess sich nicht oeffnen");
        return;
    }
    aufnahme_offen = TRUE;
    ma_device_start(&aufnahme_geraet);
}

static void aufnahme_start(SpiceRecordChannel *k, gint format, gint kanaele, gint rate, gpointer _) {
    (void)k; (void)_;
    if (format != SPICE_AUDIO_FMT_S16) return;
    aufnahme_kanaele = kanaele;
    aufnahme_rate = rate;
    gast_nimmt_auf = TRUE;
    aufnahme_oeffnen();
    melden(RW_E_MIKROFON, 1, aufnahme_offen, 0, 0);
}

static void aufnahme_stop(SpiceRecordChannel *k, gpointer _) {
    (void)k; (void)_;
    gast_nimmt_auf = FALSE;
    aufnahme_schliessen();
    melden(RW_E_MIKROFON, 0, 0, 0, 0);
}

typedef struct { int wiedergabe, mikrofon; } TonWunsch;

static gboolean ton_setzen(gpointer p) {
    TonWunsch *t = p;
    ton_wiedergabe = t->wiedergabe != 0;
    ton_mikrofon = t->mikrofon != 0;
    if (!ton_wiedergabe) wiedergabe_schliessen();
    /* Mikrofon sofort an/aus, falls der Gast gerade aufnimmt. */
    aufnahme_oeffnen();
    if (gast_nimmt_auf) melden(RW_E_MIKROFON, 1, aufnahme_offen, 0, 0);
    return G_SOURCE_REMOVE;
}

void rw_spice_ton(int32_t wiedergabe, int32_t mikrofon) {
    TonWunsch *t = g_new(TonWunsch, 1);
    t->wiedergabe = wiedergabe;
    t->mikrofon = mikrofon;
    im_kontext(ton_setzen, t);
}

/* ── USB ─────────────────────────────────────────────────────────────── */
/* spice-glib bringt das Durchreichen (usbredir ueber libusb) schon mit. Hier
 * nur Liste und Schalter. Automatisches Durchreichen ist aus: ein Stick, der
 * eingesteckt wird, soll nicht ungefragt im Gast verschwinden. */

static void usb_geaendert(SpiceUsbDeviceManager *m, SpiceUsbDevice *d, gpointer _) {
    (void)m; (void)d; (void)_;
    melden(RW_E_USB, 0, 0, 0, 0);
}

static void usb_fehler(SpiceUsbDeviceManager *m, SpiceUsbDevice *d, GError *e, gpointer _) {
    (void)m; (void)d; (void)_;
    fehler_setzen(e ? e->message : "USB-Fehler");
    melden(RW_E_USB_FEHLER, 0, 0, 0, 0);
}

static void usb_fertig(GObject *quelle, GAsyncResult *r, gpointer _) {
    (void)_;
    GError *e = NULL;
    if (!spice_usb_device_manager_connect_device_finish(SPICE_USB_DEVICE_MANAGER(quelle), r, &e)) {
        fehler_setzen(e ? e->message : "USB-Geraet liess sich nicht durchreichen");
        melden(RW_E_USB_FEHLER, 0, 0, 0, 0);
        g_clear_error(&e);
    }
    melden(RW_E_USB, 0, 0, 0, 0);
}

static void usb_getrennt(GObject *quelle, GAsyncResult *r, gpointer _) {
    (void)_;
    GError *e = NULL;
    spice_usb_device_manager_disconnect_device_finish(SPICE_USB_DEVICE_MANAGER(quelle), r, &e);
    g_clear_error(&e);
    melden(RW_E_USB, 0, 0, 0, 0);
}

static char *usb_id(SpiceUsbDevice *d) {
    /* Bus und Adresse: eindeutig, solange das Geraet steckt — mehr braucht
     * der Schalter in der Oberflaeche nicht. */
    return spice_usb_device_get_description(d, "%4$d-%5$d");
}

/* macOS: Geraete, die ein Treiber von macOS haelt (Massenspeicher, Tastatur/
 * Maus, Ton, Netz/Modem, Video, Hub, Bluetooth), kann libusb ohne Root bzw.
 * das Entitlement com.apple.vm.device-access nicht abhaengen; der Versuch
 * setzt das Geraet zurueck ("nicht korrekt ausgeworfen"). Darum gar nicht
 * erst anbieten. Gelesen werden nur die zwischengespeicherten Deskriptoren
 * (kein Oeffnen, kein Reset). Liefert die Klasse als Text oder NULL. */
static const char *usb_mac_gesperrt(SpiceUsbDevice *d) {
#ifdef RW_MACOS
    libusb_device *ld = (libusb_device *)spice_usb_device_get_libusb_device(d);
    if (!ld) return NULL;
    struct libusb_device_descriptor dd;
    if (libusb_get_device_descriptor(ld, &dd) == 0) {
        if (dd.bDeviceClass == LIBUSB_CLASS_HUB) return "Hub";
        if (dd.bDeviceClass == LIBUSB_CLASS_WIRELESS) return "Funk/Bluetooth";
    }
    struct libusb_config_descriptor *cfg = NULL;
    if (libusb_get_active_config_descriptor(ld, &cfg) != 0 &&
        libusb_get_config_descriptor(ld, 0, &cfg) != 0) return NULL;
    const char *k = NULL;
    for (int i = 0; cfg && i < cfg->bNumInterfaces && !k; i++) {
        for (int a = 0; a < cfg->interface[i].num_altsetting && !k; a++) {
            switch (cfg->interface[i].altsetting[a].bInterfaceClass) {
            case LIBUSB_CLASS_MASS_STORAGE: k = "Massenspeicher"; break;
            case LIBUSB_CLASS_HID: k = "Tastatur/Maus (HID)"; break;
            case LIBUSB_CLASS_AUDIO: k = "Ton"; break;
            case LIBUSB_CLASS_COMM: case LIBUSB_CLASS_DATA: k = "Netz/Modem (CDC)"; break;
            case LIBUSB_CLASS_VIDEO: k = "Kamera"; break;
            case LIBUSB_CLASS_HUB: k = "Hub"; break;
            case LIBUSB_CLASS_WIRELESS: k = "Funk/Bluetooth"; break;
            default: break;
            }
        }
    }
    libusb_free_config_descriptor(cfg);
    return k;
#else
    (void)d;
    return NULL;
#endif
}

typedef struct { GMutex m; GCond c; gboolean fertig; char *json; } UsbAnfrage;

static void json_text(GString *s, const char *t) {
    g_string_append_c(s, '"');
    for (const char *p = t ? t : ""; *p; p++) {
        if (*p == '"' || *p == '\\') { g_string_append_c(s, '\\'); g_string_append_c(s, *p); }
        else if ((unsigned char)*p < 0x20) g_string_append_printf(s, "\\u%04x", *p);
        else g_string_append_c(s, *p);
    }
    g_string_append_c(s, '"');
}

static gboolean usb_liste_bauen(gpointer p) {
    UsbAnfrage *a = p;
    GString *s = g_string_new("[");
    if (usb) {
        GPtrArray *liste = spice_usb_device_manager_get_devices(usb);
        for (guint i = 0; liste && i < liste->len; i++) {
            SpiceUsbDevice *d = g_ptr_array_index(liste, i);
            char *id = usb_id(d);
            char *name = spice_usb_device_get_description(d, "%s %s");
            GError *e = NULL;
            const char *mac = usb_mac_gesperrt(d);
            gboolean moeglich = !mac && spice_usb_device_manager_can_redirect_device(usb, d, &e);
            if (i) g_string_append_c(s, ',');
            g_string_append(s, "{\"id\":");
            json_text(s, id);
            g_string_append(s, ",\"name\":");
            json_text(s, name);
            g_string_append_printf(s, ",\"verbunden\":%s,\"moeglich\":%s,\"grund\":",
                                   spice_usb_device_manager_is_device_connected(usb, d) ? "true" : "false",
                                   moeglich ? "true" : "false");
            json_text(s, e ? e->message : "");
            g_string_append(s, ",\"mac_treiber\":");
            json_text(s, mac ? mac : "");
            g_string_append_c(s, '}');
            g_clear_error(&e);
            g_free(id);
            g_free(name);
        }
        if (liste) g_ptr_array_unref(liste);
    }
    g_string_append_c(s, ']');
    g_mutex_lock(&a->m);
    a->json = g_string_free(s, FALSE);
    a->fertig = TRUE;
    g_cond_signal(&a->c);
    g_mutex_unlock(&a->m);
    return G_SOURCE_REMOVE;
}

char *rw_spice_usb_liste(void) {
    /* Synchron fuer den Aufrufer, aber gebaut im GLib-Kontext. */
    if (!kontext) return g_strdup("[]");
    if (g_main_context_is_owner(kontext)) {
        UsbAnfrage a = {0};
        usb_liste_bauen(&a);
        return a.json;
    }
    UsbAnfrage *a = g_new0(UsbAnfrage, 1);
    g_mutex_init(&a->m);
    g_cond_init(&a->c);
    im_kontext_mit(usb_liste_bauen, a, NULL);
    g_mutex_lock(&a->m);
    gint64 bis = g_get_monotonic_time() + 3 * G_TIME_SPAN_SECOND;
    while (!a->fertig)
        if (!g_cond_wait_until(&a->c, &a->m, bis)) break;
    char *json = a->fertig ? a->json : g_strdup("[]");
    gboolean fertig = a->fertig;
    g_mutex_unlock(&a->m);
    /* Bei Zeitueberschreitung laeuft usb_liste_bauen evtl. noch: dann bewusst
     * nicht freigeben (kleines Leck statt Absturz). */
    if (fertig) { g_mutex_clear(&a->m); g_cond_clear(&a->c); g_free(a); }
    return json;
}

typedef struct { int an; char id[64]; } UsbSchalter;

static gboolean usb_schalten(gpointer p) {
    UsbSchalter *u = p;
    if (!usb) return G_SOURCE_REMOVE;
    GPtrArray *liste = spice_usb_device_manager_get_devices(usb);
    for (guint i = 0; liste && i < liste->len; i++) {
        SpiceUsbDevice *d = g_ptr_array_index(liste, i);
        char *id = usb_id(d);
        if (g_strcmp0(id, u->id) == 0) {
            const char *mac = u->an ? usb_mac_gesperrt(d) : NULL;
            if (mac) {
                /* Nie ein Geraet anfassen, das macOS selbst nutzt. */
                char *t = g_strdup_printf("USB %s nicht weitergegeben: %s (macOS-Treiber)", id, mac);
                fehler_setzen(t);
                g_free(t);
                melden(RW_E_USB_FEHLER, 0, 0, 0, 0);
            } else if (u->an)
                spice_usb_device_manager_connect_device_async(usb, d, NULL, usb_fertig, NULL);
            else
                spice_usb_device_manager_disconnect_device_async(usb, d, NULL, usb_getrennt, NULL);
        }
        g_free(id);
    }
    if (liste) g_ptr_array_unref(liste);
    return G_SOURCE_REMOVE;
}

void rw_spice_usb_schalten(const char *id, int32_t an) {
    if (!id) return;
    UsbSchalter *u = g_new0(UsbSchalter, 1);
    u->an = an;
    g_strlcpy(u->id, id, sizeof u->id);
    im_kontext(usb_schalten, u);
}

/* ── Ordner freigeben (WebDAV) ───────────────────────────────────────── */

int32_t rw_spice_ordner_moeglich(void) {
    /* spice-glib bringt den WebDAV-Server nur mit, wenn es mit phodav gebaut
     * ist; ohne bleibt der Kanal stumm. */
#ifdef _WIN32
    /* kein RTLD_DEFAULT: alle geladenen Module des Prozesses fragen */
    HMODULE module[512];
    DWORD bytes = 0;
    if (!K32EnumProcessModules(GetCurrentProcess(), module, sizeof module, &bytes)) return 0;
    for (DWORD i = 0; i < bytes / sizeof(HMODULE) && i < 512; i++) {
        if (GetProcAddress(module[i], "phodav_server_new")) return 1;
    }
    return 0;
#else
    if (dlsym(RTLD_DEFAULT, "phodav_server_new")) return 1;
    /* Linux/Android: Dart laedt rwspice mit RTLD_LOCAL. phodav haengt dann
     * nur im Baum von spice-glib, nicht im globalen Namensraum; darum dort
     * nachsehen (dlsym mit Handle sucht auch in den Abhaengigkeiten). */
    Dl_info info;
    if (dladdr((const void *)spice_session_new, &info) && info.dli_fname) {
        void *h = dlopen(info.dli_fname, RTLD_LAZY | RTLD_NOLOAD);
        if (h) {
            int ja = dlsym(h, "phodav_server_new") != NULL;
            dlclose(h);
            if (ja) return 1;
        }
    }
    return 0;
#endif
}

static gboolean ordner_aktiv;

typedef struct { char *pfad; int nur_lesen; } OrdnerWahl;

static void ordner_frei(gpointer p) { OrdnerWahl *o = p; g_free(o->pfad); g_free(o); }

static gboolean ordner_setzen(gpointer p) {
    OrdnerWahl *o = p;
    if (!sitzung || !webdavkanal) {
        fehler_setzen("Ordner freigeben: kein WebDAV-Kanal (im Gast fehlt spice-webdavd)");
        melden(RW_E_ORDNER, 0, 1, 0, 0);
        return G_SOURCE_REMOVE;
    }
    gboolean offen = ordner_aktiv;
    /* Wechsel und Ende: Kanal zu; ein neuer Ordner gilt erst nach erneutem
     * Verbinden (phodav liest shared-dir beim Oeffnen). */
    spice_channel_disconnect(webdavkanal, SPICE_CHANNEL_CLOSED);
    g_object_set(sitzung, "shared-dir", o->pfad, "share-dir-ro", o->nur_lesen ? TRUE : FALSE, NULL);
    if (o->pfad && *o->pfad) {
        gboolean ok = spice_channel_connect(webdavkanal);
        char *t = g_strdup_printf("Ordner freigegeben%s: %s%s", o->nur_lesen ? " (nur lesen)" : "", o->pfad,
                                  ok ? "" : " — Kanal liess sich nicht oeffnen");
        if (ok) log_zeile("ordner", t); else fehler_setzen(t);
        ordner_aktiv = ok;
        g_free(t);
        melden(RW_E_ORDNER, ok ? 1 : 0, ok ? 0 : 1, 0, 0);
    } else {
        log_zeile("ordner", offen ? "Ordnerfreigabe beendet" : "Ordnerfreigabe aus");
        ordner_aktiv = FALSE;
        melden(RW_E_ORDNER, 0, 0, 0, 0);
    }
    return G_SOURCE_REMOVE;
}

void rw_spice_ordner(const char *pfad, int32_t nur_lesen) {
    OrdnerWahl *o = g_new0(OrdnerWahl, 1);
    o->pfad = (pfad && *pfad) ? g_strdup(pfad) : NULL;
    o->nur_lesen = nur_lesen;
    im_kontext_mit(ordner_setzen, o, ordner_frei);
}

/* ── Zwischenablage (spice-vdagent im Gast) ──────────────────────────── */
/* Nur Text und nur die Auswahl CLIPBOARD (Strg+C/Strg+V), nicht PRIMARY.
 * Gast -> Geraet: der Gast meldet "ich habe etwas" (grab), rwspice fragt
 * gleich nach UTF-8-Text und meldet RW_E_ZWISCHENABLAGE; die App holt ihn mit
 * rw_spice_zwischenablage_holen. Geraet -> Gast: die App gibt den Text mit
 * rw_spice_zwischenablage_setzen; rwspice meldet ihn dem Gast an und liefert
 * ihn, wenn der Gast einfuegt. Aus (rw_spice_zwischenablage_an(0)): nichts
 * geht in eine Richtung. */

static GMutex zw_mutex;
static gboolean zw_an = TRUE;
static char *zw_eigen;  /* Text vom Geraet, den der Gast holen darf */
static char *zw_gast;   /* zuletzt vom Gast gekommen */
static gboolean zw_angemeldet;

static gboolean agent_da(void) {
    gboolean da = FALSE;
    if (hauptkanal) g_object_get(hauptkanal, "agent-connected", &da, NULL);
    return da;
}

static void zw_anmelden(void) {
    if (!hauptkanal || !agent_da()) return;
    g_mutex_lock(&zw_mutex);
    gboolean hat = zw_an && zw_eigen != NULL;
    g_mutex_unlock(&zw_mutex);
    if (!hat) return;
    guint32 typ = VD_AGENT_CLIPBOARD_UTF8_TEXT;
    spice_main_channel_clipboard_selection_grab(hauptkanal, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD, &typ, 1);
    zw_angemeldet = TRUE;
}

static gboolean zw_gast_hat(SpiceMainChannel *k, guint auswahl, gpointer typen, guint n, gpointer _) {
    (void)_;
    if (auswahl != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || !zw_an) return TRUE;
    const guint32 *t = typen;
    for (guint i = 0; i < n; i++) {
        if (t[i] == VD_AGENT_CLIPBOARD_UTF8_TEXT) {
            zw_angemeldet = FALSE; /* der Gast hat jetzt die Ablage */
            spice_main_channel_clipboard_selection_request(k, auswahl, VD_AGENT_CLIPBOARD_UTF8_TEXT);
            break;
        }
    }
    return TRUE;
}

static void zw_gast_daten(SpiceMainChannel *k, guint auswahl, guint typ, gpointer daten, guint groesse, gpointer _) {
    (void)k; (void)_;
    if (auswahl != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || typ != VD_AGENT_CLIPBOARD_UTF8_TEXT || !zw_an) return;
    /* Windows-Gaeste haengen eine abschliessende NUL an */
    while (groesse > 0 && ((const char *)daten)[groesse - 1] == '\0') groesse--;
    if (!g_utf8_validate(daten, groesse, NULL)) return;
    g_mutex_lock(&zw_mutex);
    g_free(zw_gast);
    zw_gast = g_strndup(daten, groesse);
    g_mutex_unlock(&zw_mutex);
    melden(RW_E_ZWISCHENABLAGE, (int32_t)groesse, 0, 0, 0);
}

static gboolean zw_gast_will(SpiceMainChannel *k, guint auswahl, guint typ, gpointer _) {
    (void)_;
    if (auswahl != VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD || typ != VD_AGENT_CLIPBOARD_UTF8_TEXT) return FALSE;
    g_mutex_lock(&zw_mutex);
    char *t = zw_an && zw_eigen ? g_strdup(zw_eigen) : NULL;
    g_mutex_unlock(&zw_mutex);
    if (!t) return FALSE;
    spice_main_channel_clipboard_selection_notify(k, auswahl, typ, (const guchar *)t, strlen(t));
    g_free(t);
    return TRUE;
}

static gboolean zw_setzen(gpointer p) {
    (void)p;
    zw_anmelden();
    return G_SOURCE_REMOVE;
}

static gboolean zw_freigeben(gpointer p) {
    (void)p;
    if (hauptkanal && zw_angemeldet && agent_da())
        spice_main_channel_clipboard_selection_release(hauptkanal, VD_AGENT_CLIPBOARD_SELECTION_CLIPBOARD);
    zw_angemeldet = FALSE;
    return G_SOURCE_REMOVE;
}

void rw_spice_zwischenablage_an(int32_t an) {
    g_mutex_lock(&zw_mutex);
    zw_an = an != 0;
    if (!zw_an) { g_free(zw_eigen); zw_eigen = NULL; }
    g_mutex_unlock(&zw_mutex);
    if (!an) im_kontext(zw_freigeben, g_new0(char, 1));
}

void rw_spice_zwischenablage_setzen(const char *text) {
    g_mutex_lock(&zw_mutex);
    g_free(zw_eigen);
    zw_eigen = text && *text && zw_an ? g_strdup(text) : NULL;
    gboolean leer = zw_eigen == NULL;
    g_mutex_unlock(&zw_mutex);
    im_kontext(leer ? zw_freigeben : zw_setzen, g_new0(char, 1));
}

char *rw_spice_zwischenablage_holen(void) {
    g_mutex_lock(&zw_mutex);
    char *t = g_strdup(zw_gast ? zw_gast : "");
    g_mutex_unlock(&zw_mutex);
    return t;
}

/* ── Kanaele und Sitzung ─────────────────────────────────────────────── */

static int grund_aus(SpiceChannelEvent ev) {
    switch (ev) {
    case SPICE_CHANNEL_CLOSED: return RW_G_NORMAL;
    case SPICE_CHANNEL_ERROR_TLS: return RW_G_TLS;
    case SPICE_CHANNEL_ERROR_AUTH: return RW_G_ANMELDUNG;
    case SPICE_CHANNEL_ERROR_CONNECT: return RW_G_VERBINDUNG;
    default: return RW_G_ANDERES;
    }
}

static void hauptkanal_ereignis(SpiceChannel *k, SpiceChannelEvent ev, gpointer _) {
    (void)_;
    if (ev == SPICE_CHANNEL_OPENED) {
        melden(RW_E_VERBUNDEN, 0, 0, 0, 0);
        return;
    }
    if (ev == SPICE_CHANNEL_SWITCHING) return;
    const GError *e = spice_channel_get_error(k);
    char *t = g_strdup_printf("Hauptkanal %s%s%s", ereignis_name(ev), e ? ": " : "", e ? e->message : "");
    fehler_setzen(t);
    g_free(t);
    melden(RW_E_GETRENNT, grund_aus(ev), 0, 0, 0);
}

static void mausmodus(GObject *o, GParamSpec *ps, gpointer _) {
    (void)ps; (void)_;
    gint modus = 0;
    g_object_get(o, "mouse-mode", &modus, NULL);
    melden(RW_E_MAUSMODUS, modus == SPICE_MOUSE_MODE_CLIENT ? 2 : 1, 0, 0, 0);
}

static void agent(GObject *o, GParamSpec *ps, gpointer _) {
    (void)ps; (void)_;
    gboolean da = FALSE;
    g_object_get(o, "agent-connected", &da, NULL);
    zw_angemeldet = FALSE;
    if (da) zw_anmelden();
    melden(RW_E_AGENT, da ? 1 : 0, 0, 0, 0);
}

static int kanal_art(SpiceChannel *k) {
    if (SPICE_IS_PLAYBACK_CHANNEL(k)) return RW_K_WIEDERGABE;
    if (SPICE_IS_RECORD_CHANNEL(k)) return RW_K_AUFNAHME;
    if (SPICE_IS_USBREDIR_CHANNEL(k)) return RW_K_USB;
    if (SPICE_IS_WEBDAV_CHANNEL(k)) return RW_K_ORDNER;
    return 0;
}

static void kanal_neu(SpiceSession *s, SpiceChannel *k, gpointer _) {
    (void)s; (void)_;
    gint id = 0;
    g_object_get(k, "channel-id", &id, NULL);
    g_signal_connect(k, "channel-event", G_CALLBACK(kanal_ereignis), NULL);
    {
        gint typ = 0;
        g_object_get(k, "channel-type", &typ, NULL);
        char *t = g_strdup_printf("Kanal %s#%d angeboten", spice_channel_type_to_string(typ), id);
        log_zeile("kanal", t);
        g_free(t);
        int art = kanal_art(k);
        if (art) melden(RW_E_KANAL, art, 1, 0, 0);
    }

    if (SPICE_IS_MAIN_CHANNEL(k)) {
        hauptkanal = SPICE_MAIN_CHANNEL(k);
        g_signal_connect(k, "channel-event", G_CALLBACK(hauptkanal_ereignis), NULL);
        g_signal_connect(k, "notify::mouse-mode", G_CALLBACK(mausmodus), NULL);
        g_signal_connect(k, "notify::agent-connected", G_CALLBACK(agent), NULL);
        g_signal_connect(k, "main-clipboard-selection-grab", G_CALLBACK(zw_gast_hat), NULL);
        g_signal_connect(k, "main-clipboard-selection", G_CALLBACK(zw_gast_daten), NULL);
        g_signal_connect(k, "main-clipboard-selection-request", G_CALLBACK(zw_gast_will), NULL);
        return; /* verbindet die Sitzung selbst */
    }
    if (SPICE_IS_DISPLAY_CHANNEL(k)) {
        /* Mehrere Bildschirme spaeter; heute zaehlt der erste. */
        if (id != 0 || bildkanal) return;
        bildkanal = k;
        g_signal_connect(k, "display-primary-create", G_CALLBACK(primaer_neu), NULL);
        g_signal_connect(k, "display-primary-destroy", G_CALLBACK(primaer_weg), NULL);
        g_signal_connect(k, "display-invalidate", G_CALLBACK(bild_ungueltig), NULL);
        spice_channel_connect(k);
        return;
    }
    if (SPICE_IS_INPUTS_CHANNEL(k)) {
        eingabekanal = SPICE_INPUTS_CHANNEL(k);
        spice_channel_connect(k);
        return;
    }
    if (SPICE_IS_PLAYBACK_CHANNEL(k)) {
        g_signal_connect(k, "playback-start", G_CALLBACK(wiedergabe_start), NULL);
        g_signal_connect(k, "playback-data", G_CALLBACK(wiedergabe_daten_spice), NULL);
        g_signal_connect(k, "playback-stop", G_CALLBACK(wiedergabe_stop), NULL);
        spice_channel_connect(k);
        return;
    }
    if (SPICE_IS_RECORD_CHANNEL(k)) {
        /* Der Kanal steht immer; Ton fliesst nur, wenn die Person das
         * Mikrofon in der App freigibt (ton_mikrofon). */
        aufnahmekanal = SPICE_RECORD_CHANNEL(k);
        g_signal_connect(k, "record-start", G_CALLBACK(aufnahme_start), NULL);
        g_signal_connect(k, "record-stop", G_CALLBACK(aufnahme_stop), NULL);
        spice_channel_connect(k);
        return;
    }
    if (SPICE_IS_WEBDAV_CHANNEL(k)) {
        /* Erst verbinden, wenn die Person einen Ordner freigibt. */
        webdavkanal = k;
        return;
    }
    /* USB-Kanaele verbindet der UsbDeviceManager selbst; Cursor, WebDAV,
     * Smartcard und Port bleiben fuer den Anfang aus. */
}

static void kanal_weg(SpiceSession *s, SpiceChannel *k, gpointer _) {
    (void)s; (void)_;
    int art = kanal_art(k);
    if (art) melden(RW_E_KANAL, art, 0, 0, 0);
    if ((SpiceChannel *)hauptkanal == k) hauptkanal = NULL;
    if ((SpiceChannel *)eingabekanal == k) eingabekanal = NULL;
    if ((SpiceChannel *)aufnahmekanal == k) { aufnahmekanal = NULL; aufnahme_schliessen(); }
    if (webdavkanal == k) { webdavkanal = NULL; ordner_aktiv = FALSE; }
    if (bildkanal == k) {
        bildkanal = NULL;
        g_mutex_lock(&bild_mutex);
        bild_quelle = NULL;
        g_mutex_unlock(&bild_mutex);
    }
    if (SPICE_IS_PLAYBACK_CHANNEL(k)) wiedergabe_schliessen();
}

static void getrennt(SpiceSession *s, gpointer _) {
    (void)s; (void)_;
    melden(RW_E_GETRENNT, RW_G_NORMAL, 0, 0, 0);
}

static void sitzung_abbauen(void) {
    if (!sitzung) return;
    aufnahme_schliessen();
    wiedergabe_schliessen();
    g_signal_handlers_disconnect_by_data(sitzung, NULL);
    spice_session_disconnect(sitzung);
    g_object_unref(sitzung);
    sitzung = NULL;
    hauptkanal = NULL;
    eingabekanal = NULL;
    aufnahmekanal = NULL;
    bildkanal = NULL;
    usb = NULL;
    gast_nimmt_auf = FALSE;
    zw_angemeldet = FALSE;
    g_mutex_lock(&bild_mutex);
    bild_quelle = NULL;
    g_free(bild_puffer);
    bild_puffer = NULL;
    bild_breite = bild_hoehe = 0;
    bild_neu = FALSE;
    g_mutex_unlock(&bild_mutex);
}

typedef struct {
    char *host, *passwort, *proxy, *ca, *subject;
    int port, tls_port;
} Verbindung;

static void verbindung_frei(gpointer p) {
    Verbindung *v = p;
    g_free(v->host); g_free(v->passwort); g_free(v->proxy); g_free(v->ca); g_free(v->subject);
    g_free(v);
}

static gboolean verbinden(gpointer p) {
    Verbindung *v = p;
    sitzung_abbauen();
    sitzung = spice_session_new();
    g_object_set(sitzung, "host", v->host, NULL);
    if (v->port > 0) {
        char t[16]; g_snprintf(t, sizeof t, "%d", v->port);
        g_object_set(sitzung, "port", t, NULL);
    }
    if (v->tls_port > 0) {
        char t[16]; g_snprintf(t, sizeof t, "%d", v->tls_port);
        g_object_set(sitzung, "tls-port", t, NULL);
    }
    if (v->passwort && *v->passwort) g_object_set(sitzung, "password", v->passwort, NULL);
    if (v->proxy && *v->proxy) g_object_set(sitzung, "proxy", v->proxy, NULL);
    if (v->ca && *v->ca) {
        GByteArray *ca = g_byte_array_new();
        g_byte_array_append(ca, (const guint8 *)v->ca, (guint)strlen(v->ca));
        g_object_set(sitzung, "ca", ca, NULL);
        g_byte_array_unref(ca);
    }
    /* Proxmox gibt als "host" kein echter Name, sondern das Proxy-Ziel
     * (pvespiceproxy:…). Ein Abgleich mit dem Hostnamen schluege immer fehl;
     * geprueft wird deshalb der Zertifikats-Betreff des Knotens, wie
     * remote-viewer es mit host-subject aus der .vv-Datei tut. */
    if (v->subject && *v->subject) {
        g_object_set(sitzung, "cert-subject", v->subject,
                     "verify", SPICE_SESSION_VERIFY_SUBJECT, NULL);
    }
    /* Ton ja, USB ja, aber nichts automatisch durchreichen. */
    g_object_set(sitzung, "enable-audio", TRUE, "enable-usbredir", TRUE, NULL);
    g_signal_connect(sitzung, "channel-new", G_CALLBACK(kanal_neu), NULL);
    g_signal_connect(sitzung, "channel-destroy", G_CALLBACK(kanal_weg), NULL);
    g_signal_connect(sitzung, "disconnected", G_CALLBACK(getrennt), NULL);

    GError *e = NULL;
    usb = spice_usb_device_manager_get(sitzung, &e);
    if (usb) {
        g_object_set(usb, "auto-connect", FALSE, NULL);
        g_signal_connect(usb, "device-added", G_CALLBACK(usb_geaendert), NULL);
        g_signal_connect(usb, "device-removed", G_CALLBACK(usb_geaendert), NULL);
        g_signal_connect(usb, "device-error", G_CALLBACK(usb_fehler), NULL);
    } else {
        /* Ohne USB geht der Rest trotzdem; die Oberflaeche zeigt den Grund. */
        fehler_setzen(e ? e->message : "USB nicht verfuegbar");
        g_clear_error(&e);
    }

    if (!spice_session_connect(sitzung)) {
        fehler_setzen("Verbindung liess sich nicht starten");
        melden(RW_E_GETRENNT, RW_G_VERBINDUNG, 0, 0, 0);
    }
    return G_SOURCE_REMOVE;
}

int32_t rw_spice_verbinden(const char *host, int32_t port, int32_t tls_port,
                           const char *passwort, const char *proxy,
                           const char *ca_pem, const char *host_subject) {
    if (!kontext || !host || !*host || (port <= 0 && tls_port <= 0)) return -1;
    Verbindung *v = g_new0(Verbindung, 1);
    v->host = g_strdup(host);
    v->port = port;
    v->tls_port = tls_port;
    v->passwort = g_strdup(passwort);
    v->proxy = g_strdup(proxy);
    v->ca = g_strdup(ca_pem);
    v->subject = g_strdup(host_subject);
    /* Passwort/Ticket nach Gebrauch nicht im Speicher liegen lassen ist bei
     * einem Ticket mit wenigen Sekunden Laufzeit nicht der Aufwand wert;
     * es wird aber nie protokolliert. */
    im_kontext_mit(verbinden, v, verbindung_frei);
    return 0;
}

static gboolean trennen(gpointer p) {
    (void)p;
    sitzung_abbauen();
    return G_SOURCE_REMOVE;
}

void rw_spice_trennen(void) { im_kontext(trennen, g_new0(char, 1)); }

/* ── Eingaben ────────────────────────────────────────────────────────── */

typedef struct { int art; int a, b, c; } Eingabe;
enum { E_POS, E_BEW, E_TASTE_MAUS, E_TASTE, E_GROESSE, E_CAPS_AUS };

static gboolean eingabe(gpointer p) {
    Eingabe *e = p;
    switch (e->art) {
    case E_POS:
        if (eingabekanal) spice_inputs_channel_position(eingabekanal, e->a, e->b, 0, e->c);
        break;
    case E_BEW:
        if (eingabekanal) spice_inputs_channel_motion(eingabekanal, e->a, e->b, e->c);
        break;
    case E_TASTE_MAUS:
        if (!eingabekanal) break;
        if (e->b) spice_inputs_channel_button_press(eingabekanal, e->a, e->c);
        else spice_inputs_channel_button_release(eingabekanal, e->a, e->c);
        break;
    case E_TASTE:
        if (!eingabekanal) break;
        if (e->b) spice_inputs_channel_key_press(eingabekanal, (guint)e->a);
        else spice_inputs_channel_key_release(eingabekanal, (guint)e->a);
        break;
    case E_CAPS_AUS:
        /* Zeichenmodus: die App schickt fertige Zeichen samt Shift; ein
         * eingeschaltetes Feststellen im Gast wuerde sie umdrehen. */
        if (eingabekanal) {
            guint mods = 0;
            g_object_get(eingabekanal, "key-modifiers", &mods, NULL);
            if (mods & SPICE_INPUTS_CAPS_LOCK) {
                spice_inputs_channel_set_key_locks(eingabekanal, mods & ~SPICE_INPUTS_CAPS_LOCK);
                log_zeile("tastatur", "Feststelltaste im Gast ausgeschaltet");
            }
        }
        break;
    case E_GROESSE:
        if (hauptkanal) {
            spice_main_channel_update_display_enabled(hauptkanal, 0, TRUE, FALSE);
            spice_main_channel_update_display(hauptkanal, 0, 0, 0, e->a, e->b, TRUE);
        }
        break;
    }
    return G_SOURCE_REMOVE;
}

static void eingabe_schicken(int art, int a, int b, int c) {
    Eingabe *e = g_new(Eingabe, 1);
    e->art = art; e->a = a; e->b = b; e->c = c;
    im_kontext(eingabe, e);
}

void rw_spice_maus_position(int32_t x, int32_t y, int32_t tasten) { eingabe_schicken(E_POS, x, y, tasten); }
void rw_spice_maus_bewegung(int32_t dx, int32_t dy, int32_t tasten) { eingabe_schicken(E_BEW, dx, dy, tasten); }
void rw_spice_feststell_aus(void) { eingabe_schicken(E_CAPS_AUS, 0, 0, 0); }
void rw_spice_maus_taste(int32_t taste, int32_t gedrueckt, int32_t tasten) { eingabe_schicken(E_TASTE_MAUS, taste, gedrueckt, tasten); }
void rw_spice_taste(int32_t scancode, int32_t gedrueckt) { eingabe_schicken(E_TASTE, scancode, gedrueckt, 0); }
void rw_spice_bildschirm_groesse(int32_t breite, int32_t hoehe) {
    /* QXL und virtio-gpu wollen eine Breite in Achterschritten */
    breite &= ~7;
    hoehe &= ~1;
    if (breite >= 320 && hoehe >= 200) eingabe_schicken(E_GROESSE, breite, hoehe, 0);
}

/* ── Fehlertext ──────────────────────────────────────────────────────── */

char *rw_spice_letzter_fehler(void) {
    g_mutex_lock(&fehler_mutex);
    char *t = g_strdup(letzter_fehler ? letzter_fehler : "");
    g_mutex_unlock(&fehler_mutex);
    return t;
}

void rw_spice_frei(char *p) { g_free(p); }
