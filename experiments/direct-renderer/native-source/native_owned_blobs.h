/* Internal ownership capability. Never construct from caller/mmap NSData.
 * Only the chunk decoder supplies independently owned immutable byte snapshots
 * and verified raw SHA256 or distinct canonical buffer page identities.
 * Public blob APIs still copy. */
#ifndef BEDROCK_NATIVE_OWNED_BLOBS_H
#define BEDROCK_NATIVE_OWNED_BLOBS_H
#import "native_frame_execute.h"
#import "native_frame_operations.h"
#import "shared_texture_pass_resources.h"
#import "native_snapshot_arena.h"

@interface FFSTReplayDecodeCache : NSObject
- (NSDictionary *)decode:(NSData *)wire;
- (NSDictionary *)stats;
@end

@interface FFSTOwnedBlobs : NSObject
@property(nonatomic,readonly) NSDictionary<NSString *,NSData *> *blobs;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;
- (NSDictionary *)jsonDictionary:(NSString *)name;
/* Only an exact whole-blob pointer/length match grants digest reuse. */
- (NSData *)verifiedDigestForBytes:(const void *)bytes length:(NSUInteger)length;
/* Canonical page identity is a distinct capability, never a library SHA. */
- (NSData *)verifiedBufferIDForBytes:(const void *)bytes length:(NSUInteger)length;
/* Only an exact decoder-owned arena view may bypass a Metal buffer upload. */
- (NSData<FFSTSharedSnapshotMemory> *)verifiedSharedSnapshotForBytes:(const void *)bytes length:(NSUInteger)length;
@end
FFSTOwnedBlobs *ffst_owned_blobs_from_decoder(NSDictionary<NSString *,NSData *> *blobs,
    NSDictionary<NSString *,NSData *> *digests,NSString **failure);
FFSTOwnedBlobs *ffst_owned_blobs_with_page_ids_from_decoder(NSDictionary<NSString *,NSData *> *blobs,
    NSDictionary<NSString *,NSData *> *digests,NSDictionary<NSString *,NSData *> *pageIDs,NSString **failure);
/* A previously validated replay-template.json parsed under the same verified
 * content key may be reused while the transport cache retains those bytes. */
FFSTOwnedBlobs *ffst_owned_blobs_with_template_from_decoder(NSDictionary<NSString *,NSData *> *blobs,
    NSDictionary<NSString *,NSData *> *digests,NSDictionary<NSString *,NSData *> *pageIDs,
    NSDictionary *parsedTemplate,NSString **failure);

FFSTOwnedBlobs *ffst_owned_blobs_with_replay_cache_from_decoder(NSDictionary *blobs,NSDictionary *digests,NSDictionary *pageIDs,NSDictionary *parsedTemplate,FFSTReplayDecodeCache *replayCache,NSString **failure);

@interface FFSTNativeFramePassPayload (OwnedBlobs)
@property(nonatomic,readonly) FFSTOwnedBlobs *ownedBlobs;
+ (instancetype)payloadWithOwnedBlobs:(FFSTOwnedBlobs *)owned failure:(NSString **)failure;
@end
@interface FFSTNativeFrameOperationPayload (OwnedBlobs)
@property(nonatomic,readonly) FFSTOwnedBlobs *ownedBlobs;
+ (instancetype)payloadWithOwnedBlobs:(FFSTOwnedBlobs *)owned failure:(NSString **)failure;
@end

FFSTPassResources ffst_pass_resources_load_owned(FFSTOwnedBlobs *owned);
FFSTNativeFrameOperations *ffst_native_frame_operations_load_owned(FFSTOwnedBlobs *owned,
    NSDictionary *bindings,uint64_t maxBytes,NSString **failure);

/* Preserve each loader's exact allowlist/budgets without recopying owned bytes. */
static inline BOOL ffst_owned_blob_bounds(FFSTOwnedBlobs *owned,NSUInteger (*limit)(NSString *)) {
    if(!owned||owned.blobs.count>8192)return NO;NSUInteger total=0;
    for(NSString *name in owned.blobs){NSData *data=owned.blobs[name];NSUInteger maximum=limit(name);
        if(!maximum||!data.length||data.length>maximum||data.length>64u*1024u*1024u-total)return NO;total+=data.length;}
    return YES;
}
#endif
