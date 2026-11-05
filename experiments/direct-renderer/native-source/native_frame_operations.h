/* Strict CPU-only decoder for supported auxiliary frame encoder payloads. ARC. */
#ifndef FULLFRAME_NATIVE_FRAME_OPERATIONS_H
#define FULLFRAME_NATIVE_FRAME_OPERATIONS_H
#import <Foundation/Foundation.h>
#include <stdint.h>
#include "frame_stream.h"

#define FFST_OPERATION_BUFFER_BYTES (32ull * 1024 * 1024)
#define FFST_OPERATION_IMPORT_BYTES (128ull * 1024 * 1024)

@interface FFSTNativeFrameOperations : NSObject
@property(nonatomic,readonly) NSArray<NSDictionary *> *operations;
@property(nonatomic,readonly) NSDictionary<NSNumber *,NSData *> *bufferImports;
@property(nonatomic,readonly) NSDictionary<NSNumber *,NSDictionary *> *textureImports;
@property(nonatomic,readonly) uint64_t importedBytes;
@end
#ifdef __cplusplus
extern "C" {
#endif
/* Validates format bedrock-native-frame-operation/version1 and category BLIT,
 * TIMESTAMP or SIGNAL_EVENT. Engine still compares complete resource references,
 * stream/frame/encoder identity, command types and dependencies against its ledger.
 * Returned operation metadata is a deep immutable copy. Import keys are zero-based
 * indices in bindings.resources; imported NSData preserves each view's exact bytes.
 *
 * Blit: resources[] are strict FFS_BUFFER or qualified FFS_TEXTURE references.
 * Textures are identity-swizzled full-root 2D or Cube, one sample, base mip/slice zero,
 * uncompressed color and dimensions <=8192. Buffer refs have root/view/generation/version,
 * payload_id, absolute offset/length and buffer_length/buffer_base_offset. Capacity
 * is <=32MiB per root; view ranges fit that capacity relative to base offset.
 * command_types[] and operations[] have identical bounded order (0 nop,
 * 1 copy_buffer,2 copy_buffer_to_texture,3 copy_texture_to_buffer,4 copy_texture_to_texture). Texture copies
 * preserve exact pitches, size, texture mip and origin; depth1/z0 only.
 * Buffer/texture copies retain their 2D/slice0 subset. Texture/texture copies
 * admit Cube physical faces0..5 (Metal array_length remains1); arrays reject.
 * Image pitch0 is valid for 2D; nonzero pitch must contain all padded rows. The buffer byte footprint
 * ends at the last copied texel, not the end of its trailing row padding.
 * Texture-to-buffer destinations retain view-relative offset and row/image
 * pitches; the engine checks source READ and destination READ|WRITE evidence.
 * Initial texture-to-buffer staging requires the effective native destination
 * offset, row pitch and tight row length to be multiples of4 (macOS blit rule).
 * Copy offsets are view-relative; same-root/generation overlapping copies reject.
 * copy_texture_to_texture uses exact matching formats, source/destination resource indices,
 * slices, mip levels, origins and source_size. All same-root/generation copies
 * reject, including disjoint mips/rectangles; physical Metal aliases reject
 * during execution. The engine requires source READ and destination READ|WRITE
 * ledger evidence, a defined source face/mip and a defined destination face/mip
 * for partial writes, and advances versions only after the
 * ordered encoder finishes. Full-mip copies can initialize a new destination.
 * A full-face copy defines only that face/mip; all six faces define a Cube mip.
 * Missing preimages on a previously unknown destination require complete
 * canonical face/mip coverage before encoder completion. Reads and partial
 * writes require that exact source/destination face to be defined in order.
 * Optional buffers[] entries use resource,file,bytes; unique resource indices and
 * exact sequential operation-buffer-%02u.bin names starting at 1. Each bytes equals
 * its ref.length and <=32MiB; total is <=min(maxBytes,128MiB). maxBytes0 permits no
 * imported bytes (internal native-root operations remain possible).
 * Optional textures[] use resource,file,length,format,texture_type,width,height,
 * mip_count,array_length,swizzle,planes and operation-texture-%02u.bin names.
 * They contain every face/mip in slice-major/mip-fast canonical 256-byte row layout; each
 * texture is <=32MiB. textureImports maps resource index to {metadata,bytes};
 * importedBytes and the shared 128MiB/budget limit include both import kinds.
 * Aliased full texture preimages must contain identical bytes at one root input
 * version, regardless of their view IDs or resource indices.
 *
 * Timestamp/signal have exactly one operation and absent/empty resources,
 * command_types and buffers arrays. Timestamp mode is command-buffer-end-ns,
 * query_count 1..1M counts coalesced destinations; the independent chunk-global
 * readback_index is bounded to 1M. Signal domain is FFS_EVENT,
 * id/value nonzero. No Boolean/float is accepted in an integer field.
 *
 * directory is borrowed and must be an owned private directory FD. Payloads must
 * be owned regular mode0600 files, nlink1, opened without following symlinks and
 * checked stable across exact-length reads. No GPU/IPC calls or device selection.
 * failure receives only a bounded diagnostic, never raw payload/log content. */
FFSTNativeFrameOperations *ffst_native_frame_operations_load(int directory,
    NSDictionary *bindings,uint64_t maxBytes,NSString **failure);
/* No FD fallback or invented uid/mode checks. Immutable blob snapshots share
 * all operation, name, exact-length and byte-budget validation above. */
FFSTNativeFrameOperations *ffst_native_frame_operations_load_blobs(
    NSDictionary<NSString *,NSData *> *blobs,NSDictionary *bindings,uint64_t maxBytes,NSString **failure);
#ifdef __cplusplus
}
#endif
#endif
