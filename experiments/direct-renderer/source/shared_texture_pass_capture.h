/* Ordered ordinary-pass state for the resource collector's exact draw prefix.
 * This module is independent of the current one-draw capture path. ARC source. */
#ifndef FULLFRAME_SHARED_TEXTURE_PASS_CAPTURE_H
#define FULLFRAME_SHARED_TEXTURE_PASS_CAPTURE_H
#import <Foundation/Foundation.h>
#import "draw_resource_cut.h"

@interface FFSTPassPipelineSnapshot : NSObject
@property(nonatomic, strong) NSData *vertexLibrary, *fragmentLibrary;
@property(nonatomic, strong) NSString *vertexFunction, *fragmentFunction;
@property(nonatomic, strong) NSDictionary *state; /* Existing pipeline_state ABI. */
@property(nonatomic) NSUInteger topology;
@property(nonatomic, strong) NSData *layout; /* Canonical zero-filled ff_draw_layout. */
/* Retain the registry's measured byte owners, not only their NSData payloads,
 * so retained pass plans stay inside the same shader-byte budget. */
@property(nonatomic, strong) NSArray *byteOwners;
@end
typedef FFSTPassPipelineSnapshot *(^FFSTPassPipelineResolver)(id<MTLRenderPipelineState> pipeline);
typedef NSDictionary *(^FFSTPassDepthResolver)(id<MTLDepthStencilState> state);

@interface FFSTPassRecord : NSObject
@property(nonatomic, readonly) NSDictionary *manifest;
@property(nonatomic, readonly) NSDictionary<NSString *, NSData *> *libraries;
@property(nonatomic, readonly) NSArray *byteOwners;
@end

/* Walks the actual command list in order. Every emitted draw must match the
 * resource graph's command identity, tuple and shader layout. Unsupported state
 * or missing provenance ends the prefix; nothing is skipped and then resumed.
 * No game pointer/object/handle is serialized. Returns nil for an empty prefix.
 * "contains_geometry_candidate" is only the declared >6+IA+VS-constant filter,
 * not terrain identity. The host controls arming and pass selection. */
FFSTPassRecord *ffst_pass_capture_record(const struct WMTRenderPassInfo *pass,
    const struct wmtcmd_base *head, const struct ff_draw_cut *resources,
    FFSTPassPipelineResolver pipeline, FFSTPassDepthResolver depth);
/* Atomic completion marker in an already-owned private directory. Library names
 * are SHA-256-addressed and bounded; existing files are always preserved. Partial
 * writes remain private evidence, never a completed pass. Does no GPU work. */
int ffst_pass_capture_write(int directory, FFSTPassRecord *record, const char *manifest_name);
#endif
