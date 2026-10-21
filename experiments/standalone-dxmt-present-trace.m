/* Diagnostic-only actual presentation timestamps; no per-frame log writes. */
#import "standalone-dxmt-present-trace.h"
#import <QuartzCore/QuartzCore.h>
#include <dispatch/dispatch.h>
#include <inttypes.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { TRACE_BATCH = 120, TRACE_CAPACITY = TRACE_BATCH * 8 };

struct trace_sample {
  uint64_t sequence, drawable_id, layer, width, height;
  double submitted, presented, callback, minimum_duration;
};

/* Process lifetime storage: callbacks never refer to an ObjC owner or drawable. */
static bool trace_enabled;
static dispatch_queue_t trace_writer;
static pthread_mutex_t trace_mutex = PTHREAD_MUTEX_INITIALIZER;
static struct trace_sample trace_ring[TRACE_CAPACITY];
static size_t trace_head, trace_count;
static bool trace_writer_pending;
static uint64_t trace_callbacks, trace_overflow, trace_batches;
static _Atomic uint64_t trace_submitted, trace_unsupported;

/* Only invoked on trace_writer; stderr is written once per complete batch. */
static void trace_drain(void) {
  for (;;) {
    struct trace_sample samples[TRACE_BATCH];
    uint64_t callbacks, overflow, batch;
    pthread_mutex_lock(&trace_mutex);
    if (trace_count < TRACE_BATCH) {
      trace_writer_pending = false;
      pthread_mutex_unlock(&trace_mutex);
      return;
    }
    for (size_t i = 0; i < TRACE_BATCH; ++i) {
      samples[i] = trace_ring[trace_head];
      trace_head = (trace_head + 1) % TRACE_CAPACITY;
    }
    trace_count -= TRACE_BATCH;
    callbacks = trace_callbacks;
    overflow = trace_overflow;
    batch = ++trace_batches;
    pthread_mutex_unlock(&trace_mutex);

    unsigned positive = 0, zero = 0, invalid = 0;
    for (size_t i = 0; i < TRACE_BATCH; ++i) {
      if (!isfinite(samples[i].presented) || samples[i].presented < 0.0) ++invalid;
      else if (samples[i].presented == 0.0) ++zero;
      else ++positive;
    }
    /* Fixed-size records and buffer keep memory bounded if the log blocks. */
    char line[65536];
    int written = snprintf(line, sizeof(line),
        "[dxmt-present-trace] {\"version\":1,\"batch\":%" PRIu64
        ",\"count\":%u,\"positive\":%u,\"zero\":%u,\"invalid\":%u"
        ",\"submitted_total\":%" PRIu64 ",\"callbacks_total\":%" PRIu64
        ",\"overflow_total\":%" PRIu64 ",\"unsupported_total\":%" PRIu64
        ",\"fields\":[\"sequence\",\"drawable_id\",\"layer\",\"width\",\"height\","
        "\"submitted_s\",\"presented_s\",\"callback_s\",\"minimum_duration_s\"],\"samples\":[",
        batch, TRACE_BATCH, positive, zero, invalid,
        atomic_load_explicit(&trace_submitted, memory_order_relaxed), callbacks, overflow,
        atomic_load_explicit(&trace_unsupported, memory_order_relaxed));
    if (written < 0 || (size_t)written >= sizeof(line)) abort();
    size_t used = (size_t)written;
    for (size_t i = 0; i < TRACE_BATCH; ++i) {
      const struct trace_sample *s = &samples[i];
      /* JSON has no NaN/Inf. A null is invalid, a zero remains a zero. */
      char presented[48];
      if (isfinite(s->presented) && s->presented >= 0.0)
        snprintf(presented, sizeof(presented), "%.9f", s->presented);
      else
        strcpy(presented, "null");
      written = snprintf(line + used, sizeof(line) - used,
          "%s[%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64 ",%" PRIu64
          ",%.9f,%s,%.9f,%.9f]", i ? "," : "", s->sequence,
          s->drawable_id, s->layer, s->width, s->height, s->submitted,
          presented, s->callback, s->minimum_duration);
      if (written < 0 || (size_t)written >= sizeof(line) - used) abort();
      used += (size_t)written;
    }
    if (used + 4 > sizeof(line)) abort();
    memcpy(line + used, "]}\n", 3);
    fwrite(line, 1, used + 3, stderr);
  }
}

static void trace_record(struct trace_sample sample) {
  bool schedule_writer = false;
  pthread_mutex_lock(&trace_mutex);
  ++trace_callbacks;
  if (trace_count == TRACE_CAPACITY) {
    /* Lose diagnostics, never stall Metal or retain drawable objects for I/O. */
    ++trace_overflow;
  } else {
    trace_ring[(trace_head + trace_count) % TRACE_CAPACITY] = sample;
    ++trace_count;
  }
  if (trace_count >= TRACE_BATCH && !trace_writer_pending) {
    trace_writer_pending = true;
    schedule_writer = true;
  }
  pthread_mutex_unlock(&trace_mutex);
  if (schedule_writer)
    dispatch_async(trace_writer, ^{ trace_drain(); });
}

void bedrock_trace_present(id<MTLDrawable> drawable, double minimum_duration) {
  if (!trace_enabled) return;
  const uint64_t sequence = atomic_fetch_add_explicit(&trace_submitted, 1, memory_order_relaxed) + 1;
  if (!drawable || ![drawable respondsToSelector:@selector(addPresentedHandler:)] ||
      ![drawable respondsToSelector:@selector(presentedTime)] ||
      ![drawable respondsToSelector:@selector(drawableID)]) {
    atomic_fetch_add_explicit(&trace_unsupported, 1, memory_order_relaxed);
    return;
  }
  struct trace_sample base = {0};
  base.sequence = sequence;
  base.drawable_id = drawable.drawableID;
  base.submitted = CACurrentMediaTime();
  base.minimum_duration = minimum_duration;
  if ([drawable respondsToSelector:@selector(layer)] &&
      [drawable respondsToSelector:@selector(texture)]) {
    id<CAMetalDrawable> metal_drawable = (id<CAMetalDrawable>)drawable;
    base.layer = (uintptr_t)metal_drawable.layer;
    base.width = metal_drawable.texture.width;
    base.height = metal_drawable.texture.height;
  }
  /* Capture only the scalar struct. The drawable parameter belongs to Metal;
     capturing the outer drawable would create a drawable -> block -> drawable cycle. */
  [drawable addPresentedHandler:^(id<MTLDrawable> presented_drawable) {
    struct trace_sample sample = base;
    sample.presented = presented_drawable.presentedTime;
    sample.callback = CACurrentMediaTime();
    trace_record(sample);
  }];
}

__attribute__((constructor)) static void initialize_present_trace(void) {
  const char *enabled = getenv("BEDROCK_DXMT_PRESENT_TRACE");
  if (!enabled || strcmp(enabled, "1")) return;
  trace_writer = dispatch_queue_create("bedrock.dxmt.present-trace", DISPATCH_QUEUE_SERIAL);
  trace_enabled = trace_writer != NULL;
}
