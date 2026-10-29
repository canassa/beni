// Embedded in beni for the size measurement: the prototype host with its main
// renamed, and a constructor that runs the module BENI_ENGINE_PROBE names
// before beni's main. The constructor keeps the whole engine linked.
#define main qhost_main
#include "host.c"
#undef main

__attribute__((constructor)) static void beni_engine_probe(void) {
    const char *entry = getenv("BENI_ENGINE_PROBE");
    if (!entry) return;
    exit(run_once(entry, 0, 0, NULL, NULL));
}
