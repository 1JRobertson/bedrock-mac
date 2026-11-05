/* Included by winemetal_unix.c (MRC). AppKit state is touched only on main. */
#ifndef FF_NATIVE_OVERLAY_SOURCE_H
#define FF_NATIVE_OVERLAY_SOURCE_H
#include "native_overlay_record.h"
#include <stdatomic.h>
#include <stdio.h>

static NSHashTable *ff_overlay_layers;
static dispatch_source_t ff_overlay_timer;
static NSString *ff_overlay_path, *ff_overlay_nonce, *ff_overlay_bundle;
static NSInteger ff_overlay_window;
static BOOL ff_overlay_started;
static atomic_bool ff_overlay_binding_pending;
static _Atomic uint64_t ff_overlay_suspended_ns;
/* Optional source completion ABI: an inactive live bound window can pause a
 * Present-only deadline after original GPU/query/readback readiness. This is
 * never evidence of an actual native Present and never bypasses GPU readiness. */
__attribute__((visibility("default"))) uint32_t fullframe_native_overlay_suspended(void) {
    uint64_t time = atomic_load_explicit(&ff_overlay_suspended_ns, memory_order_acquire);
    uint64_t now = ff_overlay_now_ns();
    return time && now >= time && now - time < 500000000ull;
}


typedef struct { BOOL active, suspended; } FFOverlaySourceVisibility;
static FFOverlaySourceVisibility ff_overlay_source_visibility(BOOL bound, BOOL visible, BOOL minimized, BOOL key,
    NSRunningApplication *owner, NSRunningApplication *front) {
    /* Wine's NSApp.active/key state can remain true while another macOS app is
     * foreground. Match the native presenter's authoritative owner predicate. */
    BOOL known = owner && !owner.terminated && [owner.bundleIdentifier isEqual:ff_overlay_bundle] &&
        front && front.processIdentifier > 0;
    BOOL foreground = known && owner.active && front.processIdentifier == getpid();
    return (FFOverlaySourceVisibility){bound && foreground && key,
        bound && known && (visible || minimized) && (!foreground || !key || minimized)};
}

