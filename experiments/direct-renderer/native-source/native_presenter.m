/* Compile this translation unit with -fobjc-arc, including for MRC callers. */
#if !__has_feature(objc_arc)
#error native_presenter.m requires ARC
#endif
#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include "native_presenter.h"
#include "native_overlay_record.h"
#include "private_motion_probe.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

static void display_increment(uint64_t *value, uint64_t *overflow) {
    if (*value < UINT64_MAX) ++*value;
    else if (*overflow < UINT64_MAX) ++*overflow;
}
static BOOL display_samples_requested(BOOL offscreen) {
    const char *samples=getenv("BEDROCK_NATIVE_PRESENT_SAMPLES"),*age=getenv("BEDROCK_NATIVE_FRAME_AGE");
    return !offscreen&&((samples&&!strcmp(samples,"1"))||(age&&!strcmp(age,"1")));
}
/* Pure timestamp accounting, independent of GPU completion and receipts. */
static void display_record(ff_present_stats *current, double presentedTime) {
    display_increment(&current->display_callbacks, &current->display_counter_overflow);
    if (!isfinite(presentedTime) || presentedTime < 0) {
        display_increment(&current->display_invalid, &current->display_counter_overflow);
    } else if (presentedTime == 0) {
        display_increment(&current->display_zero, &current->display_counter_overflow);
    } else {
        display_increment(&current->display_positive, &current->display_counter_overflow);
        if (current->last_presented_time && presentedTime <= current->last_presented_time) {
            display_increment(&current->display_out_of_order, &current->display_counter_overflow);
        } else {
            if (!current->first_presented_time) current->first_presented_time = presentedTime;
            if (current->last_presented_time) {
                double interval = presentedTime - current->last_presented_time;
                display_increment(&current->display_intervals, &current->display_counter_overflow);
                current->display_interval_sum += interval;
                current->lifetime_interval_max = fmax(current->lifetime_interval_max, interval);
                if (interval > 0.025) display_increment(&current->display_over_25ms, &current->display_counter_overflow);
                if (interval > 0.050) display_increment(&current->display_over_50ms, &current->display_counter_overflow);
            }
            current->last_presented_time = presentedTime;
        }
    }
}

@interface FFPresentFrame : NSObject
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) ff_present_completion completion;
@property(nonatomic) void *context;
@property(nonatomic) ff_present_snapshot_completion snapshot;
@property(nonatomic) void *snapshotContext;
@property(nonatomic, strong) id<MTLBuffer> snapshotBuffer;
@property(nonatomic) uint32_t snapshotWidth, snapshotHeight, snapshotRowBytes;
@property(nonatomic) ff_present_identity identity;
@property(nonatomic) BOOL identityPresent;
- (void)finish:(ff_present_result)result;
@end
@implementation FFPresentFrame
- (void)finish:(ff_present_result)result {
    /* The caller cannot reuse storage until all presenter references are gone. */
    self.texture = nil;
    ff_present_snapshot_completion snapshot = self.snapshot;
    self.snapshot = NULL;
    if (snapshot) snapshot(self.snapshotContext,
        result == FF_PRESENT_COMPLETED ? self.snapshotBuffer.contents : NULL,
        self.snapshotWidth, self.snapshotHeight, self.snapshotRowBytes, result);
    self.snapshotBuffer = nil;
    ff_present_completion callback = self.completion;
    self.completion = NULL;
    if (callback) callback(self.context, result);
}
@end

/* A passive surface cannot become an input destination, even after clicks. */
@interface FFNativeOverlayPanel : NSPanel
@end
@implementation FFNativeOverlayPanel
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeMainWindow { return NO; }
@end

