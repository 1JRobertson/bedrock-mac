#import "vertex_resources.h"
#import "frame_native_resources.h"
#include <stdlib.h>
#include <string.h>
#include <math.h>
struct vertex_entry { uint64_t address; uint32_t stride, length; };
_Static_assert(sizeof(struct vertex_entry)==16,"DXMT vertex table ABI");
struct ff_vertex_resources {
    id<MTLBuffer> table, constants[2], arguments[2], index;
    NSUInteger index_offset;
    id<MTLBuffer> buffers[FF_DRAW_RESOURCE_LIMIT];
    uint64_t buffer_offsets[FF_DRAW_RESOURCE_LIMIT];
    id<MTLTexture> textures[FF_TEXTURE_RESOURCE_LIMIT];
    id<MTLSamplerState> samplers[FF_SAMPLER_RESOURCE_LIMIT];
    size_t count, texture_count, sampler_count;
    MTLRenderStages stages;
    id<MTLDevice> device;
    int is_graph;
    ff_vertex_snapshot *source_metadata;
    ff_texture_snapshot *texture_metadata;
    ff_sampler_snapshot *sampler_metadata;
};
void ff_vertex_resources_destroy(ff_vertex_resources *r) {
    if(!r)return;
    [r->table release];
    for(unsigned i=0;i<2;i++){[r->constants[i] release];[r->arguments[i] release];}
    for(size_t i=0;i<r->count;i++)[r->buffers[i] release];
    for(size_t i=0;i<r->texture_count;i++)[r->textures[i] release];
    for(size_t i=0;i<r->sampler_count;i++)[r->samplers[i] release];
    [r->device release];free(r->source_metadata);free(r->texture_metadata);free(r->sampler_metadata);
    free(r);
}
static int resolve(const ff_vertex_snapshot *s,size_t count,const ff_vertex_binding *b,size_t *index) {
    if(!b->id){if(b->generation||b->offset||b->stride||b->length)return 0;*index=SIZE_MAX;return 1;}
    for(size_t i=0;i<count;i++)if(s[i].id==b->id){
        if(s[i].generation!=b->generation||b->offset>s[i].length||b->length>s[i].length-b->offset)return 0;
        *index=i;return 1;
    }
    return 0;
}
static uint64_t address(ff_vertex_resources *r,const ff_vertex_snapshot *s,size_t count,const ff_vertex_binding *b) {
    size_t i;if(!resolve(s,count,b,&i)||i==SIZE_MAX)return 0;
    uint64_t base=r->buffers[i].gpuAddress,offset=r->buffer_offsets[i];
    if(!base||offset>UINT64_MAX-base)return 0;base+=offset;return b->offset<=UINT64_MAX-base?base+b->offset:0;
}
static int texture_planes_valid(const ff_texture_snapshot *v,uint32_t slices){
    size_t offset=0;
    for(size_t p=0;p<v->plane_count;p++){
        ff_texture_plane plane=v->planes[p];
        if(plane.mip>=v->mip_count||plane.slice>=slices||plane.mip!=p%v->mip_count||plane.slice!=p/v->mip_count||
           !plane.row_bytes||(plane.row_bytes&255)||plane.offset!=offset||plane.offset>v->length||plane.length>v->length-plane.offset)return 0;
        size_t w=MAX((size_t)1,v->width>>plane.mip),h=MAX((size_t)1,v->height>>plane.mip);
        if(plane.row_bytes<w*ff_texture_pixel_size(v->format)||plane.row_bytes>SIZE_MAX/h||plane.length!=plane.row_bytes*h)return 0;
        offset+=plane.length;
    }
    return offset==v->length;
}
static int native_texture_valid(id<MTLDevice> device,id<MTLTexture> texture,const ff_texture_snapshot *v){
    if(!texture||texture.device!=device||texture.pixelFormat!=v->format||texture.textureType!=v->texture_type||
       texture.width!=v->width||texture.height!=v->height||texture.depth!=1||texture.mipmapLevelCount!=v->mip_count||
       texture.arrayLength!=v->array_length||texture.sampleCount!=1||!(texture.usage&MTLTextureUsageShaderRead))return 0;
    MTLTextureSwizzleChannels s=texture.swizzle;
    uint32_t expected[4]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
    if(v->has_swizzle)memcpy(expected,v->swizzle,sizeof(expected));
    return s.red==expected[0]&&s.green==expected[1]&&s.blue==expected[2]&&s.alpha==expected[3];
}
static ff_vertex_resources *create_resources(id<MTLDevice> device,const ff_vertex_snapshot *s,size_t count,const ff_draw_bindings *b,
    ff_vertex_resources *shared,int graph_only,const ff_native_texture_override *overrides,size_t override_count,
    const ff_native_buffer_override *native_buffers,size_t native_buffer_count) {
    if(!device||!b||count>FF_DRAW_RESOURCE_LIMIT||(count&&!s)||b->vertex_count>FF_VERTEX_RESOURCE_LIMIT||
       (b->vertex_count&&!b->vertices)||b->texture_count>FF_TEXTURE_RESOURCE_LIMIT||(b->texture_count&&!b->textures)||
       b->sampler_count>FF_SAMPLER_RESOURCE_LIMIT||(b->sampler_count&&!b->samplers)||
       override_count>b->texture_count||(override_count&&(!overrides||shared))||native_buffer_count>count||
       (native_buffer_count&&(!native_buffers||shared)))return NULL;
    for(size_t i=0;i<native_buffer_count;i++){
        const ff_native_buffer_override *v=&native_buffers[i];size_t j;
        for(j=0;j<count;j++)if(s[j].id==v->snapshot_id)break;
        if(!v->snapshot_id||j==count||!v->buffer||v->buffer.device!=device||v->base_offset>v->buffer.length||s[j].length>v->buffer.length-v->base_offset)return NULL;
        for(size_t k=0;k<i;k++)if(native_buffers[k].snapshot_id==v->snapshot_id)return NULL;
    }
    for(size_t i=0;i<override_count;i++){
        if(!overrides[i].snapshot_id||overrides[i].snapshot_id>b->texture_count||!overrides[i].texture)return NULL;
        for(size_t j=0;j<i;j++)if(overrides[i].snapshot_id==overrides[j].snapshot_id)return NULL;
    }
    ff_draw_bindings effective=*b;
    if(shared){
        if(!shared->is_graph||shared->device!=device||count!=shared->count)return NULL;
        s=shared->source_metadata;effective.textures=shared->texture_metadata;effective.texture_count=shared->texture_count;
        effective.samplers=shared->sampler_metadata;effective.sampler_count=shared->sampler_count;
    }
    b=&effective;
    size_t total=0,ignored;
    for(size_t i=0;i<count;i++){
        int overridden=0;for(size_t j=0;j<native_buffer_count;j++)if(native_buffers[j].snapshot_id==s[i].id)overridden=1;
        if(!s[i].id||!s[i].generation||(!shared&&!overridden&&!s[i].bytes)||!s[i].length||s[i].length>FF_VERTEX_BYTES_LIMIT-total)return NULL;
        total+=s[i].length;for(size_t j=0;j<i;j++)if(s[i].id==s[j].id)return NULL;
    }
    for(size_t i=0;i<b->vertex_count;i++)if(!resolve(s,count,&b->vertices[i],&ignored))return NULL;
    if(b->index&&(!b->index->id||!resolve(s,count,b->index,&ignored)))return NULL;
    for(unsigned stage=0;stage<2;stage++){
        if(b->constant_count[stage]>FF_CONSTANT_RESOURCE_LIMIT||(b->constant_count[stage]&&!b->constants[stage])||
           b->argument_count[stage]>FF_SHADER_FIELD_LIMIT||(b->argument_count[stage]&&!b->arguments[stage])||
           b->argument_bytes[stage]>FF_SHADER_TABLE_BYTES_LIMIT||(b->argument_bytes[stage]&7)||b->argument_bytes[stage]!=b->argument_count[stage]*8)return NULL;
        for(size_t i=0;i<b->constant_count[stage];i++)if(!resolve(s,count,&b->constants[stage][i],&ignored))return NULL;
        for(size_t i=0;i<b->argument_count[stage];i++){
            const ff_argument_binding *f=&b->arguments[stage][i];
            if((f->offset&7)||f->offset>b->argument_bytes[stage]||8>b->argument_bytes[stage]-f->offset||
               f->kind<FF_FIELD_BUFFER||f->kind>FF_FIELD_VALUE)return NULL;
            for(size_t j=0;j<i;j++)if(b->arguments[stage][j].offset==f->offset)return NULL;
            if(f->kind==FF_FIELD_BUFFER&&!resolve(s,count,&f->buffer,&ignored))return NULL;
            if(f->kind==FF_FIELD_TEXTURE&&f->value>b->texture_count)return NULL;
            if(f->kind==FF_FIELD_SAMPLER&&f->value>b->sampler_count)return NULL;
        }
    }
    ff_vertex_resources *r=calloc(1,sizeof(*r));if(!r)return NULL;
    r->device=[device retain];r->is_graph=graph_only;
    for(size_t i=0;i<count;i++){
        const ff_native_buffer_override *native=NULL;
        for(size_t j=0;j<native_buffer_count;j++)if(native_buffers[j].snapshot_id==s[i].id)native=&native_buffers[j];
        r->buffers[i]=shared?[shared->buffers[i] retain]:(native?[native->buffer retain]:[device newBufferWithBytes:s[i].bytes length:s[i].length options:MTLResourceStorageModeShared]);
        r->buffer_offsets[i]=shared?shared->buffer_offsets[i]:(native?native->base_offset:0);
        if(!r->buffers[i])goto rejected;++r->count;
    }
    for(size_t i=0;i<b->sampler_count;i++){
        const ff_sampler_snapshot *v=&b->samplers[i];
        if(shared){r->samplers[i]=[shared->samplers[i] retain];++r->sampler_count;continue;}
        if(v->id!=i+1||v->min_filter>1||v->mag_filter>1||v->mip_filter>2||v->compare>7||v->border>2||
           !v->max_anisotropy||v->max_anisotropy>16||v->normalized>1||v->lod_average>1||
           v->address[0]>5||v->address[1]>5||v->address[2]>5||!isfinite(v->lod_min)||!isfinite(v->lod_max)||
           v->lod_min<0||v->lod_max<v->lod_min)goto rejected;
        MTLSamplerDescriptor *d=[[MTLSamplerDescriptor alloc]init];
        d.sAddressMode=v->address[0];d.tAddressMode=v->address[1];d.rAddressMode=v->address[2];
        d.minFilter=v->min_filter;d.magFilter=v->mag_filter;d.mipFilter=v->mip_filter;
        d.compareFunction=v->compare;d.borderColor=v->border;d.maxAnisotropy=v->max_anisotropy;
        d.lodMinClamp=v->lod_min;d.lodMaxClamp=v->lod_max;d.normalizedCoordinates=v->normalized;
        d.lodAverage=v->lod_average;d.supportArgumentBuffers=YES;
        r->samplers[i]=[device newSamplerStateWithDescriptor:d];[d release];
        if(!r->samplers[i])goto rejected;++r->sampler_count;
    }
    total=0;
    for(size_t i=0;i<b->texture_count;i++){
        const ff_texture_snapshot *v=&b->textures[i];
        if(shared){r->textures[i]=[shared->textures[i] retain];++r->texture_count;continue;}
        id<MTLTexture> native=nil;for(size_t j=0;j<override_count;j++)if(overrides[j].snapshot_id==i+1)native=overrides[j].texture;
        uint32_t slices=v->texture_type==MTLTextureTypeCube?6:v->array_length;
        if(v->has_swizzle>1)goto rejected;
        if(v->has_swizzle)for(unsigned channel=0;channel<4;channel++)if(v->swizzle[channel]>MTLTextureSwizzleAlpha)goto rejected;
        if(v->id!=i+1||!ff_texture_pixel_size(v->format)||(!native&&!v->bytes)||!v->length||v->length>FF_TEXTURE_BYTES_LIMIT-total||!v->width||!v->height||
           v->width>4096||v->height>4096||!v->mip_count||v->mip_count>13||v->mip_count>32-(uint32_t)__builtin_clz(MAX(v->width,v->height))||!v->array_length||v->array_length>8||
           v->plane_count!=v->mip_count*slices||v->plane_count>FF_TEXTURE_PLANE_LIMIT||
           (v->texture_type!=MTLTextureType2D&&v->texture_type!=MTLTextureType2DArray&&v->texture_type!=MTLTextureTypeCube)||
           (v->texture_type==MTLTextureTypeCube&&(v->array_length!=1||v->width!=v->height))||
           (v->texture_type==MTLTextureType2D&&v->array_length!=1))goto rejected;
        total+=v->length;
        if(!texture_planes_valid(v,slices))goto rejected;
        if(native){
            if(!native_texture_valid(device,native,v))goto rejected;
            r->textures[i]=[native retain];++r->texture_count;continue;
        }
        MTLTextureDescriptor *d=[[MTLTextureDescriptor alloc]init];
        d.textureType=v->texture_type;d.pixelFormat=v->format;d.width=v->width;d.height=v->height;
        d.mipmapLevelCount=v->mip_count;d.arrayLength=v->array_length;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        r->textures[i]=[device newTextureWithDescriptor:d];[d release];
        if(!r->textures[i])goto rejected;++r->texture_count;
        id<MTLBuffer> upload=[device newBufferWithBytes:v->bytes length:v->length options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];
        id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];int valid=upload&&queue&&cb&&blit;
        for(size_t p=0;valid&&p<v->plane_count;p++){
            ff_texture_plane plane=v->planes[p];
            NSUInteger w=MAX((NSUInteger)1,v->width>>plane.mip),h=MAX((NSUInteger)1,v->height>>plane.mip);
            [blit copyFromBuffer:upload sourceOffset:plane.offset sourceBytesPerRow:plane.row_bytes sourceBytesPerImage:plane.length
                     sourceSize:MTLSizeMake(w,h,1) toTexture:r->textures[i] destinationSlice:plane.slice
               destinationLevel:plane.mip destinationOrigin:MTLOriginMake(0,0,0)];
        }
        [blit endEncoding];if(valid){[cb commit];[cb waitUntilCompleted];valid=cb.status==MTLCommandBufferStatusCompleted;}
        [upload release];[queue release];if(!valid)goto rejected;
        if(v->has_swizzle&&(v->swizzle[0]!=MTLTextureSwizzleRed||v->swizzle[1]!=MTLTextureSwizzleGreen||
           v->swizzle[2]!=MTLTextureSwizzleBlue||v->swizzle[3]!=MTLTextureSwizzleAlpha)){
            MTLTextureSwizzleChannels channels={(MTLTextureSwizzle)v->swizzle[0],(MTLTextureSwizzle)v->swizzle[1],
                (MTLTextureSwizzle)v->swizzle[2],(MTLTextureSwizzle)v->swizzle[3]};
            id<MTLTexture> view=[r->textures[i] newTextureViewWithPixelFormat:v->format textureType:v->texture_type
                levels:NSMakeRange(0,v->mip_count) slices:NSMakeRange(0,slices) swizzle:channels];
            if(!view)goto rejected;[r->textures[i] release];r->textures[i]=view;
        }
    }
    if(b->vertex_count){
        struct vertex_entry entries[FF_VERTEX_RESOURCE_LIMIT]={0};
        for(size_t i=0;i<b->vertex_count;i++){const ff_vertex_binding *v=&b->vertices[i];uint64_t a=address(r,s,count,v);
            if(v->id&&!a)goto rejected;entries[i]=(struct vertex_entry){a,v->stride,v->length};}
        r->table=[device newBufferWithBytes:entries length:b->vertex_count*sizeof(entries[0]) options:MTLResourceStorageModeShared];
        if(!r->table)goto rejected;r->stages|=MTLRenderStageVertex;
    }
    for(unsigned stage=0;stage<2;stage++){
        uint64_t values[FF_CONSTANT_RESOURCE_LIMIT]={0};
        for(size_t i=0;i<b->constant_count[stage];i++){
            values[i]=address(r,s,count,&b->constants[stage][i]);if(b->constants[stage][i].id&&!values[i])goto rejected;}
        if(b->constant_count[stage]){
            r->constants[stage]=[device newBufferWithBytes:values length:b->constant_count[stage]*8 options:MTLResourceStorageModeShared];
            if(!r->constants[stage])goto rejected;}
        uint64_t arguments[FF_SHADER_TABLE_BYTES_LIMIT/8]={0};
        for(size_t i=0;i<b->argument_count[stage];i++){
            const ff_argument_binding *f=&b->arguments[stage][i];uint64_t value=f->value;
            if(f->kind==FF_FIELD_BUFFER){value=address(r,s,count,&f->buffer);if(f->buffer.id&&!value)goto rejected;}
            else if(f->kind==FF_FIELD_TEXTURE&&value){value=r->textures[value-1].gpuResourceID._impl;if(!value)goto rejected;}
            else if(f->kind==FF_FIELD_SAMPLER&&value){value=r->samplers[value-1].gpuResourceID._impl;if(!value)goto rejected;}
            arguments[f->offset/8]=value;
        }
        if(b->argument_bytes[stage]){
            r->arguments[stage]=[device newBufferWithBytes:arguments length:b->argument_bytes[stage] options:MTLResourceStorageModeShared];
            if(!r->arguments[stage])goto rejected;}
        if(b->constant_count[stage]||b->argument_bytes[stage])r->stages|=stage?MTLRenderStageFragment:MTLRenderStageVertex;
    }
    if(b->index){size_t i;if(!resolve(s,count,b->index,&i)||i==SIZE_MAX)goto rejected;r->index=r->buffers[i];r->index_offset=r->buffer_offsets[i]+b->index->offset;r->stages|=MTLRenderStageVertex;}
    if(graph_only){
        if(count){
            r->source_metadata=calloc(count,sizeof(*r->source_metadata));if(!r->source_metadata)goto rejected;
            for(size_t i=0;i<count;i++){r->source_metadata[i]=s[i];r->source_metadata[i].bytes=NULL;}
        }
        if(b->texture_count){
            r->texture_metadata=calloc(b->texture_count,sizeof(*r->texture_metadata));if(!r->texture_metadata)goto rejected;
            for(size_t i=0;i<b->texture_count;i++){r->texture_metadata[i]=b->textures[i];r->texture_metadata[i].bytes=NULL;}
        }
        if(b->sampler_count){
            r->sampler_metadata=calloc(b->sampler_count,sizeof(*r->sampler_metadata));if(!r->sampler_metadata)goto rejected;
            memcpy(r->sampler_metadata,b->samplers,b->sampler_count*sizeof(*r->sampler_metadata));
        }
    }
    if(!shared&&!graph_only&&(r->count||r->texture_count)&&!r->stages)goto rejected;
    return r;
