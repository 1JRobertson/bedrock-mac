#import "native_direct_bindings.h"
#include <string.h>

#if !__has_feature(objc_arc)
#error native_direct_bindings.m requires ARC
#endif

typedef struct { uint64_t address; uint32_t stride,length; } FFDBVertex;
_Static_assert(sizeof(FFDBVertex)==16,"DXMT vertex table ABI");

@implementation FFDBBindings {
    id<MTLBuffer> _vertex,_constants[2],_arguments[2];
    NSArray<id<MTLResource>> *_resources;
    NSArray *_held;
    MTLRenderStages _stages;
}
static BOOL handleNull(FFPRHandle h) { return !h.object&&!h.generation; }
static BOOL bufferAddress(FFDBBuffer b, FFPRRegistry *registry, FFPRBatch *batch,
                          NSMutableArray *held, uint64_t *out) {
    *out=0;
    if(handleNull(b.handle))return !b.offset&&!b.stride&&!b.length;
    if(!b.handle.object||!b.handle.generation)return NO;
    id<MTLBuffer> buffer=[registry buffer:b.handle batch:batch];
    if(!buffer||b.offset>=buffer.length||b.length>buffer.length-b.offset||
       !buffer.gpuAddress||b.offset>UINT64_MAX-buffer.gpuAddress)return NO;
    [held addObject:buffer];*out=buffer.gpuAddress+b.offset;return YES;
}
+ (instancetype)prepareWithDevice:(id<MTLDevice>)device pipeline:(FFSTPipelineBinding *)pipeline
                         buffers:(FFPRRegistry *)registry batch:(FFPRBatch *)batch
                     description:(const FFDBDescription *)d
                   textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers {
    if(!device||!pipeline||pipeline.pipeline.device!=device||!registry||!batch||!d)return nil;
    ff_draw_layout layout=pipeline.layout;
    if(d->vertexCount!=(size_t)__builtin_popcount(layout.ia_slot_mask)||
       d->vertexCount>FF_VERTEX_RESOURCE_LIMIT||(d->vertexCount&&!d->vertices))return nil;
    for(unsigned s=0;s<2;s++)if(d->constantCount[s]!=layout.constant_count[s]||
       d->constantCount[s]>FF_CONSTANT_RESOURCE_LIMIT||(d->constantCount[s]&&!d->constants[s])||
       d->argumentCount[s]!=layout.arguments[s].field_count||d->argumentCount[s]>FF_SHADER_FIELD_LIMIT||
       (d->argumentCount[s]&&!d->arguments[s]))return nil;
    FFDBBindings *result=[FFDBBindings new];NSMutableArray *resources=[NSMutableArray array],*held=[NSMutableArray arrayWithObject:pipeline];
    FFDBVertex vertices[FF_VERTEX_RESOURCE_LIMIT]={0};
    for(size_t i=0;i<d->vertexCount;i++){
        uint64_t address;if(!bufferAddress(d->vertices[i],registry,batch,resources,&address))return nil;
        vertices[i]=(FFDBVertex){address,d->vertices[i].stride,d->vertices[i].length};
    }
    if(d->vertexCount){result->_vertex=[device newBufferWithBytes:vertices length:d->vertexCount*sizeof(vertices[0]) options:MTLResourceStorageModeShared];if(!result->_vertex)return nil;result->_stages|=MTLRenderStageVertex;}
    for(unsigned s=0;s<2;s++){
        uint64_t values[FF_CONSTANT_RESOURCE_LIMIT]={0},args[FF_SHADER_TABLE_BYTES_LIMIT/8]={0};
        for(size_t i=0;i<d->constantCount[s];i++)if(!bufferAddress(d->constants[s][i],registry,batch,resources,&values[i]))return nil;
        ff_shader_table_layout table=layout.arguments[s];
        if(table.byte_length>FF_SHADER_TABLE_BYTES_LIMIT||table.byte_length!=table.field_count*8)return nil;
        for(size_t i=0;i<d->argumentCount[s];i++){
            FFDBField f=d->arguments[s][i];BOOL found=NO;
            for(unsigned j=0;j<table.field_count;j++)if(table.fields[j].offset==f.offset&&table.fields[j].kind==f.kind)found=YES;
            if(!found||(f.offset&7)||f.offset>=table.byte_length)return nil;
            for(size_t j=0;j<i;j++)if(d->arguments[s][j].offset==f.offset)return nil;
            uint64_t v=0;
            if(f.kind==FF_FIELD_BUFFER){if(!bufferAddress(f.buffer,registry,batch,resources,&v)||!handleNull(f.handle)||f.value)return nil;}
            else if(f.kind==FF_FIELD_VALUE){if(!handleNull(f.handle)||!handleNull(f.buffer.handle)||f.buffer.offset||f.buffer.stride||f.buffer.length)return nil;v=f.value;}
            else if(f.kind==FF_FIELD_TEXTURE||f.kind==FF_FIELD_SAMPLER){
                if(!handleNull(f.buffer.handle)||f.buffer.offset||f.buffer.stride||f.buffer.length||f.value)return nil;
                MTLTextureReferenceType *ref=f.kind==FF_FIELD_TEXTURE?[pipeline textureReferenceForStage:s offset:f.offset]:nil;
                if(f.kind==FF_FIELD_TEXTURE&&(!ref||ref.textureType!=MTLTextureType2D||ref.isDepthTexture||ref.access!=MTLBindingAccessReadOnly||
                   (ref.textureDataType!=MTLDataTypeFloat&&ref.textureDataType!=MTLDataTypeHalf)))return nil;
                if(!handleNull(f.handle)){
                    if(!f.handle.object||!f.handle.generation)return nil;
                    if(f.kind==FF_FIELD_TEXTURE){id<MTLTexture> t=textures?textures(f.handle):nil;
                        if(!t||t.device!=device||t.textureType!=ref.textureType||t.depth!=1||t.arrayLength!=1||t.sampleCount!=1||
                           !(t.usage&MTLTextureUsageShaderRead))return nil;
                        switch(t.pixelFormat){case MTLPixelFormatA8Unorm:case MTLPixelFormatR8Unorm:case MTLPixelFormatR8Snorm:
                        case MTLPixelFormatRG8Unorm:case MTLPixelFormatRG8Snorm:case MTLPixelFormatR16Float:
                        case MTLPixelFormatRGBA8Unorm:case MTLPixelFormatRGBA8Unorm_sRGB:case MTLPixelFormatBGRA8Unorm:
                        case MTLPixelFormatBGRA8Unorm_sRGB:case MTLPixelFormatR32Float:case MTLPixelFormatRG16Float:
                        case MTLPixelFormatRGBA16Float:case MTLPixelFormatRG32Float:case MTLPixelFormatRGBA32Float:break;
                        default:return nil;}
                        v=t.gpuResourceID._impl;if(!v)return nil;[resources addObject:t];}
                    else {id<MTLSamplerState> sampler=samplers?samplers(f.handle):nil;
                        if(!sampler||sampler.device!=device)return nil;v=sampler.gpuResourceID._impl;if(!v)return nil;[held addObject:sampler];}
                }
            } else return nil;
            args[f.offset/8]=v;
        }
        if(d->constantCount[s]){result->_constants[s]=[device newBufferWithBytes:values length:d->constantCount[s]*8 options:MTLResourceStorageModeShared];if(!result->_constants[s])return nil;}
        if(table.byte_length){result->_arguments[s]=[device newBufferWithBytes:args length:table.byte_length options:MTLResourceStorageModeShared];if(!result->_arguments[s])return nil;}
        if(d->constantCount[s]||table.byte_length)result->_stages|=s?MTLRenderStageFragment:MTLRenderStageVertex;
    }
    result->_resources=[resources copy];result->_held=[held copy];return result;
}
- (void)bindToEncoder:(id<MTLRenderCommandEncoder>)encoder {
    for(id<MTLResource> resource in _resources)[encoder useResource:resource usage:MTLResourceUsageRead stages:_stages];
    if(_vertex)[encoder setVertexBuffer:_vertex offset:0 atIndex:16];
    for(unsigned s=0;s<2;s++){
        if(s){if(_constants[s])[encoder setFragmentBuffer:_constants[s] offset:0 atIndex:29];if(_arguments[s])[encoder setFragmentBuffer:_arguments[s] offset:0 atIndex:30];}
        else{if(_constants[s])[encoder setVertexBuffer:_constants[s] offset:0 atIndex:29];if(_arguments[s])[encoder setVertexBuffer:_arguments[s] offset:0 atIndex:30];}
    }
}
@end