@interface FFNativePresenter : NSObject <NSWindowDelegate>
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) id<MTLCommandQueue> queue;
@property(nonatomic, strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) CAMetalLayer *layer;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) FFPrivateMotion *privateMotion;
@property(nonatomic, strong) FFPresentFrame *pending;
@property(nonatomic) ff_present_stats stats;
@property(nonatomic) BOOL displayTraceEnabled;
@property(nonatomic, strong) NSMutableData *displaySamples;
@property(nonatomic) size_t displaySampleCount,displaySampleHead;
@property(nonatomic) uint64_t displaySampleOverflow;
@property(nonatomic) BOOL offscreen;
@property(nonatomic) uint32_t targetWidth, targetHeight;
@property(nonatomic, copy) NSString *overlayPath;
@property(nonatomic, copy) NSString *overlayNonce;
@property(nonatomic, copy) NSString *overlayBundle;
@property(nonatomic) pid_t overlayPID;
@property(nonatomic) NSInteger overlayWindow;
@property(nonatomic) BOOL overlayDiagnosed;
@property(nonatomic) uint32_t overlayReason;
@property(nonatomic) pid_t overlayFrontPID;
@property(nonatomic) pid_t overlaySourcePID;
@property(nonatomic) NSInteger overlayRecordWindow;
- (void)updateOverlay;
- (void)close;
- (void)drawPending;
@end

/* Called under the presenter lock, including by the synthetic fixture. */
static void display_sample(FFNativePresenter *presenter,double presentedTime,uint64_t ns,
    ff_present_identity identity,int identityPresent) {
    if (!presenter.displaySamples) return;
    if (!identityPresent) identity=(ff_present_identity){0};
    ff_present_sample *samples=presenter.displaySamples.mutableBytes;
    if (presenter.displaySampleCount < 16384) {
        size_t index=(presenter.displaySampleHead+presenter.displaySampleCount++)%16384;
        samples[index]=(ff_present_sample){.presented_time=presentedTime,.callback_monotonic_ns=ns,
            .identity=identity,.identity_present=identityPresent};
    } else {
        samples[presenter.displaySampleHead]=(ff_present_sample){.presented_time=presentedTime,.callback_monotonic_ns=ns,
            .identity=identity,.identity_present=identityPresent};
        presenter.displaySampleHead=(presenter.displaySampleHead+1)%16384;
        if (presenter.displaySampleOverflow < UINT64_MAX) ++presenter.displaySampleOverflow;
    }
}

/* The block captures only immutable scalar identity and a weak presenter.
 * It does not retain the submitted frame, texture, or completion context. */
static void (^display_observer(FFNativePresenter *owner,ff_present_identity identity,int identityPresent))(id<MTLDrawable>) {
    __weak FFNativePresenter *weakPresenter=owner;
    return ^(id<MTLDrawable> presentedDrawable) {
        FFNativePresenter *presenter=weakPresenter;if(!presenter)return;
        /* Sample before touching the drawable or waiting for the presenter
         * lock; callback scheduling delay still remains in this measurement. */
        uint64_t callbackNS=0;
        if(presenter.displaySamples){struct timespec now={0};
            if(!clock_gettime(CLOCK_MONOTONIC,&now))callbackNS=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;}
        double presentedTime=presentedDrawable.presentedTime;
        [presenter.lock lock];ff_present_stats current=presenter.stats;
        display_record(&current,presentedTime);
        if(presenter.displaySamples)display_sample(presenter,presentedTime,callbackNS,identity,identityPresent);
        presenter.stats=current;[presenter.lock unlock];
    };
}

