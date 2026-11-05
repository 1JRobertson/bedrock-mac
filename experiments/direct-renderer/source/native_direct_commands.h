/* Serial, fail-stop native buffer-command receiver. */
#ifndef BEDROCK_NATIVE_DIRECT_COMMANDS_H
#define BEDROCK_NATIVE_DIRECT_COMMANDS_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "native_persistent_resources.h"
#import "native_pipeline_registry.h"
#import "native_direct_bindings.h"
/* GPU receipt is called only after actual Metal completion. Batches on the
 * same queue may overlap CPU submission; callbacks are delivered in submission order.
 * A failed GPU batch causes its own and all later accepted receipts to fail,
 * even if a later command buffer reports completed. Reject/backpressure never
 * implies completion. A receipt callback exception also poisons the receiver;
 * later accepted callbacks receive failure while all work drains. A failed
 * semantic command poisons the session, as prior registry effects cannot roll
 * back. Resource destruction invalidates immediately; batch retains GPU uses. */
typedef id<MTLTexture> (^FFDCTargetLookup)(uint64_t object,uint64_t generation);
/* Authoritative metadata owners must qualify the actual bound objects. Return
 * YES only when pipeline attachment format/sample count and target agree, and
 * no sampled texture subresource aliases any target backing allocation. Pointer
 * inequality is not proof: views and separately imported objects can alias. */
typedef BOOL (^FFDCCompatibleTarget)(FFSTPipelineBinding *pipeline,id<MTLTexture> target);
typedef BOOL (^FFDCTextureDisjoint)(id<MTLTexture> target,FFPRHandle sampledHandle,id<MTLTexture> sampled);
typedef void (^FFDCCompletion)(uint64_t serial,uint64_t completion,BOOL succeeded);
typedef NS_ENUM(NSUInteger, FFDCSubmitResult) {
    FFDCSubmitAccepted, FFDCSubmitBusy, FFDCSubmitInvalid, FFDCSubmitFailed
};
@interface FFDCReceiver : NSObject
/* Registry methods are not thread-safe. Inspect or mutate only while no submit
 * can race, and honor the single ordered-queue resource contract. */
@property(nonatomic,readonly) FFPRRegistry *registry;
- (instancetype)initWithDevice:(id<MTLDevice>)device;
/* The caller owns synchronized pipeline/target registration. Target lookup is
 * synchronous and must return the exact generation, or nil. Passes use one
 * 2D color target with clear/store. The legacy initializer has no texture or
 * sampler resolver and rejects draws requiring those resources. */
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines targetLookup:(FFDCTargetLookup)lookup;
/* Resolvers return only live exact generations. Samplers must support Metal
 * argument buffers; callbacks and registries are serialized with submit. */
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines
    targetLookup:(FFDCTargetLookup)lookup textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers;
/* Render draws fail closed unless compatibility is supplied. Non-null sampled
 * textures additionally require a disjoint proof. Proofs must account for all
 * backing aliases and remain valid through GPU completion. */
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines
    targetLookup:(FFDCTargetLookup)lookup textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers
    targetCompatibility:(FFDCCompatibleTarget)compatible textureDisjoint:(FFDCTextureDisjoint)disjoint;
/* Up to four submissions and 64 MiB of packet bytes may remain outstanding,
 * including callbacks currently executing. FFPR separately bounds buffer and
 * staging bytes. Each batch allows up to 1,024 distinct prepared binding
 * snapshots; repeated draws reuse unchanged state. Draws with IA tables and
 * ordinary resource-slot commands reject until reflection can prove their
 * access ranges and types. External target,
 * texture, sampler and pipeline memory is caller-owned. Submit is thread-safe;
 * batches must still arrive in strict stream order. */
- (FFDCSubmitResult)submit:(const void *)bytes length:(size_t)length completion:(FFDCCompletion)completion;
/* First close rejects future submissions; its required callback runs once after
 * all accepted receipt callbacks return. Later close calls return NO. */
- (BOOL)closeWithCompletion:(void (^)(void))completion;
@end
#endif
