/* Ordered native execution of actual frame_stream payloads. ARC, local only. */
#ifndef FULLFRAME_NATIVE_FRAME_EXECUTE_H
#define FULLFRAME_NATIVE_FRAME_EXECUTE_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "frame_stream.h"
#import "native_frame_queue.h"
#import "shared_texture_pass_execute.h"

#define FFST_NATIVE_FRAME_MAX_PASSES 128
#define FFST_NATIVE_FRAME_MAX_BYTES (512ull * 1024 * 1024)
#define FFST_NATIVE_READBACK_MAX_BYTES (32ull * 1024 * 1024)
#define FFST_NATIVE_READBACK_MAX_RANGES 255u

/* Exact native buffer contents at the end of the original chunk. Only tight
 * pixel rows are packed into bytes; untouched/undefined padding is excluded.
 * Scatter row i to logical offset+i*rowBytes in the original backing AFTER
 * validating the complete chunk identity and every expected return range.
 * These bytes are CPU-owned snapshots after actual GPU/import retirement.
 * They do not attest that source Map backing has already been updated. */
@interface FFSTNativeBufferReadback : NSObject
@property(nonatomic,readonly) uint64_t chunk,root,generation,contentVersion;
@property(nonatomic,readonly) uint64_t offset,rowBytes,rowLength,rowCount;
@property(nonatomic,readonly) uint32_t encoder,command;
@property(nonatomic,readonly) NSData *bytes;
@end

/* The producer supplies a v2 whole-pass manifest or a v3 indexed delta with
 * an owned v2 template, plus a logical identity sidecar, all bound to
 * ENCODER_BEGIN.data[4]. The directory contains
 * that pass's existing SHA libraries and immutable cut payload files. Blob
 * factories provide the same assets entirely in memory. FD mode has blobs=nil;
 * memory mode has directory=-1 and cannot read from the filesystem. */
@interface FFSTNativeFramePassPayload : NSObject
@property(nonatomic,readonly) int directory;
@property(nonatomic,readonly) NSDictionary<NSString *,NSData *> *blobs;
@property(nonatomic,readonly) NSDictionary *manifest;
@property(nonatomic,readonly) NSDictionary *bindings;
+ (instancetype)payloadWithDirectory:(int)directory manifest:(NSDictionary *)manifest
    bindings:(NSDictionary *)bindings failure:(NSString **)failure;
/* In-memory blobs are copied to immutable ownership, bounded to 64MiB total.
 * directory is -1; consumers must never fall back to filesystem reads. */
+ (instancetype)payloadWithBlobs:(NSDictionary<NSString *,NSData *> *)blobs
    manifest:(NSDictionary *)manifest bindings:(NSDictionary *)bindings failure:(NSString **)failure;
@end

/* Non-render encoders own either a private directory FD or immutable blobs. */
@interface FFSTNativeFrameOperationPayload : NSObject
@property(nonatomic,readonly) int directory;
@property(nonatomic,readonly) NSDictionary<NSString *,NSData *> *blobs;
@property(nonatomic,readonly) NSDictionary *bindings;
+ (instancetype)payloadWithDirectory:(int)directory bindings:(NSDictionary *)bindings
    failure:(NSString **)failure;
+ (instancetype)payloadWithBlobs:(NSDictionary<NSString *,NSData *> *)blobs
    bindings:(NSDictionary *)bindings failure:(NSString **)failure;
@end

@protocol FFSTNativeFramePayloadProvider <NSObject>
/* Returned payload owns its directory FD; no game pointer/handle enters here. */
- (FFSTNativeFramePassPayload *)renderPayload:(uint64_t)payloadID
    stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure;
@optional
- (FFSTNativeFrameOperationPayload *)operationPayload:(uint64_t)payloadID
    stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure;
- (NSDictionary *)presentPayload:(uint64_t)payloadID stream:(uint64_t)stream
    frame:(uint64_t)frame failure:(NSString **)failure;
/* Only exact initial attachment versions may be imported. Implementations keep
 * leases alive through frame GPU completion and acknowledge retirement below.
 * Internal reads always resolve the earlier native result before this hook. */
- (id<MTLTexture>)initialTexture:(NSDictionary *)reference device:(id<MTLDevice>)device
    failure:(NSString **)failure;
/* External dependency payloads attest completed immutable source snapshots;
 * metadata-only or unfinished producer work must return NO. */
- (BOOL)externalDependencyCompleted:(const ffs_record *)record failure:(NSString **)failure;
/* Install all imported-storage completion hooks BEFORE command commit. */
- (BOOL)finishImportsWithCommand:(id<MTLCommandBuffer>)command failure:(NSString **)failure;
/* Wait for actual GPU completion plus every producer retirement ACK. */
- (BOOL)waitForImportRetirement:(NSString **)failure;
/* Only for a frame never committed. Never abandon in-flight GPU storage. */
- (void)abandonImports;
/* Optional sealed snapshot arena lease. Submission precedes the first Metal
 * commit; completion follows actual command retirement. Failed pre-submit
 * execution abandons only after immutable views release their pins. */
- (BOOL)sharedSnapshotWillSubmit:(NSString **)failure;
- (BOOL)sharedSnapshotGPUCompleted:(NSString **)failure;
- (void)sharedSnapshotAbandon;
@end

@interface FFSTNativeFrameRequest : NSObject <FFSTQueuedFrame>
@property(nonatomic,readonly) uint64_t streamID,frameID;
@property(nonatomic,readonly) size_t retainedBytes;
@property(nonatomic,readonly) NSData *records;
@property(nonatomic,readonly) id<FFSTNativeFramePayloadProvider> payloads;
/* firstSequence comes from the trusted stream receiver. Validation consumes
 * the complete ledger; unsupported or incomplete frames never become requests.
 * retainedBytes includes all retained pass payloads, not just these wire bytes. */
+ (instancetype)requestWithRecords:(NSData *)records firstSequence:(uint64_t)firstSequence
    retainedBytes:(size_t)bytes payloads:(id<FFSTNativeFramePayloadProvider>)payloads
    failure:(NSString **)failure;
@end

@interface FFSTNativeFrameExecution : NSObject
@property(nonatomic,readonly) id<MTLTexture> texture;
@property(nonatomic,readonly) NSData *pixels;
@property(nonatomic,readonly) NSUInteger rowBytes;
/* Completion binds the exact stream/frame/digest and final root/view/version
 * to real command completion. This does not claim presenter completion. */
@property(nonatomic,readonly) NSDictionary *metrics;
@property(nonatomic,readonly) NSArray<FFSTNativeBufferReadback *> *bufferReadbacks;
@end

/* One native command buffer per original chunk, encoders in ledger order. Native writes
 * feed later Load and sampled inputs, preserving color/MSAA/depth/stencil roots.
 * No publication on unsupported encoders, missing payloads or failed completion.
 * The caller may submit this synchronous operation to FFSTNativeFrameQueue. */
FFSTNativeFrameExecution *ffst_native_frame_execute(FFSTNativeFrameRequest *request,
    FFSTPassLibraryResolver libraries, BOOL (^cancelled)(void), NSString **failure);
#endif
