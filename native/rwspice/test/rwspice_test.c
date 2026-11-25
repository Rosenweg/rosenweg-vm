// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Headless-Test fuer librwspice: verbindet mit einem SPICE-Server, wartet auf
 * ein Bild und schreibt es als PPM. Damit ist die C-Schicht ohne Flutter und
 * ohne Hausnetz pruefbar, z. B. gegen spice-server/test-display-no-ssl:
 *
 *   rwspice_test 127.0.0.1 5912 bild.ppm
 *
 * Durch die Proxy-Kette der App (native/rwtunnel/werkzeuge/proxytest):
 *
 *   rwspice_test pvespiceproxy:ticket:100:pve1 5912 bild.ppm 10 http://rw:…@127.0.0.1:…
 */
#include "../rwspice.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static volatile int verbunden, breite, hoehe, getrennt = -1, ton = -1;

static void ereignis(int32_t art, int32_t a, int32_t b, int32_t c, int32_t d) {
    (void)c; (void)d;
    switch (art) {
    case RW_E_VERBUNDEN: verbunden = 1; break;
    case RW_E_BILD_GROESSE: breite = a; hoehe = b; break;
    case RW_E_GETRENNT: getrennt = a; break;
    case RW_E_TON: ton = a; break;
    }
    fprintf(stderr, "Ereignis %d (%d, %d)\n", art, a, b);
}

int main(int argc, char **argv) {
    if (argc < 4) { fprintf(stderr, "rwspice_test <host> <port> <ausgabe.ppm> [sekunden] [proxy]\n"); return 2; }
    int sekunden = argc > 4 ? atoi(argv[4]) : 10;
    const char *proxy = argc > 5 ? argv[5] : NULL;
    rw_spice_start(1, ereignis);
    if (rw_spice_verbinden(argv[1], atoi(argv[2]), 0, NULL, proxy, NULL, NULL) != 0) return 3;

    uint8_t *puffer = NULL;
    int bilder = 0;
    for (int i = 0; i < sekunden * 20; i++) {
        usleep(50000);
        if (getrennt >= 0) break;
        if (!breite) continue;
        size_t n = (size_t)breite * hoehe * 4;
        if (!puffer) puffer = malloc(n);
        int32_t w, h;
        if (rw_spice_bild_abholen(puffer, (int32_t)n, &w, &h) == 1) bilder++;
        if (bilder >= 5) break;
    }
    char *usb = rw_spice_usb_liste();
    fprintf(stderr, "USB: %s\n", usb);
    rw_spice_frei(usb);
    char *f = rw_spice_letzter_fehler();
    fprintf(stderr, "letzter Fehler: %s\n", f);
    rw_spice_frei(f);

    if (!verbunden || !breite || !bilder) {
        fprintf(stderr, "FEHLER: verbunden=%d breite=%d bilder=%d getrennt=%d\n", verbunden, breite, bilder, getrennt);
        return 1;
    }
    FILE *a = fopen(argv[3], "wb");
    fprintf(a, "P6\n%d %d\n255\n", breite, hoehe);
    long hell = 0;
    for (int i = 0; i < breite * hoehe; i++) {
        uint8_t *p = puffer + i * 4; /* B G R A */
        fputc(p[2], a); fputc(p[1], a); fputc(p[0], a);
        hell += p[0] + p[1] + p[2];
    }
    fclose(a);
    printf("OK %dx%d, %d Bilder, mittlere Helligkeit %ld\n", breite, hoehe, bilder, hell / (3L * breite * hoehe));
    rw_spice_trennen();
    usleep(300000);
    return 0;
}
