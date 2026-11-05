#ifndef FFST_NATIVE_DIRECT_BINDINGS_H
#define FFST_NATIVE_DIRECT_BINDINGS_H
#import "native_pipeline_registry.h"
#import "native_persistent_resources.h"

/* Inputs are copied synchronously; handles are exact generation identities.
 * Null resources use the all-zero reference. Buffers point into FFPRRegistry;
 * texture/sampler callbacks must resolve exact live generations in stream order.
 * Samplers must be created with MTLSamplerDescriptor.supportArgumentBuffers=YES;
 * Metal exposes no equivalent query on the returned MTLSamplerState. */
typedef struct { FFPRHandle handle; uint64_t offset; uint32_t stride,length; } FFDBBuffer;
typedef struct { uint32_t offset,kind; uint64_t value; FFDBBuffer buffer; FFPRHandle handle; } FFDBField;
typedef struct {
    const FFDBBuffer *vertices; size_t vertexCount;
    const FFDBBuffer *constants[2]; size_t constantCount[2];
    const FFDBField *arguments[2]; size_t argumentCount[2];
} FFDBDescription;
typedef id<MTLTexture> (^FFDBTextureLookup)(FFPRHandle handle);
typedef id<MTLSamplerState> (^FFDBSamplerLookup)(FFPRHandle handle);

/* Immutable snapshots of DXMT ABI tables; retain this and pipeline binding
 * until actual GPU completion. A new snapshot is required after each update.
 * Buffer records are additionally held by batch to preserve its budget lifetime.
 * Call on the command stream's serial owner; failures perform no encoding. */
@interface FFDBBindings : NSObject
+ (instancetype)prepareWithDevice:(id<MTLDevice>)device pipeline:(FFSTPipelineBinding *)pipeline
                         buffers:(FFPRRegistry *)registry batch:(FFPRBatch *)batch
                     description:(const FFDBDescription *)description
                   textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers;
- (void)bindToEncoder:(id<MTLRenderCommandEncoder>)encoder;
@end
#endif