static void ff_overlay_publish(void) {
    @autoreleasepool {
        /* Retain the last authenticated state while refreshing. Clearing it
         * before file/AppKit work lets a 50ms completion poll phase-lock onto
         * transient false values and charge background time. Its 500ms TTL
         * still bounds a blocked refresh, and invalid/new states replace it. */
        NSDictionary *record = ff_overlay_read_record(ff_overlay_path, ff_overlay_nonce);
        if (!record || [record[@"owner_pid"] intValue] != getpid() ||
            ![record[@"bundle_id"] isEqual:ff_overlay_bundle] ||
            ([record[@"window_number"] integerValue] != 0 && [record[@"window_number"] integerValue] != ff_overlay_window)) {
            atomic_store_explicit(&ff_overlay_suspended_ns, 0, memory_order_release); return;
        }
        CAMetalLayer *layer = ff_overlay_layers.allObjects.firstObject;
        NSView *view = [layer.delegate isKindOfClass:NSView.class] ? (NSView *)layer.delegate : nil;
        NSWindow *window = view.window;
        BOOL bound = window && window.windowNumber == ff_overlay_window && window.screen;
        NSRect rect = NSZeroRect;
        if (bound) rect = [window convertRectToScreen:[view convertRect:view.bounds toView:nil]];
        NSMutableDictionary *updated = [[record mutableCopy] autorelease];
        updated[@"source_pid"] = @(getpid()); updated[@"window_number"] = @(ff_overlay_window);
        updated[@"monotonic_ns"] = @(ff_overlay_now_ns());
        updated[@"x"] = @(rect.origin.x); updated[@"y"] = @(rect.origin.y);
        updated[@"width"] = @(rect.size.width); updated[@"height"] = @(rect.size.height);
        updated[@"window_level"] = @(bound ? window.level : 0);
        updated[@"scale"] = @(bound ? window.backingScaleFactor : 1);
        FFOverlaySourceVisibility state = ff_overlay_source_visibility(bound, window.visible, window.miniaturized, window.keyWindow,
            [NSRunningApplication runningApplicationWithProcessIdentifier:getpid()], NSWorkspace.sharedWorkspace.frontmostApplication);
        updated[@"active"] = @(state.active);
        /* Do not use occlusionState: the overlay itself occludes this view. */
        updated[@"visible"] = @(bound && window.visible && !view.hiddenOrHasHiddenAncestor);
        updated[@"miniaturized"] = @(!bound || window.miniaturized);
        atomic_store_explicit(&ff_overlay_suspended_ns, state.suspended ? ff_overlay_now_ns() : 0, memory_order_release);
        NSData *data = [NSJSONSerialization dataWithJSONObject:updated options:0 error:NULL];
        if (!data || data.length > 4096) return;
        NSString *temporary = [ff_overlay_path stringByAppendingFormat:@".%d.tmp", getpid()];
        int fd = open(temporary.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (fd < 0) return;
        BOOL written = write(fd, data.bytes, data.length) == (ssize_t)data.length;
        close(fd);
        /* Recheck the owner before replacement. A changed/revoked record stops
         * publication; temporary files never become an alternate binding. */
        NSDictionary *current = ff_overlay_read_record(ff_overlay_path, ff_overlay_nonce);
        if (!written || !current || ![current[@"owner_pid"] isEqual:record[@"owner_pid"]] ||
            ![current[@"bundle_id"] isEqual:record[@"bundle_id"]] ||
            ![current[@"window_number"] isEqual:record[@"window_number"]] ||
            rename(temporary.fileSystemRepresentation, ff_overlay_path.fileSystemRepresentation))
            unlink(temporary.fileSystemRepresentation);
    }
}
static void ff_overlay_try_bind(void) {
    if (ff_overlay_window) { ff_overlay_publish(); return; }
    NSDictionary *record = ff_overlay_read_record(ff_overlay_path, ff_overlay_nonce);
    NSRunningApplication *app = NSRunningApplication.currentApplication;
    if (!record || [record[@"owner_pid"] intValue] != getpid() || ![record[@"bundle_id"] isEqual:app.bundleIdentifier]) return;
    CAMetalLayer *layer = ff_overlay_layers.allObjects.firstObject;
    NSView *view = [layer.delegate isKindOfClass:NSView.class] ? (NSView *)layer.delegate : nil;
    NSWindow *window = view.window;
    if (!window || !window.keyWindow || !window.visible || window.windowNumber <= 0 ||
        ([record[@"window_number"] integerValue] != 0 && [record[@"window_number"] integerValue] != window.windowNumber)) return;
    ff_overlay_bundle = [app.bundleIdentifier copy]; ff_overlay_window = window.windowNumber;
    ff_overlay_publish();
}
static void ff_overlay_bind_layer(CAMetalLayer *layer) {
    const char *enabled = getenv("BEDROCK_NATIVE_OVERLAY");
    const char *path = getenv("BEDROCK_NATIVE_OVERLAY_CONTROL"), *nonce = getenv("BEDROCK_NATIVE_OVERLAY_NONCE");
    if (!enabled || strcmp(enabled, "1") || !path || !nonce || !layer ||
        atomic_exchange_explicit(&ff_overlay_binding_pending, true, memory_order_acq_rel)) return;
    /* Capture the exact source layer once, then retry initial ownership/window
     * readiness on main. The first Present may block awaiting native output,
     * so startup cannot depend on another QueryDisplaySettingForLayer call. */
    dispatch_async(dispatch_get_main_queue(), ^{
        @autoreleasepool {
            if (ff_overlay_started) return;
            ff_overlay_started = YES;
            ff_overlay_path = [[NSString stringWithUTF8String:path] copy];
            ff_overlay_nonce = [[NSString stringWithUTF8String:nonce] copy];
            ff_overlay_layers = [[NSHashTable weakObjectsHashTable] retain]; [ff_overlay_layers addObject:layer];
            ff_overlay_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(ff_overlay_timer, DISPATCH_TIME_NOW, 50000000ull, 5000000ull);
            dispatch_source_set_event_handler(ff_overlay_timer, ^{ @autoreleasepool { ff_overlay_try_bind(); } });
            dispatch_resume(ff_overlay_timer);
        }
    });
}
#endif