@implementation FFNativePresenter
- (void)updateOverlay {
    if (!self.overlayPath) return;
    NSDictionary *record = ff_overlay_read_record(self.overlayPath, self.overlayNonce);
    if (record && !self.overlayPID) {
        self.overlayPID = [record[@"owner_pid"] intValue];
        self.overlayBundle = record[@"bundle_id"];
    }
    uint64_t now = ff_overlay_now_ns();
    NSInteger window = [record[@"window_number"] integerValue];
    pid_t sourcePID = [record[@"source_pid"] intValue];
    BOOL identity = record && self.overlayPID == [record[@"owner_pid"] intValue] &&
        [self.overlayBundle isEqual:record[@"bundle_id"]];
    BOOL geometry = record && ff_overlay_geometry_valid(record, now);
    if (identity && geometry && !self.overlayWindow) self.overlayWindow = window;
    NSRunningApplication *owner = record ? [NSRunningApplication runningApplicationWithProcessIdentifier:self.overlayPID] : nil;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    /* Diagnostic mask only; preserve the existing ownership/show predicate.
     * 1 record absent/unsafe, 2 identity, 4 geometry/state, 8 stale/future,
     * 16 window mismatch, 32 owner missing/terminated/bundle mismatch,
     * 64 owner inactive, 128 foreground mismatch, 256 source inactive,
     * 512 source invisible, 1024 source minimized. No nonce/path is logged. */
    uint32_t reason = record ? 0 : 1;
    uint64_t stamp = [record[@"monotonic_ns"] unsignedLongLongValue];
    long long age = stamp && stamp <= now ? (long long)((now - stamp) / 1000000ull) : -1;
    if (record) {
        if (!identity) reason |= 2;
        if (!geometry) reason |= 4;
        if (!stamp || stamp > now || now - stamp >= 500000000ull) reason |= 8;
        if (self.overlayWindow != window) reason |= 16;
        if (!owner || owner.terminated || ![owner.bundleIdentifier isEqual:self.overlayBundle]) reason |= 32;
        if (!owner.active) reason |= 64;
        if (front.processIdentifier != self.overlayPID) reason |= 128;
        if (![record[@"active"] boolValue]) reason |= 256;
        if (![record[@"visible"] boolValue]) reason |= 512;
        if ([record[@"miniaturized"] boolValue]) reason |= 1024;
    }
    if (!self.overlayDiagnosed || self.overlayReason != reason || self.overlayFrontPID != front.processIdentifier ||
        self.overlaySourcePID != sourcePID || self.overlayRecordWindow != window) {
        fprintf(stderr, "[native-overlay] reason_mask=%u owner_pid=%d source_pid=%d front_pid=%d active=%d visible=%d mini=%d window=%ld age_ms=%lld\n",
            reason, self.overlayPID, sourcePID, front.processIdentifier, [record[@"active"] boolValue],
            [record[@"visible"] boolValue], [record[@"miniaturized"] boolValue], (long)window, age);
        self.overlayDiagnosed = YES; self.overlayReason = reason; self.overlayFrontPID = front.processIdentifier;
        self.overlaySourcePID = sourcePID; self.overlayRecordWindow = window;
    }
    if (reason) { [self.window orderOut:nil]; return; }
    NSRect rect = NSMakeRect([record[@"x"] doubleValue], [record[@"y"] doubleValue],
        [record[@"width"] doubleValue], [record[@"height"] doubleValue]);
    self.window.level = [record[@"window_level"] integerValue] + 1;
    if (!NSEqualRects(rect, self.window.frame)) [self.window setFrame:rect display:NO];
    if (!self.window.visible) [self.window orderFrontRegardless];
}
- (void)close {
    [self.lock lock];
    ff_present_stats stats = self.stats;
    stats.closed = 1; stats.pending = 0;
    self.stats = stats;
    FFPresentFrame *frame = self.pending; self.pending = nil;
    [self.lock unlock];
    [frame finish:FF_PRESENT_CLOSED];
}
- (void)windowWillClose:(NSNotification *)notification {
    (void)notification; [self close];
}
- (void)drawPending {
    [self.lock lock];
    ff_present_stats stats = self.stats;
    if (stats.closed || !self.pending || stats.in_flight >= 2) {
        [self.lock unlock]; return;
    }
    [self.lock unlock];

    NSRect bounds = self.offscreen ? NSZeroRect : self.window.contentView.bounds;
    CGFloat scale = self.offscreen ? 1 : self.window.backingScaleFactor;
    NSUInteger width = self.offscreen ? self.targetWidth : (NSUInteger)fmin(16384.0, fmax(1.0, floor(bounds.size.width * scale)));
    NSUInteger height = self.offscreen ? self.targetHeight : (NSUInteger)fmin(16384.0, fmax(1.0, floor(bounds.size.height * scale)));
    if (!self.offscreen) { self.layer.contentsScale = scale; self.layer.drawableSize = CGSizeMake(width, height); }
    /* A minimized/occluded window keeps only its newest pending frame. */
    if (!self.offscreen && (self.overlayPath ? !self.window.visible :
        (self.window.miniaturized || !(self.window.occlusionState & NSWindowOcclusionStateVisible)))) return;
    id<CAMetalDrawable> drawable = self.offscreen ? nil : [self.layer nextDrawable];
    if (!self.offscreen && !drawable) return;
    id<MTLTexture> target = drawable.texture;
    if (self.offscreen) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
            width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModePrivate;
        descriptor.usage = MTLTextureUsageRenderTarget;
        target = [self.device newTextureWithDescriptor:descriptor];
    }
    [self.lock lock];
    stats = self.stats;
    if (stats.closed || !self.pending) { [self.lock unlock]; return; }
    FFPresentFrame *frame = self.pending; self.pending = nil;
    stats.pending = 0; stats.in_flight++; self.stats = stats;
    [self.lock unlock];

    if (!target) {
        [self.lock lock]; stats = self.stats;
        stats.in_flight--; stats.gpu_errors++; self.stats = stats; [self.lock unlock];
        [frame finish:FF_PRESENT_GPU_ERROR]; return;
    }

    id<MTLCommandBuffer> command = [self.queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    if (!command || !encoder) {
        [self.lock lock]; stats = self.stats;
        stats.in_flight--; stats.gpu_errors++; self.stats = stats; [self.lock unlock];
        [frame finish:FF_PRESENT_GPU_ERROR]; return;
    }
    id<MTLTexture> texture = frame.texture;
    double fit = fmin((double)width / texture.width, (double)height / texture.height);
    double fittedWidth = texture.width * fit, fittedHeight = texture.height * fit;
    [encoder setViewport:(MTLViewport){(width - fittedWidth) / 2, (height - fittedHeight) / 2,
        fittedWidth, fittedHeight, 0, 1}];
    [encoder setRenderPipelineState:self.pipeline];
    [encoder setFragmentTexture:texture atIndex:0];
    uint32_t srgb = texture.pixelFormat == MTLPixelFormatRGBA8Unorm_sRGB ||
        texture.pixelFormat == MTLPixelFormatBGRA8Unorm_sRGB;
    [encoder setFragmentBytes:&srgb length:sizeof(srgb) atIndex:0];
    [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [encoder endEncoding];
    uint64_t motionSerial=0;
    id<MTLBuffer> motionBuffer=self.privateMotion?[self.privateMotion encode:command texture:texture serial:&motionSerial]:nil;
    if (frame.snapshot) {
        NSUInteger rowBytes = (width * 4 + 255) & ~(NSUInteger)255;
        if (rowBytes > UINT32_MAX || height > SIZE_MAX / rowBytes) {
            [self.lock lock]; stats = self.stats;
            stats.in_flight--; stats.gpu_errors++; self.stats = stats; [self.lock unlock];
            [frame finish:FF_PRESENT_GPU_ERROR]; return;
        }
        id<MTLBuffer> pixels = [self.device newBufferWithLength:rowBytes * height options:MTLResourceStorageModeShared];
        id<MTLBlitCommandEncoder> blit = pixels ? [command blitCommandEncoder] : nil;
        if (!blit) {
            [self.lock lock]; stats = self.stats;
            stats.in_flight--; stats.gpu_errors++; self.stats = stats; [self.lock unlock];
            [frame finish:FF_PRESENT_GPU_ERROR]; return;
        }
        [blit copyFromTexture:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(width,height,1) toBuffer:pixels destinationOffset:0
            destinationBytesPerRow:rowBytes destinationBytesPerImage:rowBytes * height];
        [blit endEncoding];
        frame.snapshotBuffer = pixels;
        frame.snapshotWidth = (uint32_t)width; frame.snapshotHeight = (uint32_t)height;
        frame.snapshotRowBytes = (uint32_t)rowBytes;
    }
    if (self.displayTraceEnabled && !self.offscreen) {
        if ([drawable respondsToSelector:@selector(addPresentedHandler:)] &&
            [drawable respondsToSelector:@selector(presentedTime)]) {
            [self.lock lock]; ff_present_stats observed = self.stats;
            display_increment(&observed.display_scheduled, &observed.display_counter_overflow);
            self.stats = observed; [self.lock unlock];
            ff_present_identity identity={0};int identityPresent=0;
            if(self.displaySamples&&frame.identityPresent){identity=frame.identity;identityPresent=1;}
            [drawable addPresentedHandler:display_observer(self,identity,identityPresent)];
        } else {
            [self.lock lock]; ff_present_stats current = self.stats;
            display_increment(&current.display_unsupported, &current.display_counter_overflow);
            self.stats = current; [self.lock unlock];
        }
    }
    if (!self.offscreen) [command presentDrawable:drawable];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        BOOL ok = completed.status == MTLCommandBufferStatusCompleted;
        [self.lock lock]; ff_present_stats current = self.stats;
        current.in_flight--;
        if (ok) current.completed++; else current.gpu_errors++;
        self.stats = current; [self.lock unlock];
        [frame finish:ok ? FF_PRESENT_COMPLETED : FF_PRESENT_GPU_ERROR];
        if(ok&&motionBuffer)[self.privateMotion finish:motionBuffer serial:motionSerial];
    }];
    [command commit];
}
@end

