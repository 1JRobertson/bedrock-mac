#ifndef FFST_NATIVE_PIPELINE_REGISTRY_H
#define FFST_NATIVE_PIPELINE_REGISTRY_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import "vertex_resources.h"

/* Immutable result of a validated pipeline definition. Keep a strong reference
 * through actual GPU completion; a destroy only revokes future lookups. */
@interface FFSTPipelineBinding : NSObject
@property(nonatomic,readonly,strong) id<MTLRenderPipelineState> pipeline;
@property(nonatomic,readonly) ff_draw_layout layout;
/* Reflected texture requirements for argument-table byte offset, or nil. */
- (MTLTextureReferenceType *)textureReferenceForStage:(unsigned)stage offset:(uint32_t)offset;
@end

/* Single-owner ordered-command registry, deliberately not thread safe.
 * Object and generation are nonzero. Each object may only advance generation,
 * including after destruction; tombstones are bounded by maxObjects. Exhaustion
 * rejects a new identity, never forgets history and silently aliases stale IDs.
 * Definitions are immutable. The caller must provide reflection returned when
 * creating this exact pipeline with binding/type reflection enabled. */
@interface FFSTPipelineRegistry : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device maxObjects:(NSUInteger)maxObjects;
- (BOOL)defineObject:(uint64_t)object generation:(uint64_t)generation
           pipeline:(id<MTLRenderPipelineState>)pipeline
         reflection:(MTLRenderPipelineReflection *)reflection iaMask:(uint32_t)iaMask;
- (FFSTPipelineBinding *)bindingForObject:(uint64_t)object generation:(uint64_t)generation;
- (BOOL)destroyObject:(uint64_t)object generation:(uint64_t)generation;
@end
#endif
