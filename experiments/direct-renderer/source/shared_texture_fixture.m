/* Isolated protocol proof. No game, account, installed runtime or live world. */
#import "shared_texture.h"
#import "shared_texture_attachment.h"
#import "shared_texture_executor.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

static id<MTLDevice> exact_device(uint64_t registry) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) if (d.registryID == registry) return d;
    return nil;
}
static BOOL wait_sem(dispatch_semaphore_t s, unsigned seconds) {
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, seconds * NSEC_PER_SEC)) == 0;
}
static MTLTextureDescriptor *descriptor(MTLPixelFormat format, NSUInteger samples) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:32 height:16 mipmapped:NO];
    d.sampleCount = samples; d.textureType = samples == 1 ? MTLTextureType2D : MTLTextureType2DMultisample;
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    return d;
}
static int producer(NSString *service, NSString *token, id<MTLDevice> device, NSUInteger samples) {
    FFSTProducer p = ffst_producer_create(service, token, device, 1, 16 * 1024 * 1024, 0);
    if (!p) return 10;
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLTexture> color = [device newTextureWithDescriptor:descriptor(MTLPixelFormatRGBA8Unorm, samples)];
    id<MTLTexture> depth = [device newTextureWithDescriptor:descriptor(MTLPixelFormatDepth32Float_Stencil8, samples)];
    id<MTLTexture> colorCopy = [device newSharedTextureWithDescriptor:descriptor(MTLPixelFormatRGBA8Unorm, samples)];
    id<MTLTexture> depthCopy = [device newSharedTextureWithDescriptor:descriptor(MTLPixelFormatDepth32Float_Stencil8, samples)];
    if (!color || !depth || !colorCopy || !depthCopy) { ffst_producer_destroy(p); return 11; }
    FFSTTextureInput textures[] = {{colorCopy, 101, 1, 0, 0}, {depthCopy, 102, 1, 0, 0}};
    FFSTAttachmentRef refs[] = {{FFST_COLOR, 0, 0}, {FFST_DEPTH, 0, 1}, {FFST_STENCIL, 0, 1}};
    id<MTLCommandBuffer> command = [queue commandBuffer];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(0.25, 0.5, 0.75, 1);
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = 0.375;
    pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore; pass.stencilAttachment.clearStencil = 73;
    id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass]; [render endEncoding];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    for (NSArray *pair in @[@[color, colorCopy], @[depth, depthCopy]]) {
        [blit copyFromTexture:pair[0] sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(32,16,1) toTexture:pair[1] destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [blit endEncoding];
    __block NSInteger final = -1; dispatch_semaphore_t done = dispatch_semaphore_create(0);
    FFSTCompletion callback = ^(uint64_t cut, FFSTResult result) {
        if (cut == 700 + samples) final = result; dispatch_semaphore_signal(done);
    };
    /* A handle alone never authorizes publishing unfinished producer GPU writes. */
    if (ffst_producer_publish(p, command, 700 + samples, textures, 2, refs, 3, callback)) {
        ffst_producer_destroy(p); return 12;
    }
    [command commit]; [command waitUntilCompleted];
    if (!ffst_producer_publish(p, command, 700 + samples, textures, 2, refs, 3, callback)) {
        ffst_producer_destroy(p); return 13;
    }
    /* Retired cut identifiers are never reused, including an in-flight repeat. */
    if (ffst_producer_publish(p, command, 700 + samples, textures, 2, refs, 3, callback)) {
        ffst_producer_destroy(p); return 14;
    }
    BOOL waited = wait_sem(done, 25); ffst_producer_destroy(p);
    if (!waited || final != FFST_OK) return 15;
    printf("{\"producer_retired\":true,\"sample_count\":%lu}\n", (unsigned long)samples); return 0;
}
typedef struct {
    id<MTLCommandBuffer> command;
    id<MTLBuffer> color, depth, stencil;
} FFSTFixtureReadback;
/* The same Load/resolve/readback path exercises primitive and integrated leases. */
static int encode_readback(id<MTLDevice> device, NSUInteger samples, id<MTLTexture> color,
    id<MTLTexture> ds, FFSTFixtureReadback *out) {
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLTexture> resolved = samples == 1 ? color : [device newTextureWithDescriptor:descriptor(MTLPixelFormatRGBA8Unorm, 1)];
    id<MTLTexture> resolvedDS = samples == 1 ? ds : [device newTextureWithDescriptor:descriptor(MTLPixelFormatDepth32Float_Stencil8, 1)];
    id<MTLBuffer> bytes = [device newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> depthBytes = [device newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
    id<MTLBuffer> stencilBytes = [device newBufferWithLength:256 * 16 options:MTLResourceStorageModeShared];
    if (!queue || !command || !resolved || !resolvedDS || !bytes || !depthBytes || !stencilBytes) {
        return 32;
    }
    memset(depthBytes.contents, 0xa5, depthBytes.length);
    memset(stencilBytes.contents, 0xa5, stencilBytes.length);
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
    pass.colorAttachments[0].storeAction = samples == 1 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve;
    if (samples != 1) pass.colorAttachments[0].resolveTexture = resolved;
    pass.depthAttachment.texture = ds; pass.depthAttachment.loadAction = MTLLoadActionLoad;
    pass.depthAttachment.storeAction = samples == 1 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve;
    pass.stencilAttachment.texture = ds; pass.stencilAttachment.loadAction = MTLLoadActionLoad;
    pass.stencilAttachment.storeAction = samples == 1 ? MTLStoreActionStore : MTLStoreActionMultisampleResolve;
    if (samples != 1) {
        /* Resolve both planes into the same combined allocation. Uniform source
         * clears make sample0 a precise preservation test for every pixel. */
        pass.depthAttachment.resolveTexture = resolvedDS;
        pass.depthAttachment.depthResolveFilter = MTLMultisampleDepthResolveFilterSample0;
        pass.stencilAttachment.resolveTexture = resolvedDS;
        pass.stencilAttachment.stencilResolveFilter = MTLMultisampleStencilResolveFilterSample0;
    }
    id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:pass];
    if (!render) { return 33; }
    [render endEncoding];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) { return 34; }
    [blit copyFromTexture:resolved sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(32,16,1) toBuffer:bytes destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * 16];
    [blit copyFromTexture:resolvedDS sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(32,16,1) toBuffer:depthBytes destinationOffset:0 destinationBytesPerRow:256
        destinationBytesPerImage:256 * 16 options:MTLBlitOptionDepthFromDepthStencil];
    [blit copyFromTexture:resolvedDS sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(32,16,1) toBuffer:stencilBytes destinationOffset:0 destinationBytesPerRow:256
        destinationBytesPerImage:256 * 16 options:MTLBlitOptionStencilFromDepthStencil];
    [blit endEncoding];
    out->command = command; out->color = bytes; out->depth = depthBytes; out->stencil = stencilBytes;
    return 0;
}
static int verify_readback(FFSTFixtureReadback *readback) {
    const uint8_t *pixels = readback->color.contents;
    for (unsigned y = 0; y < 16; ++y) for (unsigned x = 0; x < 32; ++x) {
        const uint8_t *p = pixels + y * 256 + x * 4;
        if (abs((int)p[0] - 64) > 1 || abs((int)p[1] - 128) > 1 || abs((int)p[2] - 191) > 1 || p[3] != 255) return 29;
        float depthValue;
        memcpy(&depthValue, (const uint8_t *)readback->depth.contents + y * 256 + x * sizeof(float), sizeof(depthValue));
        if (!isfinite(depthValue) || fabsf(depthValue - 0.375f) > 0.000001f) return 30;
        if (((const uint8_t *)readback->stencil.contents)[y * 256 + x] != 73) return 31;
    }
    return 0;
}
static void print_consumer_result(NSUInteger samples, BOOL integrated) {
    printf("{\"consumer_gpu_completed\":true,\"color_load_verified\":true,\"depth_load_verified\":true,\"stencil_load_verified\":true,\"verified_pixels\":512,\"depth_stencil_alias\":true,\"integrated\":%s,\"sample_count\":%lu}\n", integrated ? "true" : "false", (unsigned long)samples);
    fflush(stdout);
}
static int consumer(NSString *service, NSString *token, id<MTLDevice> device, NSUInteger samples) {
    FFSTConsumer c = ffst_consumer_create(service, token, device, 0); if (!c) return 20;
    __block FFSTLease lease = NULL; __block FFSTResult result = FFST_EMPTY;
    for (unsigned poll = 0; poll < 150 && !lease; ++poll) {
        dispatch_semaphore_t acquired = dispatch_semaphore_create(0);
        ffst_consumer_acquire(c, ^(FFSTLease l, FFSTResult r) { lease = l; result = r; dispatch_semaphore_signal(acquired); });
        if (!wait_sem(acquired, 5)) { ffst_consumer_destroy(c); return 21; }
        if (result != FFST_EMPTY && result != FFST_OK) { ffst_consumer_destroy(c); return 22; }
        if (!lease) [NSThread sleepForTimeInterval:0.1];
    }
    if (!lease) { ffst_consumer_destroy(c); return 23; }
    if (ffst_lease_cut_id(lease) != 700 + samples || ffst_lease_texture_count(lease) != 2 ||
        ffst_lease_attachment_count(lease) != 3) {
        ffst_consumer_abandon(lease, nil); ffst_consumer_destroy(c); return 24;
    }
    FFSTAttachmentRef depth, stencil; ffst_lease_attachment(lease, 1, &depth); ffst_lease_attachment(lease, 2, &stencil);
    if (depth.texture_index != stencil.texture_index || depth.role != FFST_DEPTH || stencil.role != FFST_STENCIL) {
        ffst_consumer_abandon(lease, nil); ffst_consumer_destroy(c); return 25;
    }
    id<MTLTexture> color = ffst_lease_texture(lease, 0), ds = ffst_lease_texture(lease, depth.texture_index);
    if (color.device.registryID != device.registryID || ds.sampleCount != samples) {
        ffst_consumer_abandon(lease, nil); ffst_consumer_destroy(c); return 26;
    }
    FFSTFixtureReadback readback = {0};
    int encoded = encode_readback(device, samples, color, ds, &readback);
    if (encoded) { ffst_consumer_abandon(lease, nil); ffst_consumer_destroy(c); return encoded; }
    id<MTLCommandBuffer> command = readback.command;
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block FFSTResult finish = FFST_CLOSED;
    if (!ffst_consumer_finish(lease, command, ^(uint64_t cut, FFSTResult r) {
        (void)cut; finish = r; dispatch_semaphore_signal(done);
    })) { ffst_consumer_abandon(lease, nil); ffst_consumer_destroy(c); return 27; }
    [command commit];
    if (!wait_sem(done, 15) || finish != FFST_OK) { ffst_consumer_destroy(c); return 28; }
    int verified = verify_readback(&readback); ffst_consumer_destroy(c);
    if (verified) return verified;
    print_consumer_result(samples, NO); return 0;
}
static MTLRenderPassDescriptor *clear_pass(id<MTLTexture> color, id<MTLTexture> depth,
    MTLClearColor clearColor, double clearDepth, uint32_t clearStencil) {
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = color; pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore; pass.colorAttachments[0].clearColor = clearColor;
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = MTLLoadActionClear;
    pass.depthAttachment.storeAction = MTLStoreActionStore; pass.depthAttachment.clearDepth = clearDepth;
    pass.stencilAttachment.texture = depth; pass.stencilAttachment.loadAction = MTLLoadActionClear;
    pass.stencilAttachment.storeAction = MTLStoreActionStore; pass.stencilAttachment.clearStencil = clearStencil;
    return pass;
}
static int producer_attachment(NSString *service, NSString *token, id<MTLDevice> device, NSUInteger samples) {
    FFSTProducer producer = ffst_producer_create(service, token, device, 1, 16 * 1024 * 1024, 0);
    if (!producer) return 40;
    FFSTAttachmentCapture capture = ffst_attachment_capture_create(producer, device, 1, 16 * 1024 * 1024);
    if (!capture) { ffst_producer_destroy(producer); return 41; }
    /* The helper exclusively owns the producer from here, including failure. */
    MTLTextureDescriptor *colorDescriptor = descriptor(MTLPixelFormatRGBA8Unorm, samples);
    MTLTextureDescriptor *depthDescriptor = descriptor(MTLPixelFormatDepth32Float_Stencil8, samples);
    colorDescriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    depthDescriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;
    id<MTLTexture> color = [device newTextureWithDescriptor:colorDescriptor];
    id<MTLTexture> depth = [device newTextureWithDescriptor:depthDescriptor];
    id<MTLCommandQueue> queue = [device newCommandQueue]; id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLFence> initialized = [device newFence];
    if (!color || !depth || !queue || !command || !initialized) { ffst_attachment_capture_destroy(capture); return 42; }
    id<MTLRenderCommandEncoder> render = [command renderCommandEncoderWithDescriptor:
        clear_pass(color, depth, MTLClearColorMake(0.25, 0.5, 0.75, 1), 0.375, 73)];
    if (!render) { ffst_attachment_capture_destroy(capture); return 43; }
    [render updateFence:initialized afterStages:MTLRenderStageFragment]; [render endEncoding];
    FFSTAttachmentSource sources[] = {
        {color, 101, 1, 0, 0, FFST_COLOR, 0},
        {depth, 102, 1, 0, 0, FFST_DEPTH, 0},
        {depth, 102, 1, 0, 0, FFST_STENCIL, 0}
    };
    id<MTLFence> fences[] = {initialized}; id<MTLFence> ready = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0); __block FFSTResult final = FFST_CLOSED;
    __block unsigned callbacks = 0;
    if (!ffst_attachment_capture_schedule(capture, command, 700 + samples, sources, 3, fences, 1, &ready,
        ^(uint64_t cut, FFSTResult result) {
            ++callbacks; final = cut == 700 + samples ? result : FFST_REJECTED;
            dispatch_semaphore_signal(done);
        }) || !ready) { ffst_attachment_capture_destroy(capture); return 44; }
    uint64_t beforeBytes = 0, afterBytes = 0;
    if (ffst_attachment_capture_pending(capture, &beforeBytes) != 1 || !beforeBytes) {
        ffst_attachment_capture_destroy(capture); return 45;
    }
    id<MTLFence> rejectedReady = nil;
    if (ffst_attachment_capture_schedule(capture, command, 800 + samples, sources, 3, fences, 1, &rejectedReady,
        ^(uint64_t cut, FFSTResult result) { (void)cut; (void)result; ++callbacks; }) || rejectedReady ||
        ffst_attachment_capture_pending(capture, &afterBytes) != 1 || beforeBytes != afterBytes) {
        ffst_attachment_capture_destroy(capture); return 46;
    }
    /* Original game work resumes only after the exact Load snapshot has copied.
     * Distinct overwrite values make a late/aliased copy fail consumer readback. */
    render = [command renderCommandEncoderWithDescriptor:
        clear_pass(color, depth, MTLClearColorMake(1, 0, 0, 1), 0.875, 7)];
    if (!render) { ffst_attachment_capture_destroy(capture); return 47; }
    [render waitForFence:ready beforeStages:MTLRenderStageVertex | MTLRenderStageFragment]; [render endEncoding];
    [command commit];
    BOOL waited = wait_sem(done, 25);
    uint64_t pendingBytes = UINT64_MAX;
    uint32_t pending = ffst_attachment_capture_pending(capture, &pendingBytes);
    ffst_attachment_capture_destroy(capture);
    if (!waited || final != FFST_OK || callbacks != 1 || command.status != MTLCommandBufferStatusCompleted || pending || pendingBytes) return 48;
    printf("{\"producer_retired\":true,\"integrated\":true,\"originals_untracked\":true,\"originals_overwritten\":true,\"budget_rejection_verified\":true,\"pending_after_retirement\":0,\"sample_count\":%lu}\n", (unsigned long)samples);
    return 0;
}
static int consumer_executor(id<MTLDevice> device, NSUInteger samples) {
    FFSTExecutorAttachments attachments = ffst_executor_acquire(device, 700 + samples, 20);
    if (!attachments) return 50;
    id<MTLTexture> color = ffst_executor_texture(attachments, FFST_COLOR, 0);
    id<MTLTexture> depth = ffst_executor_texture(attachments, FFST_DEPTH, 0);
    id<MTLTexture> stencil = ffst_executor_texture(attachments, FFST_STENCIL, 0);
    if (ffst_executor_attachment_count(attachments) != 3 || !color || !depth || depth != stencil ||
        color.device.registryID != device.registryID || depth.sampleCount != samples) {
        ffst_executor_release(attachments); return 51;
    }
    FFSTTextureInfo colorInfo={0},depthInfo={0},stencilInfo={0};
    if (!ffst_executor_texture_info(attachments, FFST_COLOR, 0, &colorInfo) ||
        !ffst_executor_texture_info(attachments, FFST_DEPTH, 0, &depthInfo) ||
        !ffst_executor_texture_info(attachments, FFST_STENCIL, 0, &stencilInfo) ||
        colorInfo.source_id != 101 || colorInfo.source_generation != 1 || colorInfo.source_level || colorInfo.source_slice ||
        depthInfo.source_id != 102 || depthInfo.source_generation != 1 || depthInfo.source_level || depthInfo.source_slice ||
        stencilInfo.source_id != depthInfo.source_id || stencilInfo.source_generation != depthInfo.source_generation) {
        ffst_executor_release(attachments); return 53;
    }
    FFSTFixtureReadback readback = {0};
    int encoded = encode_readback(device, samples, color, depth, &readback);
    if (encoded) { ffst_executor_release(attachments); return encoded; }
    if (!ffst_executor_finish(attachments, readback.command)) { ffst_executor_release(attachments); return 52; }
    [readback.command commit];
    FFSTResult result = ffst_executor_wait(attachments, 20);
    ffst_executor_release(attachments); /* Immediate release after terminal ACK, no sleep. */
    if (result != FFST_OK) return 53;
    int verified = verify_readback(&readback); if (verified) return verified;
    print_consumer_result(samples, YES); return 0;
}
int main(int argc, const char **argv) { @autoreleasepool {
    if (argc == 2 && !strcmp(argv[1], "device")) {
        id<MTLDevice> d = MTLCreateSystemDefaultDevice(); if (!d) return 2;
        printf("%llu\n", (unsigned long long)d.registryID); return 0;
    }
    if (argc < 5) return 2;
    NSString *mode = @(argv[1]), *service = @(argv[2]), *token = @(argv[3]);
    uint64_t registry = strtoull(argv[4], NULL, 10); id<MTLDevice> device = exact_device(registry); if (!device) return 3;
    if ([mode isEqualToString:@"broker"]) return ffst_broker_run(service, token, registry, FFST_DEFAULT_MAX_CUTS, FFST_DEFAULT_MAX_BYTES, 30, 0, 0);
    if (argc != 6) return 2;
    NSUInteger samples = (NSUInteger)strtoul(argv[5], NULL, 10); if (samples != 1 && samples != 2) return 2;
    if ([mode isEqualToString:@"producer-attachment"]) return producer_attachment(service, token, device, samples);
    if ([mode isEqualToString:@"consumer-executor"]) return consumer_executor(device, samples);
    if ([mode isEqualToString:@"producer"]) return producer(service, token, device, samples);
    if ([mode isEqualToString:@"consumer"]) return consumer(service, token, device, samples);
    return 2;
} }