struct ff_native_presenter { void *object; };
static FFNativePresenter *impl(ff_native_presenter *presenter) {
    return presenter ? (__bridge FFNativePresenter *)presenter->object : nil;
}
static void set_error(char *error, size_t capacity, NSString *message) {
    if (error && capacity) snprintf(error, capacity, "%s", message.UTF8String ?: "Presenter error");
}
static void finish_standalone_launch(void) {
    /* This component pumps events instead of calling NSApplication.run, which
     * normally performs finishLaunching. GPU presentation alone does not mark
     * an app ready for LaunchServices/accessibility clients. Leave an existing
     * host application's completed lifecycle alone, and never repeat our launch
     * notifications when a second presenter is created. Main thread only. */
    static BOOL finishedHere = NO;
    if (!finishedHere && !NSApp.running && !NSRunningApplication.currentApplication.finishedLaunching) {
        finishedHere = YES;
        [NSApp finishLaunching];
    }
}

ff_native_presenter *ff_presenter_create(void *metal_device, const char *title,
    uint32_t width, uint32_t height, char *error, size_t error_capacity) {
    return ff_presenter_create_with_activation(metal_device, title, width, height, 1,
        error, error_capacity);
}

static ff_native_presenter *presenter_create_mode(void *metal_device,
    const char *title, uint32_t width, uint32_t height, int activate,
    BOOL offscreen, char *error, size_t error_capacity) {
    @autoreleasepool {
        if (error && error_capacity) error[0] = '\0';
        if (activate != 0 && activate != 1) {
            set_error(error, error_capacity, @"Presenter activation must be 0 or 1"); return NULL;
        }
        if (![NSThread isMainThread] || !metal_device || !width || !height || width > 8192 || height > 8192) {
            set_error(error, error_capacity, @"Presenter requires main thread, device and window dimensions 1..8192"); return NULL;
        }
        const char *overlayEnabled = getenv("BEDROCK_NATIVE_OVERLAY");
        BOOL overlay = !offscreen && !activate && overlayEnabled && !strcmp(overlayEnabled, "1");
        NSString *overlayPath = nil, *overlayNonce = nil;
        if (overlay) {
            const char *path = getenv("BEDROCK_NATIVE_OVERLAY_CONTROL"), *nonce = getenv("BEDROCK_NATIVE_OVERLAY_NONCE");
            overlayPath = path ? [NSString stringWithUTF8String:path] : nil;
            overlayNonce = nonce ? [NSString stringWithUTF8String:nonce] : nil;
            if (!ff_overlay_nonce_valid(overlayNonce) || !ff_overlay_private_directory(overlayPath)) {
                set_error(error, error_capacity, @"Native overlay requires private control and nonce"); return NULL;
            }
        }
        FFNativePresenter *p = [FFNativePresenter new];
        p.offscreen = offscreen; p.targetWidth = width; p.targetHeight = height;
        p.overlayPath = overlayPath; p.overlayNonce = overlayNonce;
        const char *displayTrace = getenv("BEDROCK_NATIVE_PRESENT_TRACE");
        BOOL samplesEnabled = display_samples_requested(offscreen);
        p.displayTraceEnabled = !offscreen && ((displayTrace && !strcmp(displayTrace, "1")) || samplesEnabled);
        if (samplesEnabled) p.displaySamples = [NSMutableData dataWithLength:16384 * sizeof(ff_present_sample)];
        ff_present_stats initialStats = p.stats;
        initialStats.display_trace_enabled = p.displayTraceEnabled;
        initialStats.offscreen = offscreen;
        p.stats = initialStats;
        p.device = (__bridge id<MTLDevice>)metal_device;
        p.lock = [NSLock new]; p.queue = [p.device newCommandQueue];
        const char *privateMotion=getenv("BEDROCK_PRIVATE_MOTION_OBSERVE");
        if(!offscreen&&privateMotion&&!strcmp(privateMotion,"texture-aggregate-v1")){
            p.privateMotion=[[FFPrivateMotion alloc] initWithDevice:p.device];
            if(!p.privateMotion){set_error(error,error_capacity,@"Private motion probe unavailable");return NULL;}
        }
        /* UNorm preserves byte color values. For sRGB textures Metal decodes
         * samples, so explicitly encode them again for the UNorm drawable. */
        NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
            "struct V { float4 position [[position]]; float2 uv; };\n"
            "vertex V ff_present_vertex(uint id [[vertex_id]]) {\n"
            " float2 p[3] = {float2(-1,-1), float2(3,-1), float2(-1,3)};\n"
            " V o; o.position=float4(p[id],0,1); o.uv=float2((p[id].x+1)*0.5, (1-p[id].y)*0.5); return o; }\n"
            "fragment float4 ff_present_fragment(V in [[stage_in]], texture2d<float> image [[texture(0)]],\n"
            " constant uint &srgb [[buffer(0)]]) { constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);\n"
            " float3 c=image.sample(s,in.uv).rgb; if(srgb) c=select(c*12.92,1.055*pow(max(c,0.0),float3(1.0/2.4))-0.055,c>0.0031308);\n"
            " return float4(c,1); }\n";
        NSError *failure = nil;
        id<MTLLibrary> library = [p.device newLibraryWithSource:source options:nil error:&failure];
        MTLRenderPipelineDescriptor *descriptor = [MTLRenderPipelineDescriptor new];
        descriptor.vertexFunction = [library newFunctionWithName:@"ff_present_vertex"];
        descriptor.fragmentFunction = [library newFunctionWithName:@"ff_present_fragment"];
        descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        if (library) p.pipeline = [p.device newRenderPipelineStateWithDescriptor:descriptor error:&failure];
        if (!p.queue || !p.pipeline) {
            set_error(error, error_capacity, failure.localizedDescription ?: @"Metal presentation pipeline unavailable"); return NULL;
        }
        if (offscreen) {
            ff_native_presenter *handle = calloc(1, sizeof(*handle));
            if (!handle) { set_error(error, error_capacity, @"Presenter allocation failed"); return NULL; }
            handle->object = (__bridge_retained void *)p; return handle;
        }
        pid_t overlayFrontBefore = overlay ? NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier : 0;
        [NSApplication sharedApplication];
        if (NSApp.activationPolicy == NSApplicationActivationPolicyProhibited)
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        finish_standalone_launch();
        if (overlay) fprintf(stderr, "[native-overlay-launch] front_before=%d front_after=%d\n",
            overlayFrontBefore, NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier);
        if (overlay) {
            NSPanel *panel = [[FFNativeOverlayPanel alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                backing:NSBackingStoreBuffered defer:NO];
            panel.hidesOnDeactivate = NO; panel.becomesKeyOnlyIfNeeded = YES;
            panel.ignoresMouseEvents = YES; panel.acceptsMouseMovedEvents = NO;
            panel.hasShadow = NO; panel.animationBehavior = NSWindowAnimationBehaviorNone;
            p.window = panel;
        } else {
            p.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, width, height)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                backing:NSBackingStoreBuffered defer:NO];
        }
        p.window.releasedWhenClosed = NO; p.window.delegate = p;
        if (!activate) {
            /* The game can own another application's full-screen Space. */
            p.window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces |
                NSWindowCollectionBehaviorFullScreenAuxiliary |
                NSWindowCollectionBehaviorCanJoinAllApplications;
        }
        NSString *windowTitle = title ? [NSString stringWithUTF8String:title] : nil;
        p.window.title = windowTitle ?: @"Native Metal output";
        if (!overlay) p.window.contentMinSize = NSMakeSize(160, 90);
        p.layer = [CAMetalLayer layer]; p.layer.device = p.device;
        p.layer.pixelFormat = MTLPixelFormatBGRA8Unorm; p.layer.framebufferOnly = YES;
        p.layer.maximumDrawableCount = 3;
        const char *privateSync=getenv("BEDROCK_PRIVATE_NATIVE_VSYNC");
        p.layer.displaySyncEnabled = !(privateSync&&!strcmp(privateSync,"0"));
        fprintf(stderr,"[VSP1] sync=%u max_drawables=%lu\n",p.layer.displaySyncEnabled?1u:0u,(unsigned long)p.layer.maximumDrawableCount);
        p.layer.allowsNextDrawableTimeout = YES; p.layer.opaque = YES;
        p.window.contentView.wantsLayer = YES; p.window.contentView.layer = p.layer;
        [p.window center];
        if (activate) {
            [p.window makeKeyAndOrderFront:nil];
            [NSApp activateIgnoringOtherApps:YES];
        } else if (!overlay) {
            /* Stay drawable above the active app without taking its key focus. */
            [p.window orderFrontRegardless];
        }
        ff_native_presenter *handle = calloc(1, sizeof(*handle));
        if (!handle) { [p.window close]; set_error(error, error_capacity, @"Presenter allocation failed"); return NULL; }
        handle->object = (__bridge_retained void *)p; return handle;
    }
}

