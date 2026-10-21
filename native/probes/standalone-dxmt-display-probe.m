/* Native, headless allocation diagnostic for the pinned DXMT output query. */
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#include <dlfcn.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include "winemetal_thunks.h"

static void report(unsigned count) {
    malloc_statistics_t stats;
    malloc_zone_statistics(NULL, &stats);
    printf("iterations=%u live_bytes=%zu blocks=%u\n", count, stats.size_in_use, stats.blocks_in_use);
    fflush(stdout);
}

int main(int argc, char **argv) {
    if (argc != 2) { fprintf(stderr, "Usage: %s /absolute/path/to/winemetal.so\n", argv[0]); return 2; }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!library) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    int32_t (**calls)(void *) = dlsym(library, "__wine_unix_call_funcs");
    if (!calls) return 1;
    struct WMTDisplayDescription description = {0};
    struct unixcall_generic_obj_ptr_noret args = {
        .handle = CGMainDisplayID(), .arg = {.ptr = &description}
    };
    /* A pool in both cases isolates owned Core Foundation leaks from temporaries. */
    for (unsigned i = 0; i < 100; i++) {
        @autoreleasepool { if (calls[96](&args)) return 1; }
    }
    report(0);
    for (unsigned i = 1; i <= 2000; i++) {
        @autoreleasepool { if (calls[96](&args)) return 1; }
        if (i % 200 == 0) report(i);
    }
    printf("white=%f,%f max_edr=%f\n", description.white_points[0], description.white_points[1],
           description.maximum_edr_color_component_value);
    return description.maximum_edr_color_component_value > 0 ? 0 : 1;
}
