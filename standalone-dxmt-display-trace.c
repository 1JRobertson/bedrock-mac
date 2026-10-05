/* Optional scalar-only diagnostics for the pinned DXMT v0.80 Unix bridge. */
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef int32_t (*unix_call_fn)(void *);
extern const void *__wine_unix_call_funcs[];
extern const void *__wine_unix_call_wow64_funcs[];
static unix_call_fn describe_original, query_original;
static _Atomic uint64_t describes, queries;
static struct timespec started;

static void report(const char *name, uint64_t count) {
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    double seconds = now.tv_sec - started.tv_sec + (now.tv_nsec - started.tv_nsec) / 1e9;
    fprintf(stderr, "[dxmt-display-trace] seconds=%.3f %s=%llu\n",
            seconds, name, (unsigned long long)count);
}

static int32_t describe_traced(void *args) {
    uint64_t count = atomic_fetch_add_explicit(&describes, 1, memory_order_relaxed) + 1;
    if (!(count & (count - 1)) || !(count % 1024)) report("output_descriptions", count);
    return describe_original(args);
}

static int32_t query_traced(void *args) {
    uint64_t count = atomic_fetch_add_explicit(&queries, 1, memory_order_relaxed) + 1;
    if (!(count & (count - 1)) || !(count % 1024)) report("layer_queries", count);
    return query_original(args);
}

__attribute__((constructor)) static void initialize_display_trace(void) {
    const char *enabled = getenv("BEDROCK_DXMT_DISPLAY_TRACE");
    if (!enabled || strcmp(enabled, "1")) return;
    clock_gettime(CLOCK_MONOTONIC, &started);
    describe_original = (unix_call_fn)__wine_unix_call_funcs[96];
    query_original = (unix_call_fn)__wine_unix_call_funcs[101];
    __wine_unix_call_funcs[96] = __wine_unix_call_wow64_funcs[96] = describe_traced;
    __wine_unix_call_funcs[101] = __wine_unix_call_wow64_funcs[101] = query_traced;
}