ff_native_presenter *ff_presenter_create_with_activation(void *metal_device,
    const char *title, uint32_t width, uint32_t height, int activate,
    char *error, size_t error_capacity) {
    return presenter_create_mode(metal_device,title,width,height,activate,NO,error,error_capacity);
}
ff_native_presenter *ff_presenter_create_offscreen(void *metal_device,
    uint32_t width, uint32_t height, char *error, size_t error_capacity) {
    return presenter_create_mode(metal_device,NULL,width,height,0,YES,error,error_capacity);
}

int ff_presenter_submit(ff_native_presenter *handle, void *metal_texture,
    ff_present_completion completion, void *context) {
    return ff_presenter_submit_snapshot_tagged(handle,metal_texture,completion,context,NULL,NULL,NULL);
}
int ff_presenter_submit_snapshot(ff_native_presenter *handle, void *metal_texture,
    ff_present_completion completion, void *context,
    ff_present_snapshot_completion snapshot, void *snapshot_context) {
    return ff_presenter_submit_snapshot_tagged(handle,metal_texture,completion,context,snapshot,snapshot_context,NULL);
}
int ff_presenter_submit_snapshot_tagged(ff_native_presenter *handle, void *metal_texture,
    ff_present_completion completion, void *context,
    ff_present_snapshot_completion snapshot, void *snapshot_context,
    const ff_present_identity *identity) {
    @autoreleasepool {
        FFNativePresenter *p = impl(handle);
        id<MTLTexture> texture = (__bridge id<MTLTexture>)metal_texture;
        if (!p || (snapshot && !p.offscreen) || !texture || texture.device != p.device || texture.textureType != MTLTextureType2D ||
            texture.sampleCount != 1 || !(texture.usage & MTLTextureUsageShaderRead) || !texture.width || !texture.height) return 0;
        MTLPixelFormat format = texture.pixelFormat;
        if (format != MTLPixelFormatRGBA8Unorm && format != MTLPixelFormatBGRA8Unorm &&
            format != MTLPixelFormatRGBA8Unorm_sRGB && format != MTLPixelFormatBGRA8Unorm_sRGB) return 0;
        FFPresentFrame *frame = [FFPresentFrame new];
        frame.texture = texture; frame.completion = completion; frame.context = context;
        frame.snapshot = snapshot; frame.snapshotContext = snapshot_context;
        if(identity){frame.identity=*identity;frame.identityPresent=YES;}
        [p.lock lock]; ff_present_stats stats = p.stats;
        if (stats.closed) { [p.lock unlock]; return 0; }
        FFPresentFrame *old = p.pending; p.pending = frame;
        stats.accepted++; stats.pending = 1;
        if (old) stats.superseded++;
        p.stats = stats; [p.lock unlock];
        [old finish:FF_PRESENT_SUPERSEDED]; return 1;
    }
}

