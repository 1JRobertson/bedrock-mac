#import "shared_texture_attachment.h"
#include <limits.h>

#if !__has_feature(objc_arc)
#error shared_texture_attachment.m requires ARC
#endif
typedef struct { uint64_t source_id, source_generation; NSUInteger level, slice; } FFSTCopyRecord;

@interface FFSTCopyBundle : NSObject
@property(nonatomic) uint64_t cutID, reservedBytes;
@property(nonatomic, strong) id<MTLFence> readyFence;
@property(nonatomic, strong) NSArray<id<MTLTexture>> *originals, *copies;
@property(nonatomic, strong) NSData *sourceRecords, *attachmentRecords;
@property(nonatomic, copy) FFSTCompletion completion;
@end
@implementation FFSTCopyBundle
@end

@interface FFSTCopyState : NSObject
@property(nonatomic) FFSTProducer producer;
@property(nonatomic, strong) id<MTLDevice> device;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableDictionary<NSNumber *, FFSTCopyBundle *> *pending;
@property(nonatomic) uint32_t maxCuts;
@property(nonatomic) uint64_t maxBytes, bytes;
@property(nonatomic) BOOL closed;
@property(nonatomic, strong) dispatch_queue_t callbacks;
@end
@implementation FFSTCopyState
- (void)dealloc { if (_producer) ffst_producer_destroy(_producer); }
@end