rejected:ff_vertex_resources_destroy(r);return NULL;
}
ff_vertex_resources *ff_vertex_resources_create_draw(id<MTLDevice> d,const ff_vertex_snapshot *s,size_t n,const ff_draw_bindings *b){
    return create_resources(d,s,n,b,NULL,0,NULL,0,NULL,0);
}
ff_vertex_resources *ff_vertex_resources_create_graph(id<MTLDevice> device,const ff_vertex_snapshot *snapshots,size_t count,
    const ff_texture_snapshot *textures,size_t texture_count,const ff_sampler_snapshot *samplers,size_t sampler_count){
    ff_draw_bindings b={.textures=textures,.texture_count=texture_count,.samplers=samplers,.sampler_count=sampler_count};
    return create_resources(device,snapshots,count,&b,NULL,1,NULL,0,NULL,0);
}
ff_vertex_resources *ff_vertex_resources_create_graph_native(id<MTLDevice> device,const ff_vertex_snapshot *snapshots,size_t count,
    const ff_texture_snapshot *textures,size_t texture_count,const ff_sampler_snapshot *samplers,size_t sampler_count,
    const ff_native_texture_override *overrides,size_t override_count){
    ff_draw_bindings b={.textures=textures,.texture_count=texture_count,.samplers=samplers,.sampler_count=sampler_count};
    return create_resources(device,snapshots,count,&b,NULL,1,overrides,override_count,NULL,0);
}
ff_vertex_resources *ff_vertex_resources_create_graph_native_assets(id<MTLDevice> device,const ff_vertex_snapshot *snapshots,size_t count,
    const ff_texture_snapshot *textures,size_t texture_count,const ff_sampler_snapshot *samplers,size_t sampler_count,
    const ff_native_buffer_override *buffers,size_t buffer_count,const ff_native_texture_override *native_textures,size_t native_texture_count){
    ff_draw_bindings b={.textures=textures,.texture_count=texture_count,.samplers=samplers,.sampler_count=sampler_count};
    return create_resources(device,snapshots,count,&b,NULL,1,native_textures,native_texture_count,buffers,buffer_count);
}
ff_vertex_resources *ff_vertex_resources_create_draw_shared(ff_vertex_resources *graph,const ff_draw_bindings *b){
    if(!graph||!graph->is_graph)return NULL;
    return create_resources(graph->device,graph->source_metadata,graph->count,b,graph,0,NULL,0,NULL,0);
}
ff_vertex_resources *ff_vertex_resources_create(id<MTLDevice> d,const ff_vertex_snapshot *s,size_t n,const ff_vertex_binding *v,size_t count){
    if(!n||!count)return NULL;ff_draw_bindings b={.vertices=v,.vertex_count=count};return ff_vertex_resources_create_draw(d,s,n,&b);
}
id<MTLBuffer> ff_vertex_resources_index(ff_vertex_resources *r,NSUInteger *offset){if(!r||!offset)return nil;*offset=r->index_offset;return r->index;}
void ff_vertex_resources_bind(ff_vertex_resources *r,id<MTLRenderCommandEncoder> encoder){
    if(!r||!encoder||!r->stages)return;
    for(size_t i=0;i<r->count;i++)[encoder useResource:r->buffers[i] usage:MTLResourceUsageRead stages:r->stages];
    for(size_t i=0;i<r->texture_count;i++)[encoder useResource:r->textures[i] usage:MTLResourceUsageRead stages:r->stages];
    if(r->table)[encoder setVertexBuffer:r->table offset:0 atIndex:16];
    for(unsigned stage=0;stage<2;stage++){
        if(stage){if(r->constants[stage])[encoder setFragmentBuffer:r->constants[stage] offset:0 atIndex:29];
            if(r->arguments[stage])[encoder setFragmentBuffer:r->arguments[stage] offset:0 atIndex:30];}
        else{if(r->constants[stage])[encoder setVertexBuffer:r->constants[stage] offset:0 atIndex:29];
            if(r->arguments[stage])[encoder setVertexBuffer:r->arguments[stage] offset:0 atIndex:30];}
    }
}

