/* Experimental, narrowly scoped Unix adapter for pinned DXMT v0.80.
 * Its original 132-entry ABI and implementation remain in winemetal-upstream.so.
 * The display-query call returns scalars only, so its temporary Cocoa objects
 * can be released before returning. Calls returning borrowed objects are not
 * wrapped, since draining their pool would invalidate the returned objects.
 */
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <limits.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef int32_t (*unix_call_fn)(void *);
enum { DXMT_080_CALL_COUNT = 132, DXMT_DISPLAY_QUERY = 101 };
__attribute__((visibility("default"))) unix_call_fn __wine_unix_call_funcs[DXMT_080_CALL_COUNT];
__attribute__((visibility("default"))) unix_call_fn __wine_unix_call_wow64_funcs[DXMT_080_CALL_COUNT];
static unix_call_fn original_query;
static unix_call_fn original_query_wow64;

static int32_t query_with_pool(void *arguments) {
    @autoreleasepool { return original_query(arguments); }
}
static int32_t query_wow64_with_pool(void *arguments) {
    @autoreleasepool { return original_query_wow64(arguments); }
}

__attribute__((constructor)) static void initialize_adapter(void) {
    Dl_info own;
    char path[PATH_MAX];
    if (!dladdr((void *)initialize_adapter, &own) || !own.dli_fname || strlen(own.dli_fname) >= sizeof(path)) {
        fputs("DXMT pool adapter: cannot resolve its own location\n", stderr); abort();
    }
    strcpy(path, own.dli_fname);
    char *slash = strrchr(path, '/');
    if (!slash || (size_t)(slash-path) + sizeof("/winemetal-upstream.so") > sizeof(path)) {
        fputs("DXMT pool adapter: invalid library path\n", stderr); abort();
    }
    strcpy(slash, "/winemetal-upstream.so");
    void *upstream = dlopen(path, RTLD_NOW | RTLD_LOCAL | RTLD_FIRST);
    if (!upstream) { fprintf(stderr, "DXMT pool adapter: %s\n", dlerror()); abort(); }
    unix_call_fn *native = dlsym(upstream, "__wine_unix_call_funcs");
    unix_call_fn *wow64 = dlsym(upstream, "__wine_unix_call_wow64_funcs");
    if (!native || !wow64 || native == __wine_unix_call_funcs) {
        fputs("DXMT pool adapter: upstream Unix-call ABI unavailable\n", stderr); abort();
    }
    memcpy(__wine_unix_call_funcs, native, sizeof(__wine_unix_call_funcs));
    memcpy(__wine_unix_call_wow64_funcs, wow64, sizeof(__wine_unix_call_wow64_funcs));
    original_query = native[DXMT_DISPLAY_QUERY];
    original_query_wow64 = wow64[DXMT_DISPLAY_QUERY];
    const char *mode = getenv("BEDROCK_DXMT_DISPLAY_QUERY_POOL");
    if (!mode || strcmp(mode, "0")) {
        __wine_unix_call_funcs[DXMT_DISPLAY_QUERY] = query_with_pool;
        __wine_unix_call_wow64_funcs[DXMT_DISPLAY_QUERY] = query_wow64_with_pool;
    }
}