FFSTAttachmentCapture ffst_attachment_capture_create(FFSTProducer producer,
    id<MTLDevice> device, uint32_t max_cuts, uint64_t max_bytes) {
    if (!producer || !device || !max_cuts || max_cuts > 16 || !max_bytes || max_bytes > (UINT64_C(1) << 30)) return NULL;
    FFSTCopyState *s = [FFSTCopyState new]; s.producer = producer; s.device = device;
    s.lock = [NSLock new]; s.pending = [NSMutableDictionary dictionary];
    s.maxCuts = max_cuts; s.maxBytes = max_bytes;
    s.callbacks = dispatch_queue_create("bedrock.shared-texture.attachment", DISPATCH_QUEUE_SERIAL);
    return (__bridge_retained void *)s;
}
void ffst_attachment_capture_destroy(FFSTAttachmentCapture capture) {
    if (!capture) return;
    FFSTCopyState *s = (__bridge_transfer FFSTCopyState *)capture;
    [s.lock lock]; s.closed = YES; [s.lock unlock];
}
uint32_t ffst_attachment_capture_pending(FFSTAttachmentCapture capture, uint64_t *bytes) {
    if (bytes) *bytes = 0;
    if (!capture) return 0;
    FFSTCopyState *s = (__bridge FFSTCopyState *)capture;
    [s.lock lock]; uint32_t count = (uint32_t)s.pending.count; if (bytes) *bytes = s.bytes; [s.lock unlock]; return count;
}
static void finish(FFSTCopyState *s, FFSTCopyBundle *bundle, FFSTResult result, BOOL notify) {
    [s.lock lock];
    BOOL owned = s.pending[@(bundle.cutID)] == bundle;
    if (owned) { s.bytes -= bundle.reservedBytes; [s.pending removeObjectForKey:@(bundle.cutID)]; }
    [s.lock unlock];
    if (owned && notify) dispatch_async(s.callbacks, ^{ bundle.completion(bundle.cutID, result); });
}
static BOOL source_valid(const FFSTAttachmentSource *source, id<MTLDevice> device) {
    id<MTLTexture> t = source->texture;
    if (!t || t.device != device || !source->source_id || !source->source_generation || !t.width || !t.height ||
        t.width > 8192 || t.height > 8192 || !ffst_attachment_format_supported(t.pixelFormat, source->role) || t.storageMode == MTLStorageModeMemoryless ||
        (t.textureType != MTLTextureType2D && t.textureType != MTLTextureType2DMultisample) ||
        source->slice || source->level >= t.mipmapLevelCount || !ffst_sample_count_supported(device, t.sampleCount) ||
        (t.sampleCount != 1 && source->level)) return NO;
    MTLTextureSwizzleChannels swizzle = t.swizzle;
    if (swizzle.red != MTLTextureSwizzleRed || swizzle.green != MTLTextureSwizzleGreen ||
        swizzle.blue != MTLTextureSwizzleBlue || swizzle.alpha != MTLTextureSwizzleAlpha) return NO;
    if (source->role < FFST_COLOR || source->role > FFST_STENCIL ||
        (source->role == FFST_COLOR ? source->attachment_index > 7 : source->attachment_index != 0)) return NO;
    return YES;
}
int ffst_attachment_capture_schedule(FFSTAttachmentCapture capture,
    id<MTLCommandBuffer> command, uint64_t cut_id,
    const FFSTAttachmentSource *sources, size_t source_count,
    const id<MTLFence> *fences, size_t fence_count,
    id<MTLFence> __autoreleasing *ready_fence, FFSTCompletion completion) {
    if (ready_fence) *ready_fence = nil;
    if (!capture || !command || !cut_id || !sources || !source_count || source_count > FFST_MAX_ATTACHMENTS ||
        !ready_fence || !completion || fence_count > 64 || (fence_count && !fences) || command.status > MTLCommandBufferStatusEnqueued) return 0;
    FFSTCopyState *s = (__bridge FFSTCopyState *)capture;
    if (command.device != s.device) return 0;
    for (size_t i = 0; i < fence_count; ++i) if (!fences[i] || fences[i].device != s.device) return 0;
    FFSTAttachmentSource selected[FFST_MAX_TEXTURES] = {0};
    FFSTAttachmentRef refs[FFST_MAX_ATTACHMENTS] = {0}; size_t count = 0; uint64_t estimated = 0;
    for (size_t i = 0; i < source_count; ++i) {
        const FFSTAttachmentSource *source = &sources[i];
        if (!source_valid(source, s.device)) return 0;
        for (size_t j = 0; j < i; ++j) if (refs[j].role == source->role && refs[j].attachment_index == source->attachment_index) return 0;
        size_t j;
        for (j = 0; j < count; ++j) if (selected[j].texture == source->texture && selected[j].level == source->level && selected[j].slice == source->slice) break;
        if (j < count) {
            if (selected[j].source_id != source->source_id || selected[j].source_generation != source->source_generation) return 0;
        } else {
            if (count == FFST_MAX_TEXTURES) return 0;
            for (size_t k = 0; k < count; ++k) if (selected[k].source_id == source->source_id && selected[k].texture != source->texture) return 0;
            NSUInteger width = MAX((NSUInteger)1, source->texture.width >> source->level);
            NSUInteger height = MAX((NSUInteger)1, source->texture.height >> source->level);
            /* Conservative budget before allocation: every admitted format uses
             * at most 16 bytes per pixel/sample, plus tile-alignment headroom. */
            uint64_t padded_width = ((uint64_t)width + 255) & ~UINT64_C(255);
            uint64_t padded_height = ((uint64_t)height + 15) & ~UINT64_C(15);
            uint64_t bytes = padded_width * padded_height * source->texture.sampleCount * 16;
            if (bytes > s.maxBytes - estimated) return 0;
            estimated += bytes; selected[count++] = *source;
        }
        refs[i] = (FFSTAttachmentRef){source->role, source->attachment_index, j};
    }
    FFSTCopyBundle *bundle = [FFSTCopyBundle new]; bundle.cutID = cut_id; bundle.reservedBytes = estimated; bundle.completion = completion;
    [s.lock lock];
    BOOL reserve = !s.closed && s.pending.count < s.maxCuts && !s.pending[@(cut_id)] && estimated <= s.maxBytes - s.bytes;
    if (reserve) { s.pending[@(cut_id)] = bundle; s.bytes += estimated; }
    [s.lock unlock]; if (!reserve) return 0;
    NSMutableArray<id<MTLTexture>> *originals = [NSMutableArray array], *copies = [NSMutableArray array];
    uint64_t allocated = 0;
    for (size_t i = 0; i < count; ++i) {
        id<MTLTexture> original = selected[i].texture;
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor new];
        descriptor.textureType = original.sampleCount > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
        descriptor.pixelFormat = original.pixelFormat;
        descriptor.width = MAX((NSUInteger)1, original.width >> selected[i].level);
        descriptor.height = MAX((NSUInteger)1, original.height >> selected[i].level);
        descriptor.sampleCount = original.sampleCount; descriptor.mipmapLevelCount = 1;
        descriptor.storageMode = MTLStorageModePrivate; descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
        descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> copy = [s.device newSharedTextureWithDescriptor:descriptor];
        if (!copy || !copy.allocatedSize || copy.allocatedSize > s.maxBytes - allocated) { finish(s, bundle, FFST_REJECTED, NO); return 0; }
        allocated += copy.allocatedSize; [originals addObject:original]; [copies addObject:copy];
    }
    bundle.originals = originals; bundle.copies = copies;
    FFSTCopyRecord records[FFST_MAX_TEXTURES] = {0};
    for (size_t i = 0; i < count; ++i) records[i] = (FFSTCopyRecord){selected[i].source_id, selected[i].source_generation, selected[i].level, selected[i].slice};
    bundle.sourceRecords = [NSData dataWithBytes:records length:count * sizeof(records[0])];
    bundle.attachmentRecords = [NSData dataWithBytes:refs length:source_count * sizeof(refs[0])];
    bundle.readyFence = [s.device newFence];
    if (!bundle.readyFence) { finish(s, bundle, FFST_REJECTED, NO); return 0; }
    [s.lock lock];
    BOOL within_budget = allocated <= bundle.reservedBytes || allocated - bundle.reservedBytes <= s.maxBytes - s.bytes;
    if (within_budget) { s.bytes = s.bytes - bundle.reservedBytes + allocated; bundle.reservedBytes = allocated; }
    BOOL closed = s.closed; [s.lock unlock];
    if (!within_budget || closed) { finish(s, bundle, FFST_REJECTED, NO); return 0; }
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!blit) { finish(s, bundle, FFST_REJECTED, NO); return 0; }
    for (size_t i = 0; i < fence_count; ++i) [blit waitForFence:fences[i]];
    for (size_t i = 0; i < count; ++i) {
        id<MTLTexture> copy = copies[i];
        [blit copyFromTexture:originals[i] sourceSlice:selected[i].slice sourceLevel:selected[i].level sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(copy.width, copy.height, 1) toTexture:copy destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    }
    [blit updateFence:bundle.readyFence]; [blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        dispatch_async(s.callbacks, ^{
            bundle.originals = nil; /* Original GPU use ended; only owned copies cross IPC. */
            if (completed.status != MTLCommandBufferStatusCompleted) { finish(s, bundle, FFST_GPU_FAILED, YES); return; }
            [s.lock lock]; BOOL stopped = s.closed; [s.lock unlock];
            if (stopped) { finish(s, bundle, FFST_CLOSED, YES); return; }
            FFSTTextureInput inputs[FFST_MAX_TEXTURES] = {0};
            const FFSTCopyRecord *records = bundle.sourceRecords.bytes;
            for (size_t i = 0; i < count; ++i) inputs[i] = (FFSTTextureInput){bundle.copies[i], records[i].source_id,
                records[i].source_generation, records[i].level, records[i].slice};
            if (!ffst_producer_publish(s.producer, completed, cut_id, inputs, count, bundle.attachmentRecords.bytes, source_count,
                ^(uint64_t result_cut, FFSTResult result) {
                    finish(s, bundle, result_cut == cut_id ? result : FFST_REJECTED, YES);
                })) finish(s, bundle, FFST_REJECTED, YES);
        });
    }];
    *ready_fence = bundle.readyFence; return 1;
}
