/* Opt-in aggregate Metal command telemetry. No resource handles or contents. */
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static _Atomic uint64_t counters[12];
static _Atomic uint64_t presents;
static int enabled;

__attribute__((constructor)) static void fullframe_initialize(void) {
    const char *value = getenv("BEDROCK_FULLFRAME_TRACE");
    enabled = value && strcmp(value, "1") == 0;
}

void fullframe_event(unsigned kind) {
    if (enabled && kind < 12) atomic_fetch_add_explicit(&counters[kind], 1, memory_order_relaxed);
}

void fullframe_present(void) {
    if (!enabled) return;
    uint64_t count = atomic_fetch_add_explicit(&presents, 1, memory_order_relaxed) + 1;
    if (count % 120) return;
    uint64_t values[12];
    for (unsigned i = 0; i < 12; ++i) values[i] = atomic_load_explicit(&counters[i], memory_order_relaxed);
    /* Cumulative cross-thread counters are not a coherent individual frame. */
    fprintf(stderr, "[full-frame-trace] {\"version\":1,\"submitted_presentations\":%llu,"
        "\"render_passes\":%llu,\"draws\":%llu,\"indexed_draws\":%llu,\"indirect_draws\":%llu,"
        "\"pipeline_binds\":%llu,\"texture_binds\":%llu,\"vertex_buffer_binds\":%llu,"
        "\"fragment_buffer_binds\":%llu,\"compute_batches\":%llu,\"blit_batches\":%llu,"
        "\"mesh_draws\":%llu,\"render_commands\":%llu}\n", (unsigned long long)count,
        (unsigned long long)values[0], (unsigned long long)values[1], (unsigned long long)values[2],
        (unsigned long long)values[3], (unsigned long long)values[4], (unsigned long long)values[5],
        (unsigned long long)values[6], (unsigned long long)values[7], (unsigned long long)values[8],
        (unsigned long long)values[9], (unsigned long long)values[10], (unsigned long long)values[11]);
}