/* Native pass batching. Existing graph constructors are the sole authority for
 * immutable asset metadata/ownership; do not revalidate/copy/retain that graph
 * for every draw. Draw-specific checks remain independent of that trust. */
enum { PASS_VERTEX, PASS_VERTEX_CONSTANTS, PASS_FRAGMENT_CONSTANTS,
       PASS_VERTEX_ARGUMENTS, PASS_FRAGMENT_ARGUMENTS, PASS_TABLES, PASS_ALIGN=256 };
#define PASS_DRAW_BYTES (512u+2u*256u+2u*1024u)
struct pass_draw {
    NSUInteger offset[PASS_TABLES],length[PASS_TABLES],index_offset;
    id<MTLBuffer> index; /* owned by the transferred graph */
    MTLRenderStages stages;
};
struct ff_vertex_pass_resources {
    ff_vertex_resources *graph;
    id<MTLBuffer> arena;
    uint64_t allocated_bytes;
    size_t count,resident_count;
    MTLRenderStages stages;
    id<MTLResource> residents[FF_DRAW_RESOURCE_LIMIT+FF_TEXTURE_RESOURCE_LIMIT];
    struct pass_draw draws[];
};
struct pass_id {uint64_t id;size_t index;};
struct pass_lookup {
    const ff_vertex_resources *graph;
    struct pass_id ids[FF_DRAW_RESOURCE_LIMIT];
    uint64_t addresses[FF_DRAW_RESOURCE_LIMIT];
    int dense;
};
static int pass_id_compare(const void *a,const void *b) {
    uint64_t x=((const struct pass_id *)a)->id,y=((const struct pass_id *)b)->id;return x<y?-1:x>y;
}
static int pass_resource_compare(const void *a,const void *b) {
    uintptr_t x=(uintptr_t)*(const void *const *)a,y=(uintptr_t)*(const void *const *)b;return x<y?-1:x>y;
}
static int pass_resolve(const struct pass_lookup *lookup,const ff_vertex_binding *binding,size_t *index) {
    if(!binding->id){if(binding->generation||binding->offset||binding->stride||binding->length)return 0;*index=SIZE_MAX;return 1;}
    const ff_vertex_resources *graph=lookup->graph;size_t i=SIZE_MAX;
    if(lookup->dense){if(binding->id<=graph->count)i=(size_t)binding->id-1;}
    else{size_t low=0,high=graph->count;while(low<high){size_t middle=low+(high-low)/2;
            if(lookup->ids[middle].id<binding->id)low=middle+1;else high=middle;}
        if(low<graph->count&&lookup->ids[low].id==binding->id)i=lookup->ids[low].index;}
    if(i==SIZE_MAX)return 0;const ff_vertex_snapshot *snapshot=&graph->source_metadata[i];
    if(binding->generation!=snapshot->generation||binding->offset>snapshot->length||binding->length>snapshot->length-binding->offset)return 0;
    *index=i;return 1;
}
static int pass_address(const struct pass_lookup *lookup,const ff_vertex_binding *binding,uint64_t *value) {
    size_t i;if(!pass_resolve(lookup,binding,&i))return 0;
    if(i==SIZE_MAX){*value=0;return 1;}uint64_t base=lookup->addresses[i];
    if(!base||binding->offset>UINT64_MAX-base)return 0;*value=base+binding->offset;return 1;
}
static void *pass_slice(uint8_t *bytes,size_t capacity,size_t *cursor,struct pass_draw *draw,unsigned table,size_t length) {
    if(!length)return NULL;
    if(length>SIZE_MAX-(PASS_ALIGN-1))return NULL;size_t aligned=(length+PASS_ALIGN-1)&~(size_t)(PASS_ALIGN-1);
    if(*cursor>capacity||aligned>capacity-*cursor)return NULL;
    draw->offset[table]=*cursor;draw->length[table]=length;void *result=bytes+*cursor;*cursor+=aligned;return result;
}
ff_vertex_pass_resources *ff_vertex_pass_resources_create(ff_vertex_resources *graph,const ff_draw_bindings *bindings,size_t count,uint64_t max_bytes) {
    if(!graph||!graph->is_graph||!graph->device||count>FF_NATIVE_PASS_DRAW_LIMIT||(count&&!bindings))return NULL;
    ff_vertex_pass_resources *pass=calloc(1,sizeof(*pass)+count*sizeof(struct pass_draw));if(!pass)return NULL;
    size_t capacity=(size_t)MIN(max_bytes,(uint64_t)count*PASS_DRAW_BYTES),cursor=0;
    uint8_t *bytes=capacity?calloc(1,capacity):NULL;if(capacity&&!bytes){free(pass);return NULL;}
    struct pass_lookup lookup={.graph=graph,.dense=1};
    for(size_t i=0;i<graph->count;++i){lookup.ids[i]=(struct pass_id){graph->source_metadata[i].id,i};
        if(lookup.ids[i].id!=i+1)lookup.dense=0;
        uint64_t address=graph->buffers[i].gpuAddress,offset=graph->buffer_offsets[i];
        lookup.addresses[i]=address&&offset<=UINT64_MAX-address?address+offset:0;}
    if(!lookup.dense)qsort(lookup.ids,graph->count,sizeof(lookup.ids[0]),pass_id_compare);
    for(size_t d=0;d<count;++d){const ff_draw_bindings *b=&bindings[d];struct pass_draw *draw=&pass->draws[d];
        /* Initial pointer/count checks match the legacy shared constructor,
         * even though graph-owned textures/samplers replace those inputs. */
        if(b->vertex_count>FF_VERTEX_RESOURCE_LIMIT||(b->vertex_count&&!b->vertices)||
           b->texture_count>FF_TEXTURE_RESOURCE_LIMIT||(b->texture_count&&!b->textures)||
           b->sampler_count>FF_SAMPLER_RESOURCE_LIMIT||(b->sampler_count&&!b->samplers))goto rejected;
        if(b->vertex_count){struct vertex_entry *entries=pass_slice(bytes,capacity,&cursor,draw,PASS_VERTEX,b->vertex_count*sizeof(*entries));
            if(!entries)goto rejected;
            for(size_t i=0;i<b->vertex_count;++i){uint64_t address;if(!pass_address(&lookup,&b->vertices[i],&address))goto rejected;
                entries[i]=(struct vertex_entry){address,b->vertices[i].stride,b->vertices[i].length};}
            draw->stages|=MTLRenderStageVertex;}
        for(unsigned stage=0;stage<2;++stage){
            if(b->constant_count[stage]>FF_CONSTANT_RESOURCE_LIMIT||(b->constant_count[stage]&&!b->constants[stage])||
               b->argument_count[stage]>FF_SHADER_FIELD_LIMIT||(b->argument_count[stage]&&!b->arguments[stage])||
               b->argument_bytes[stage]>FF_SHADER_TABLE_BYTES_LIMIT||(b->argument_bytes[stage]&7)||
               b->argument_bytes[stage]!=b->argument_count[stage]*8)goto rejected;
            if(b->constant_count[stage]){uint64_t *values=pass_slice(bytes,capacity,&cursor,draw,
                    stage?PASS_FRAGMENT_CONSTANTS:PASS_VERTEX_CONSTANTS,b->constant_count[stage]*8);
                if(!values)goto rejected;
                for(size_t i=0;i<b->constant_count[stage];++i)if(!pass_address(&lookup,&b->constants[stage][i],&values[i]))goto rejected;}
            if(b->argument_bytes[stage]){uint64_t *values=pass_slice(bytes,capacity,&cursor,draw,
                    stage?PASS_FRAGMENT_ARGUMENTS:PASS_VERTEX_ARGUMENTS,b->argument_bytes[stage]);
                if(!values)goto rejected;uint8_t occupied[FF_SHADER_FIELD_LIMIT]={0};
                for(size_t i=0;i<b->argument_count[stage];++i){const ff_argument_binding *field=&b->arguments[stage][i];
                    if((field->offset&7)||field->offset>b->argument_bytes[stage]||8>b->argument_bytes[stage]-field->offset||
                       field->kind<FF_FIELD_BUFFER||field->kind>FF_FIELD_VALUE||occupied[field->offset/8])goto rejected;
                    occupied[field->offset/8]=1;uint64_t value=field->value;
                    if(field->kind==FF_FIELD_BUFFER){if(!pass_address(&lookup,&field->buffer,&value))goto rejected;}
                    else if(field->kind==FF_FIELD_TEXTURE&&value){if(value>graph->texture_count)goto rejected;
                        value=graph->textures[value-1].gpuResourceID._impl;if(!value)goto rejected;}
                    else if(field->kind==FF_FIELD_SAMPLER&&value){if(value>graph->sampler_count)goto rejected;
                        value=graph->samplers[value-1].gpuResourceID._impl;if(!value)goto rejected;}
                    values[field->offset/8]=value;
                }}
            if(b->constant_count[stage]||b->argument_bytes[stage])draw->stages|=stage?MTLRenderStageFragment:MTLRenderStageVertex;
        }
        if(b->index){size_t i;if(!b->index->id||!pass_resolve(&lookup,b->index,&i)||i==SIZE_MAX||
                b->index->offset>NSUIntegerMax-graph->buffer_offsets[i])goto rejected;
            draw->index=graph->buffers[i];draw->index_offset=graph->buffer_offsets[i]+b->index->offset;draw->stages|=MTLRenderStageVertex;}
        pass->stages|=draw->stages;
    }
    if(cursor){pass->arena=[graph->device newBufferWithBytes:bytes length:cursor options:MTLResourceStorageModeShared];
        if(!pass->arena)goto rejected;pass->allocated_bytes=pass->arena.allocatedSize;
        if(pass->allocated_bytes<cursor||pass->allocated_bytes>max_bytes)goto rejected;}
    free(bytes);bytes=NULL;
    for(size_t i=0;i<graph->count;++i)pass->residents[pass->resident_count++]=graph->buffers[i];
    for(size_t i=0;i<graph->texture_count;++i)pass->residents[pass->resident_count++]=graph->textures[i];
    qsort(pass->residents,pass->resident_count,sizeof(pass->residents[0]),pass_resource_compare);
    size_t unique=0;for(size_t i=0;i<pass->resident_count;++i)
        if(!unique||pass->residents[i]!=pass->residents[unique-1])pass->residents[unique++]=pass->residents[i];
    pass->resident_count=unique;pass->count=count;pass->graph=graph;return pass;
rejected:free(bytes);ff_vertex_pass_resources_destroy(pass);return NULL;
}
uint64_t ff_vertex_pass_resources_allocated_bytes(const ff_vertex_pass_resources *pass){return pass?pass->allocated_bytes:0;}
void ff_vertex_pass_resources_declare(ff_vertex_pass_resources *pass,id<MTLRenderCommandEncoder> encoder){
    if(pass&&encoder&&pass->stages&&pass->resident_count)
        [encoder useResources:pass->residents count:pass->resident_count usage:MTLResourceUsageRead stages:pass->stages];
}
void ff_vertex_pass_resources_bind(ff_vertex_pass_resources *pass,size_t draw,id<MTLRenderCommandEncoder> encoder){
    if(!pass||draw>=pass->count||!encoder)return;const struct pass_draw *d=&pass->draws[draw];
    if(d->length[PASS_VERTEX])[encoder setVertexBuffer:pass->arena offset:d->offset[PASS_VERTEX] atIndex:16];
    for(unsigned stage=0;stage<2;++stage){unsigned constant=stage?PASS_FRAGMENT_CONSTANTS:PASS_VERTEX_CONSTANTS,
            argument=stage?PASS_FRAGMENT_ARGUMENTS:PASS_VERTEX_ARGUMENTS;
        if(stage){if(d->length[constant])[encoder setFragmentBuffer:pass->arena offset:d->offset[constant] atIndex:29];
            if(d->length[argument])[encoder setFragmentBuffer:pass->arena offset:d->offset[argument] atIndex:30];}
        else{if(d->length[constant])[encoder setVertexBuffer:pass->arena offset:d->offset[constant] atIndex:29];
            if(d->length[argument])[encoder setVertexBuffer:pass->arena offset:d->offset[argument] atIndex:30];}}
}
id<MTLBuffer> ff_vertex_pass_resources_index(ff_vertex_pass_resources *pass,size_t draw,NSUInteger *offset){
    if(!pass||draw>=pass->count||!offset)return nil;*offset=pass->draws[draw].index_offset;return pass->draws[draw].index;
}
void ff_vertex_pass_resources_destroy(ff_vertex_pass_resources *pass){
    if(!pass)return;[pass->arena release];ff_vertex_resources_destroy(pass->graph);free(pass);
}