int ff_presenter_pump(ff_native_presenter *handle, double timeout_seconds) {
    @autoreleasepool {
        FFNativePresenter *p = impl(handle);
        if (!p || ![NSThread isMainThread]) return 0;
        double wait = isfinite(timeout_seconds) ? fmin(0.05, fmax(0, timeout_seconds)) : 0;
        if (p.offscreen) {
            [p drawPending];
            if (wait > 0) usleep((useconds_t)(fmin(wait,0.001)*1000000.0));
            return !ff_presenter_is_closed(handle);
        }
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:wait];
        NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:deadline inMode:NSDefaultRunLoopMode dequeue:YES];
        /* Bound event processing as well as GPU work under sustained input. */
        for (unsigned i = 0; event && i < 128; ++i) {
            [NSApp sendEvent:event];
            event = i < 127 ? [NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast]
                inMode:NSDefaultRunLoopMode dequeue:YES] : nil;
        }
        [NSApp updateWindows]; [p updateOverlay]; [p drawPending];
        return !ff_presenter_is_closed(handle);
    }
}
int ff_presenter_is_closed(ff_native_presenter *handle) {
    FFNativePresenter *p = impl(handle); if (!p) return 1;
    [p.lock lock]; int closed = p.stats.closed; [p.lock unlock]; return closed;
}
void ff_presenter_get_stats(ff_native_presenter *handle, ff_present_stats *out) {
    if (!out) return; FFNativePresenter *p = impl(handle);
    if (!p) { *out = (ff_present_stats){.closed = 1}; return; }
    [p.lock lock]; *out = p.stats; [p.lock unlock];
}
size_t ff_presenter_copy_samples(ff_native_presenter *handle, ff_present_sample *out,
    size_t capacity, uint64_t *overflow, ff_present_stats *stats) {
    FFNativePresenter *p = impl(handle); if (!p) { if (overflow) *overflow = 0; if (stats) *stats = (ff_present_stats){.closed=1}; return 0; }
    [p.lock lock]; size_t count = p.displaySampleCount;
    size_t copied = out ? MIN(count, capacity) : 0;
    if (copied) {
        const ff_present_sample *samples=p.displaySamples.bytes;
        size_t first=MIN(copied,16384-p.displaySampleHead);
        memcpy(out,samples+p.displaySampleHead,first*sizeof(*out));
        if(copied>first)memcpy(out+first,samples,(copied-first)*sizeof(*out));
    }
    if (overflow) *overflow = p.displaySampleOverflow; if (stats) *stats = p.stats;
    [p.lock unlock]; return count;
}
void ff_presenter_close(ff_native_presenter *handle) {
    FFNativePresenter *p = impl(handle); if (!p || ![NSThread isMainThread]) return;
    [p close]; if (p.window) [p.window close];
}
void ff_presenter_destroy(ff_native_presenter *handle) {
    if (!handle || ![NSThread isMainThread]) return;
    ff_presenter_close(handle);
    FFNativePresenter *p = (__bridge_transfer FFNativePresenter *)handle->object;
    p.window.delegate = nil; p.window = nil; p.layer = nil;
    handle->object = NULL; free(handle);
}
