/* Native presentation of an already-rendered Metal texture, not game replay. */
#ifndef FF_NATIVE_PRESENTER_H
#define FF_NATIVE_PRESENTER_H
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ff_native_presenter ff_native_presenter;
typedef enum ff_present_result {
    FF_PRESENT_COMPLETED = 0,
    FF_PRESENT_SUPERSEDED = 1,
    FF_PRESENT_CLOSED = 2,
    FF_PRESENT_GPU_ERROR = 3
} ff_present_result;
typedef void (*ff_present_completion)(void *context, ff_present_result result);
/* Snapshot bytes are BGRA8, valid only during callback. A NULL pointer means
 * the selected frame did not complete a GPU readback. Called before its normal
 * completion, including on supersession/close/error. Offscreen mode only. */
typedef void (*ff_present_snapshot_completion)(void *context, const void *bytes,
    uint32_t width, uint32_t height, uint32_t row_bytes, ff_present_result result);

/* Raw drawable observations in lock-recording order. presented_time is Metal's
 * presentedTime seconds; callback_monotonic_ns samples CLOCK_MONOTONIC at
 * handler entry before reading the drawable or acquiring the presenter lock. */
typedef struct ff_present_identity { uint64_t stream, frame, chunk, serial, queue_completion; } ff_present_identity;
typedef struct ff_present_sample {
    double presented_time; uint64_t callback_monotonic_ns;
    ff_present_identity identity; int identity_present;
} ff_present_sample;

typedef struct ff_present_stats {
    uint64_t accepted, superseded, completed, gpu_errors;
    uint32_t pending, in_flight;
    int closed;
    int display_trace_enabled;
    /* Optional drawable observation. These do not grant completion credit. */
    uint64_t display_scheduled, display_callbacks, display_unsupported;
    uint64_t display_positive, display_zero, display_invalid, display_out_of_order;
    uint64_t display_intervals, display_over_25ms, display_over_50ms, display_counter_overflow;
    double first_presented_time, last_presented_time, display_interval_sum, lifetime_interval_max;
    int offscreen;
} ff_present_stats;

/* Create, pump, close and destroy must run on the AppKit main thread.
 * metal_device is a borrowed id<MTLDevice>, bridged to void * without transfer.
 * Width/height are window points (1..8192). Error is optional UTF-8 storage.
 * The implementation is compiled with ARC; callers may use MRC or plain C.
 * Standalone AppKit launch is initialized here; pump services its launch events.
 * An already-running host keeps its existing AppKit lifecycle/delegate.
 */
ff_native_presenter *ff_presenter_create(void *metal_device, const char *title,
    uint32_t width, uint32_t height, char *error, size_t error_capacity);
/* Creation-time focus policy: activate must be 0 or 1. With 0 the window is
 * eligible to join all Spaces and other apps' full-screen Spaces, and ordered
 * front without requesting key focus or app activation. With 1,
 * behavior matches ff_presenter_create, which retains its activating default.
 * Later user interaction with the window follows normal AppKit behavior.
 * Explicit BEDROCK_NATIVE_OVERLAY=1 opts activate=0 into a passive borderless
 * NSPanel, using BEDROCK_NATIVE_OVERLAY_CONTROL and _NONCE private binding.
 * It cannot become key/main or receive mouse events. Until exact, fresh source
 * geometry and foreground ownership are validated it stays hidden. Missing or
 * unsafe records never fall back to a focusable window. Activating/default
 * creation does not opt in. The launcher enables this only for native render. */
ff_native_presenter *ff_presenter_create_with_activation(void *metal_device,
    const char *title, uint32_t width, uint32_t height, int activate,
    char *error, size_t error_capacity);
/* Explicit headless GPU sink. Creates no NSApplication, NSWindow or drawable.
 * Completion means the same transfer shader finished into a private Metal
 * texture; it is never evidence of display. Dimensions are target pixels. */
ff_native_presenter *ff_presenter_create_offscreen(void *metal_device,
    uint32_t width, uint32_t height, char *error, size_t error_capacity);

/* Thread-safe. metal_texture is a borrowed id<MTLTexture> from EXACTLY the
 * creation device. Supported: shader-readable 2D RGBA8/BGRA8 UNorm or sRGB,
 * one sample, no array. Resolve MSAA before calling. Rendering MUST already
 * be completed. The caller must not modify/reuse its storage until completion.
 * Returns 1 when ownership is accepted; completion is called exactly once,
 * possibly on another thread. Returns 0 without a callback on invalid input or
 * a closed presenter. Texture retention requires no CPU pixel upload/readback.
 * Completion also covers superseded frames; callback context must remain alive.
 * No API call may race destroy. Do not destroy from a completion callback.
 */
int ff_presenter_submit(ff_native_presenter *, void *metal_texture,
    ff_present_completion completion, void *context);
int ff_presenter_submit_snapshot(ff_native_presenter *, void *metal_texture,
    ff_present_completion completion, void *context,
    ff_present_snapshot_completion snapshot, void *snapshot_context);
/* Optional identity is copied at submission and appears only in opt-in
 * drawable callback samples. It never grants completion or display credit. */
int ff_presenter_submit_snapshot_tagged(ff_native_presenter *, void *metal_texture,
    ff_present_completion completion, void *context,
    ff_present_snapshot_completion snapshot, void *snapshot_context,
    const ff_present_identity *identity);

/* Dispatch AppKit events, then submit the newest frame if GPU capacity allows.
 * timeout_seconds is clamped to 0..0.05; call repeatedly while rendering/waiting.
 * Returns 1 while open, 0 after normal window close (or on the wrong thread).
 */
int ff_presenter_pump(ff_native_presenter *, double timeout_seconds);
/* Thread-safe explicit normal-close query; a NULL presenter is closed. */
int ff_presenter_is_closed(ff_native_presenter *);
void ff_presenter_get_stats(ff_native_presenter *, ff_present_stats *);
/* Opt-in BEDROCK_NATIVE_PRESENT_SAMPLES=1 or BEDROCK_NATIVE_FRAME_AGE=1
 * enables tracing and retains the
 * most recent 16384 callbacks in lock-recording order. Snapshot under the presenter
 * lock. Returns the retained count; copies min(count, capacity) oldest retained
 * samples. overflow counts callbacks omitted from the beginning of this window.
 * Scheduled minus callbacks in the accompanying stats identifies observations
 * still pending or never delivered at snapshot time. No API may race destroy. */
size_t ff_presenter_copy_samples(ff_native_presenter *, ff_present_sample *out,
    size_t capacity, uint64_t *overflow, ff_present_stats *stats);
void ff_presenter_close(ff_native_presenter *);
/* Closes the window. GPU work retains its texture and internal state until
 * completion; callbacks can run after destroy returns. Does not terminate NSApp.
 */
void ff_presenter_destroy(ff_native_presenter *);

#ifdef __cplusplus
}
#endif
#endif
