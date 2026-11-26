// SPDX-License-Identifier: GPL-3.0-or-later
/*
 * Ladetest fuer ein ausgeliefertes Buendel: laedt rwspice und rwtunnel so,
 * wie die App es tut (Datei neben dem Programm), startet die GLib-Schleife
 * und fragt ein paar Werte ab. Fehlt eine abhaengige Bibliothek (DLL/.so),
 * scheitert schon das Laden — genau das soll der CI-Lauf merken, bevor ein
 * Installer entsteht.
 *
 *   laden_test <ordner mit rwspice und rwtunnel>
 *
 * Windows: Ordner = Buendel neben rosenweg_vm.exe; der Test laeuft mit einem
 * PATH ohne MSYS2, damit nur zaehlt, was im Buendel liegt.
 */
#include <stdio.h>
#include <stdint.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>
typedef HMODULE Lib;
static Lib laden(const char *ordner, const char *name) {
    char p[MAX_PATH];
    snprintf(p, sizeof p, "%s\\%s.dll", ordner, name);
    /* Abhaengigkeiten wie bei der App aus dem Ordner der DLL suchen */
    Lib l = LoadLibraryExA(p, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!l) fprintf(stderr, "%s: LoadLibrary-Fehler %lu\n", p, GetLastError());
    return l;
}
static void *fn(Lib l, const char *n) { return (void *)GetProcAddress(l, n); }
static void warten(int ms) { Sleep(ms); }
#else
#include <dlfcn.h>
#include <unistd.h>
typedef void *Lib;
static Lib laden(const char *ordner, const char *name) {
    char p[4096];
#ifdef __APPLE__
    snprintf(p, sizeof p, "%s/lib%s.dylib", ordner, name);
#else
    snprintf(p, sizeof p, "%s/lib%s.so", ordner, name);
#endif
    Lib l = dlopen(p, RTLD_NOW | RTLD_GLOBAL);
    if (!l) fprintf(stderr, "%s: %s\n", p, dlerror());
    return l;
}
static void *fn(Lib l, const char *n) { return dlsym(l, n); }
static void warten(int ms) { usleep(ms * 1000); }
#endif

static void ereignis(int32_t art, int32_t a, int32_t b, int32_t c, int32_t d) {
    (void)c; (void)d;
    fprintf(stderr, "Ereignis %d (%d, %d)\n", art, a, b);
}

int main(int argc, char **argv) {
    const char *ordner = argc > 1 ? argv[1] : ".";
    Lib spice = laden(ordner, "rwspice");
    Lib tunnel = laden(ordner, "rwtunnel");
    if (!spice || !tunnel) return 1;

    int32_t (*abi)(void) = (int32_t (*)(void))fn(spice, "rw_spice_abi");
    void (*start)(int32_t, void (*)(int32_t, int32_t, int32_t, int32_t, int32_t)) =
        (void (*)(int32_t, void (*)(int32_t, int32_t, int32_t, int32_t, int32_t)))fn(spice, "rw_spice_start");
    int32_t (*ordner_moeglich)(void) = (int32_t (*)(void))fn(spice, "rw_spice_ordner_moeglich");
    char *(*usb_liste)(void) = (char *(*)(void))fn(spice, "rw_spice_usb_liste");
    void (*frei)(char *) = (void (*)(char *))fn(spice, "rw_spice_frei");
    char *(*schluessel)(void) = (char *(*)(void))fn(tunnel, "rwt_schluesselpaar");
    void (*tfrei)(char *) = (void (*)(char *))fn(tunnel, "rwt_frei");
    if (!abi || !start || !ordner_moeglich || !usb_liste || !frei || !schluessel || !tfrei) {
        fprintf(stderr, "Funktion fehlt in rwspice/rwtunnel\n");
        return 1;
    }

    printf("rwspice ABI %d\n", abi());
    start(1, ereignis);
    warten(300);
    printf("Ordner freigeben moeglich (phodav): %d\n", ordner_moeglich());
    char *l = usb_liste();
    printf("USB-Liste ohne Sitzung: %s\n", l ? l : "(null)");
    if (l) frei(l);

    char *k = schluessel();
    /* nur pruefen, dass ein Schluesselpaar kam; nicht ausgeben */
    int ok = k && strstr(k, "\"oeffentlich\"") != NULL;
    printf("rwtunnel Schluesselpaar: %s\n", ok ? "ok" : (k ? k : "(null)"));
    if (k) tfrei(k);
    return ok ? 0 : 1;
}
