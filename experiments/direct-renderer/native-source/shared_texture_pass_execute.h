/* ARM64 execution of an ordered original pass/prefix with one owned asset graph.
 * No presentation, game launch or installed-runtime changes. Compile with ARC. */
#ifndef FULLFRAME_SHARED_TEXTURE_PASS_EXECUTE_H
#define FULLFRAME_SHARED_TEXTURE_PASS_EXECUTE_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface FFSTPassExecution : NSObject
@property(nonatomic, readonly) id<MTLTexture> texture; /* Own resolved ShaderRead output. */
@property(nonatomic, readonly) NSData *pixels;
@property(nonatomic, readonly) NSUInteger rowBytes;
@property(nonatomic, readonly) NSDictionary *metrics;
@end
/* Optional host-owned native-library cache, also usable by an authored GPU oracle.
 * nil uses strict private SHA-addressed .metallib files. Supplied libraries must
 * already be validated/compiled by the host and belong to the exact GPU. This
 * changes no resource, pipeline-state, reflection or draw validation. */
typedef id<MTLLibrary> (^FFSTPassLibraryResolver)(NSString *file);
/* Synchronous render-worker operation. Caller owns private directory FD. Reads
 * draw-resource-cut.json v2 and validates every manifest draw against its ordered
 * resource plan. Creates/uploads globals once; per-draw tables remain alive
 * through the single GPU completion. Exact Load bundles are acquired by cut ID
 * and acknowledged after the final imported-storage access. Output texture is
 * always independent of imported leases before return, suitable for presenter.
 * cancelled may be nil; queried between bounded CPU/encoding operations. */
FFSTPassExecution *ffst_pass_execute(int directory, NSDictionary *manifest,
    FFSTPassLibraryResolver libraries, BOOL (^cancelled)(void), NSString **failure);
#endif
