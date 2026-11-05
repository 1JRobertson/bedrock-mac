#import "native_value_validation.h"
#import "native_metadata_sidecar.h"
#import "native_boundary_pass.h"
/* Native frame encoding shares the qualified pass schema and shader ABI.
 * Separate source keeps the current single-pass QA candidate immutable. ARC. */
#import "native_frame_execute.h"
#import "native_session_execute.h"
#import "native_session_cache.h"
#import "native_draw_state.h"
#import "shared_texture_pass_resources.h"
#import "frame_native_resources.h"
#import "native_frame_operations.h"
#import "native_owned_blobs.h"
#import "native_buffer_ref_helpers.h"
#include "native_metadata_wire.h"
#import "native_content_identity.h"
#import "shader_bindings.h"
#import "shared_texture.h"
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <stdatomic.h>
#include <time.h>
#include <unistd.h>
#if !__has_feature(objc_arc)
#error native_frame_execute.m requires ARC
#endif
@interface FFSTFrameRenderPipeline : NSObject
@property(nonatomic,strong) id<MTLRenderPipelineState> state;
@property(nonatomic) ff_draw_layout layout;
@property(nonatomic,strong) NSArray *liveFetch;
@end
@implementation FFSTFrameRenderPipeline @end
@interface FFSTFrameRenderDraw : NSObject
@property(nonatomic,strong) FFSTFrameRenderPipeline *pipeline;
@property(nonatomic,strong) id<MTLDepthStencilState> depth;
@property(nonatomic) FFSTPassDrawInfo info;
@property(nonatomic) MTLViewport viewport;
@property(nonatomic) MTLScissorRect scissor;
@property(nonatomic) FFSTDrawState state;
@property(nonatomic) uint32_t stencil;
@property(nonatomic) BOOL material,geometry;
@end
@implementation FFSTFrameRenderDraw @end
#include "direct_pass_decode.inc"
@interface FFSTFrameRenderContext : NSObject
@property(nonatomic) FFSTPassResources decoded;
@property(nonatomic,strong) FFDPDecoded *direct;
@property(nonatomic,strong) FFDPTableArena *directTables;
@property(nonatomic) ff_vertex_resources *graph;
@property(nonatomic) ff_vertex_pass_resources *passTables;
@end
@implementation FFSTFrameRenderContext
- (void)dealloc {
    ff_vertex_pass_resources_destroy(_passTables);
    ff_vertex_resources_destroy(_graph);ffst_pass_resources_destroy(_decoded);
}
@end
static BOOL pass_u64(id object,uint64_t maximum,uint64_t *out) {return ffst_value_u64(object,maximum,out);}
static BOOL pass_bool(id object,BOOL *out) {
    if(![object isKindOfClass:[NSNumber class]])return NO;
    if(CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID()){*out=[object boolValue];return YES;}
    uint64_t value;if(!pass_u64(object,1,&value))return NO;*out=(BOOL)value;return YES;
}
static BOOL pass_numbers(id array,NSUInteger count) {
    if(![array isKindOfClass:[NSArray class]]||[array count]!=count)return NO;
    for(id value in array)if(![value isKindOfClass:[NSNumber class]]||!isfinite([value doubleValue]))return NO;return YES;
}
static BOOL pass_record(id object){return [object isKindOfClass:[NSDictionary class]];}
static NSData *pass_read(int directory,const char *name,size_t maximum) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK);if(fd<0)return nil;struct stat before,after;
    if(fstat(fd,&before)||!S_ISREG(before.st_mode)||before.st_uid!=getuid()||before.st_nlink!=1||(before.st_mode&077)||
       before.st_size<=0||(uint64_t)before.st_size>maximum){close(fd);return nil;}
    NSMutableData *data=[NSMutableData dataWithLength:(NSUInteger)before.st_size];size_t left=data.length;uint8_t *p=data.mutableBytes;
    while(left){ssize_t n=read(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0){close(fd);return nil;}p+=n;left-=(size_t)n;}
    BOOL stable=!fstat(fd,&after)&&before.st_dev==after.st_dev&&before.st_ino==after.st_ino&&before.st_size==after.st_size&&
        before.st_mode==after.st_mode&&before.st_uid==after.st_uid&&before.st_nlink==after.st_nlink&&
        before.st_mtimespec.tv_sec==after.st_mtimespec.tv_sec&&before.st_mtimespec.tv_nsec==after.st_mtimespec.tv_nsec&&
        before.st_ctimespec.tv_sec==after.st_ctimespec.tv_sec&&before.st_ctimespec.tv_nsec==after.st_ctimespec.tv_nsec;
    close(fd);return stable?data:nil;
}
static NSData *pass_payload_read(int directory,NSDictionary *blobs,const char *name,size_t maximum) {
    if(!blobs)return pass_read(directory,name,maximum);
    id bytes=blobs[@(name)];return [bytes isKindOfClass:[NSData class]]&&[bytes length]&&[bytes length]<=maximum?bytes:nil;
}
static NSData *pass_cache_key(id object) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingSortedKeys error:nil];if(!data)return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    return [NSData dataWithBytes:digest length:sizeof(digest)];
}
static NSString *pass_hash_name(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];char text[65];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    for(unsigned i=0;i<32;++i)snprintf(text+2*i,3,"%02x",hash[i]);return [NSString stringWithFormat:@"pass-lib-%s.metallib",text];
}
static id<MTLLibrary> pass_library(id<MTLDevice> device,int directory,NSDictionary *blobs,id file,FFSTPassLibraryResolver resolver,
    NSMutableDictionary<NSString *,id<MTLLibrary>> *cache,FFSTNativeSessionCache *persistent,uint64_t *bytes) {
    if(![file isKindOfClass:[NSString class]]||![file length]||[file length]>128)return nil;
    id<MTLLibrary> library=persistent?[persistent objectForKey:file]:cache[file];if(library)return library;
    uint64_t cost=1;
    if(resolver)library=resolver(file);
    else {
        if([file length]!=82||![file hasPrefix:@"pass-lib-"]||![file hasSuffix:@".metallib"])return nil;
        NSData *blob=pass_payload_read(directory,blobs,[file fileSystemRepresentation],8u*1024u*1024u);
        if(!blob||![pass_hash_name(blob) isEqual:file]||(!persistent&&blob.length>64u*1024u*1024u-*bytes))return nil;
        dispatch_data_t data=dispatch_data_create(blob.bytes,blob.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error=nil;library=[device newLibraryWithData:data error:&error];if(error)return nil;cost=blob.length;
    }
    if(!library||library.device.registryID!=device.registryID)return nil;
    if(persistent){if(![persistent setObject:library forKey:file cost:cost])return nil;*bytes=[persistent.stats[@"cost"] unsignedLongLongValue];}
    else{cache[file]=library;*bytes+=cost;}return library;
}
static BOOL pass_layout_matches(NSDictionary *record,const ff_draw_layout *layout) {
    uint64_t mask,value;if(!pass_u64(record[@"ia_slot_mask"],UINT32_MAX,&mask)||mask!=layout->ia_slot_mask||
       !pass_numbers(record[@"constant_count"],2)||!pass_numbers(record[@"argument_bytes"],2)||
       ![record[@"argument_layout"] isKindOfClass:[NSArray class]]||[record[@"argument_layout"] count]!=2)return NO;
    for(unsigned stage=0;stage<2;++stage){
        if(!pass_u64(record[@"constant_count"][stage],FF_CONSTANT_RESOURCE_LIMIT,&value)||value!=layout->constant_count[stage]||
           !pass_u64(record[@"argument_bytes"][stage],FF_SHADER_TABLE_BYTES_LIMIT,&value)||value!=layout->arguments[stage].byte_length)return NO;
        NSArray *fields=record[@"argument_layout"][stage];if(![fields isKindOfClass:[NSArray class]]||fields.count!=layout->arguments[stage].field_count)return NO;
        NSMutableIndexSet *seen=[NSMutableIndexSet indexSet];
        for(id field in fields){uint64_t offset,kind;if(!pass_record(field)||!pass_u64(field[@"offset"],FF_SHADER_TABLE_BYTES_LIMIT,&offset)||
            !pass_u64(field[@"kind"],FF_FIELD_VALUE,&kind)||!kind||[seen containsIndex:(NSUInteger)offset])return NO;
            BOOL found=NO;for(unsigned i=0;i<layout->arguments[stage].field_count;++i)
                if(layout->arguments[stage].fields[i].offset==offset&&layout->arguments[stage].fields[i].kind==kind)found=YES;
            if(!found)return NO;[seen addIndex:(NSUInteger)offset];}
    }return YES;
}
static FFSTFrameRenderPipeline *pass_pipeline(id<MTLDevice> device,int directory,NSDictionary *blobs,NSDictionary *record,NSDictionary *attachments,NSUInteger identifier,
    FFSTPassLibraryResolver resolver,NSMutableDictionary *libraries,FFSTNativeSessionCache *libraryCache,FFSTNativeSessionCache *pipelineCache,uint64_t *bytes) {
    uint64_t value,mask;NSDictionary *state=record[@"state"];
    if(!pass_record(record)||!pass_record(state)||!pass_u64(record[@"id"],FFST_PASS_DRAW_LIMIT,&value)||value!=identifier||
       !pass_u64(record[@"topology"],MTLPrimitiveTopologyClassTriangle,&value)||!pass_u64(record[@"ia_slot_mask"],UINT32_MAX,&mask))return nil;
    NSUInteger topology=(NSUInteger)value;
    for(NSString *key in @[@"samples",@"depth_format",@"stencil_format"])
        if(!pass_u64(state[key],UINT32_MAX,&value)||![state[key] isEqual:attachments[key]])return nil;
    if(![record[@"vertex_function"] isKindOfClass:[NSString class]]||![record[@"fragment_function"] isKindOfClass:[NSString class]]||
       ![record[@"vertex_function"] length]||[record[@"vertex_function"] length]>512||![record[@"fragment_function"] length]||[record[@"fragment_function"] length]>512)return nil;
    NSMutableDictionary *keyRecord=[record mutableCopy];[keyRecord removeObjectForKey:@"id"];
    NSData *key=pipelineCache?pass_cache_key(@[keyRecord,@[attachments[@"samples"],attachments[@"pixel_format"],attachments[@"depth_format"],attachments[@"stencil_format"]]]):nil;
    FFSTFrameRenderPipeline *cached=key?[pipelineCache objectForKey:key]:nil;if(cached)return cached;
    id<MTLLibrary> vertex=pass_library(device,directory,blobs,record[@"vertex_file"],resolver,libraries,libraryCache,bytes),fragment=pass_library(device,directory,blobs,record[@"fragment_file"],resolver,libraries,libraryCache,bytes);
    id<MTLFunction> vs=[vertex newFunctionWithName:record[@"vertex_function"]],ps=[fragment newFunctionWithName:record[@"fragment_function"]];
    if(!vs||!ps||vs.functionType!=MTLFunctionTypeVertex||ps.functionType!=MTLFunctionTypeFragment||vs.stageInputAttributes.count)return nil;
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=vs;d.fragmentFunction=ps;d.inputPrimitiveTopology=topology;
    /* Legacy captures omitted these descriptor fields. New captures preserve
     * DXMT's immutable shader-table/IA declarations exactly. */
    if(state[@"vertex_buffer_mutability"]||state[@"fragment_buffer_mutability"]){
        NSArray *v=state[@"vertex_buffer_mutability"],*f=state[@"fragment_buffer_mutability"];
        if(!pass_numbers(v,31)||!pass_numbers(f,31))return nil;
        for(NSUInteger i=0;i<31;i++){
            if(!pass_u64(v[i],MTLMutabilityImmutable,&value))return nil;d.vertexBuffers[i].mutability=(MTLMutability)value;
            if(!pass_u64(f[i],MTLMutabilityImmutable,&value))return nil;d.fragmentBuffers[i].mutability=(MTLMutability)value;
        }
    }
    d.rasterSampleCount=[attachments[@"samples"] unsignedIntegerValue];d.depthAttachmentPixelFormat=[attachments[@"depth_format"] unsignedIntegerValue];d.stencilAttachmentPixelFormat=[attachments[@"stencil_format"] unsignedIntegerValue];
    d.colorAttachments[0].pixelFormat=[attachments[@"pixel_format"] unsignedIntegerValue];BOOL enabled;
    if(!pass_bool(state[@"alpha_to_coverage"],&enabled))return nil;d.alphaToCoverageEnabled=enabled;
    if(!pass_bool(state[@"alpha_to_one"],&enabled))return nil;d.alphaToOneEnabled=enabled;
    NSArray *blend=state[@"blend"];if(!pass_numbers(blend,8)||!pass_bool(blend[0],&enabled))return nil;
    for(unsigned i=1;i<8;++i)if(!pass_u64(blend[i],i==1?15:i<4?MTLBlendOperationMax:MTLBlendFactorOneMinusSource1Alpha,&value))return nil;
    MTLRenderPipelineColorAttachmentDescriptor *c=d.colorAttachments[0];c.blendingEnabled=enabled;c.writeMask=[blend[1] unsignedIntegerValue];
    c.rgbBlendOperation=[blend[2] unsignedIntegerValue];c.alphaBlendOperation=[blend[3] unsignedIntegerValue];c.sourceRGBBlendFactor=[blend[4] unsignedIntegerValue];
    c.destinationRGBBlendFactor=[blend[5] unsignedIntegerValue];c.sourceAlphaBlendFactor=[blend[6] unsignedIntegerValue];c.destinationAlphaBlendFactor=[blend[7] unsignedIntegerValue];
    NSError *error=nil;MTLRenderPipelineReflection *reflection=nil;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:d options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&error];
    FFSTFrameRenderPipeline *result=[FFSTFrameRenderPipeline new];ff_draw_layout layout;
    if(!pipeline||error||!ff_shader_layout(reflection,(uint32_t)mask,&layout)||!pass_layout_matches(record,&layout))return nil;
    result.state=pipeline;result.layout=layout;if(pipelineCache&&(!key||![pipelineCache setObject:result forKey:key cost:1]))return nil;return result;
}
static MTLStencilDescriptor *pass_stencil(id record) {
    if(!pass_numbers(record,6))return nil;uint64_t value;
    for(unsigned i=0;i<6;++i)if(!pass_u64(record[i],i<4?7:UINT32_MAX,&value))return nil;
    MTLStencilDescriptor *s=[MTLStencilDescriptor new];s.stencilCompareFunction=[record[0] unsignedIntegerValue];s.stencilFailureOperation=[record[1] unsignedIntegerValue];
    s.depthFailureOperation=[record[2] unsignedIntegerValue];s.depthStencilPassOperation=[record[3] unsignedIntegerValue];s.readMask=[record[4] unsignedIntValue];s.writeMask=[record[5] unsignedIntValue];return s;
}
/* Canonical validated Metal depth/stencil fields; no JSON serialization or
 * cryptographic hashing on each draw. Extra dictionary fields never affect the
 * descriptor. A null descriptor stays distinct from an explicit descriptor. */
static NSData *pass_depth_key(id record) {
    uint32_t fields[15]={0};uint64_t value;BOOL write;
    if(record==[NSNull null])return [NSData dataWithBytes:fields length:sizeof(fields)];
    if(!pass_record(record)||!pass_u64(record[@"compare"],7,&value)||!pass_bool(record[@"write"],&write))return nil;
    fields[0]=1;fields[1]=(uint32_t)value;fields[2]=write;
    if(!record[@"front"]||!record[@"back"])return nil;
    NSArray *faces=@[record[@"front"],record[@"back"]];
    for(unsigned face=0;face<2;++face){id stencil=faces[face];unsigned offset=3+face*6;
        if(stencil==[NSNull null])continue;
        if(!pass_numbers(stencil,6))return nil;
        for(unsigned i=0;i<6;++i){if(!pass_u64(stencil[i],i<4?7:UINT32_MAX,&value))return nil;fields[offset+i]=(uint32_t)value;}
        /* Mark a present face using a bit outside the compare-function range. */
        fields[offset]|=8;
    }
    return [NSData dataWithBytes:fields length:sizeof(fields)];
}
static id<MTLDepthStencilState> pass_depth(id<MTLDevice> device,id record,BOOL *valid) {
    *valid=NO;MTLDepthStencilDescriptor *d=[MTLDepthStencilDescriptor new];
    /* Explicitly restore Metal's disabled default. Passing nil to the Apple
     * render encoder crashes, and skipping the bind would retain prior state. */
    d.depthCompareFunction=MTLCompareFunctionAlways;d.depthWriteEnabled=NO;
    if(record!=[NSNull null]){uint64_t compare;BOOL write;
        if(!pass_record(record)||!pass_u64(record[@"compare"],7,&compare)||!pass_bool(record[@"write"],&write))return nil;
        d.depthCompareFunction=compare;d.depthWriteEnabled=write;
        for(NSString *key in @[@"front",@"back"]){id r=record[key];MTLStencilDescriptor *s=r==[NSNull null]?nil:pass_stencil(r);
            if(r!=[NSNull null]&&!s)return nil;if([key isEqual:@"front"])d.frontFaceStencil=s;else d.backFaceStencil=s;}
    }
    id<MTLDepthStencilState> result=[device newDepthStencilStateWithDescriptor:d];*valid=result!=nil;return result;
}
static BOOL pass_draw_matches(NSDictionary *record,const FFSTPassDrawInfo *info) {
    NSArray *tuple=record[@"draw"];if(!pass_numbers(tuple,5))return NO;uint64_t expected[]={info->primitive,info->start,info->count,info->instances,info->base_instance},value;
    for(unsigned i=0;i<5;++i)if(!pass_u64(tuple[i],UINT64_MAX,&value)||value!=expected[i])return NO;
    if(!info->indexed)return !record[@"indexed"];
    NSDictionary *indexed=record[@"indexed"];if(!pass_record(indexed))return NO;
    const char *keys[]={"index_type","index_count","index_offset"};uint64_t values[]={info->index_type,info->index_count,info->index_offset};
    for(unsigned i=0;i<3;++i)if(!pass_u64(indexed[@(keys[i])],UINT64_MAX,&value)||value!=values[i])return NO;
    id base=indexed[@"base_vertex"];return [base isKindOfClass:[NSNumber class]]&&isfinite([base doubleValue])&&[base doubleValue]==info->base_vertex;
}
static FFSTFrameRenderDraw *pass_draw(id<MTLDevice> device,NSDictionary *record,FFSTFrameRenderPipeline *pipeline,const FFSTPassDrawInfo *info,NSUInteger width,NSUInteger height,FFSTNativeSessionCache *depthCache) {
    if(!pass_record(record)||!pass_draw_matches(record,info)||!pass_numbers(record[@"viewport"],6)||!pass_numbers(record[@"scissor"],4)||
       !pass_numbers(record[@"raster"],7)||!pass_numbers(record[@"blend_constant"],4))return nil;
    NSArray *v=record[@"viewport"],*s=record[@"scissor"],*r=record[@"raster"],*b=record[@"blend_constant"];uint64_t scissor[4],value;
    for(unsigned i=0;i<4;++i)if(!pass_u64(s[i],UINT32_MAX,&scissor[i])||!pass_u64(r[i],i==1?2:1,&value)||!isfinite([b[i] floatValue]))return nil;
    if(scissor[0]>width||scissor[1]>height||!scissor[2]||!scissor[3]||scissor[2]>width-scissor[0]||scissor[3]>height-scissor[1]||
       [v[2] doubleValue]<=0||[v[3] doubleValue]<=0||[v[4] doubleValue]<0||[v[5] doubleValue]>1||[v[4] doubleValue]>[v[5] doubleValue])return nil;
    for(unsigned i=4;i<7;++i)if(!isfinite([r[i] floatValue]))return nil;
    if(!pass_u64(record[@"stencil_ref"],255,&value))return nil;BOOL valid;
    if(!record[@"depth_state"])return nil;
    NSData *depthKey=depthCache?pass_depth_key(record[@"depth_state"]):nil;
    if(depthCache&&!depthKey)return nil;
    id<MTLDepthStencilState> depth=depthKey?[depthCache objectForKey:depthKey]:nil;
    if(!depth){depth=pass_depth(device,record[@"depth_state"],&valid);if(!valid)return nil;
        if(depthCache&&(!depthKey||![depthCache setObject:depth forKey:depthKey cost:1]))return nil;}
    FFSTFrameRenderDraw *draw=[FFSTFrameRenderDraw new];draw.pipeline=pipeline;draw.depth=depth;draw.info=*info;draw.stencil=(uint32_t)value;
    FFSTDrawState encoded={0};encoded.pipeline=(__bridge const void *)pipeline.state;encoded.depth=(__bridge const void *)depth;
    for(unsigned i=0;i<6;++i)encoded.viewport[i]=[v[i] doubleValue];
    for(unsigned i=0;i<4;++i){encoded.scissor[i]=scissor[i];encoded.raster[i]=[r[i] unsignedIntValue];encoded.blend[i]=[b[i] floatValue];}
    for(unsigned i=0;i<3;++i)encoded.bias[i]=[r[i+4] floatValue];encoded.stencil=(uint32_t)value;draw.state=encoded;
    draw.viewport=(MTLViewport){[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue],[v[3] doubleValue],[v[4] doubleValue],[v[5] doubleValue]};
    draw.scissor=(MTLScissorRect){scissor[0],scissor[1],scissor[2],scissor[3]};return draw;
}

static FFSTFrameRenderDraw *pass_direct_draw(id<MTLDevice> device,const pr_row *r,NSArray *depths,FFSTFrameRenderPipeline *pipeline,const FFSTPassDrawInfo *info,NSUInteger width,NSUInteger height,FFSTNativeSessionCache *cache){
 if(!pr_row_valid(r,depths.count)||r->stencil>255||r->draw[0]!=info->primitive||r->draw[1]!=info->start||r->draw[2]!=info->count||r->draw[3]!=info->instances||r->draw[4]!=info->base_instance||r->indexed!=info->indexed||r->index_type!=info->index_type||r->base_vertex!=info->base_vertex||r->index_count!=info->index_count||r->index_offset!=info->index_offset||r->scissor[0]>width||r->scissor[1]>height||!r->scissor[2]||!r->scissor[3]||r->scissor[2]>width-r->scissor[0]||r->scissor[3]>height-r->scissor[1]||r->viewport[2]<=0||r->viewport[3]<=0||r->viewport[4]<0||r->viewport[5]>1||r->viewport[4]>r->viewport[5])return nil;
 id depthRecord=depths[r->depth];NSData *key=pass_depth_key(depthRecord);if(!key)return nil;id<MTLDepthStencilState> depth=[cache objectForKey:key];BOOL valid=NO;
 if(!depth){depth=pass_depth(device,depthRecord,&valid);if(!valid||(cache&&![cache setObject:depth forKey:key cost:1]))return nil;}
 FFSTFrameRenderDraw *draw=[FFSTFrameRenderDraw new];draw.pipeline=pipeline;draw.depth=depth;draw.info=*info;draw.stencil=r->stencil;
 FFSTDrawState state={0};state.pipeline=(__bridge const void *)pipeline.state;state.depth=(__bridge const void *)depth;
 memcpy(state.viewport,r->viewport,sizeof(state.viewport));for(unsigned i=0;i<4;i++)state.scissor[i]=r->scissor[i];memcpy(state.raster,r->raster,sizeof(state.raster));memcpy(state.blend,r->blend,sizeof(state.blend));memcpy(state.bias,r->bias,sizeof(state.bias));state.stencil=r->stencil;draw.state=state;
 draw.viewport=(MTLViewport){r->viewport[0],r->viewport[1],r->viewport[2],r->viewport[3],r->viewport[4],r->viewport[5]};draw.scissor=(MTLScissorRect){r->scissor[0],r->scissor[1],r->scissor[2],r->scissor[3]};return draw;
}
static NSUInteger pass_pixel_size(MTLPixelFormat format) {
    if(format==MTLPixelFormatRGB10A2Unorm||format==MTLPixelFormatRG11B10Float)return 4;return ff_texture_pixel_size((uint32_t)format);
}
static id<MTLTexture> pass_texture(id<MTLDevice> device,MTLPixelFormat format,NSUInteger width,NSUInteger height,NSUInteger samples,NSUInteger mips) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.sampleCount=samples;d.textureType=samples>1?MTLTextureType2DMultisample:MTLTextureType2D;d.storageMode=MTLStorageModePrivate;
    d.mipmapLevelCount=mips;
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;return [device newTextureWithDescriptor:d];
}

@interface FFSTNativeBufferReadback ()
@property(nonatomic,readwrite) uint64_t chunk,root,generation,contentVersion;
@property(nonatomic,readwrite) uint64_t offset,rowBytes,rowLength,rowCount;
@property(nonatomic,readwrite) uint32_t encoder,command;
@property(nonatomic,readwrite,strong) NSData *bytes;
@end
@implementation FFSTNativeBufferReadback @end

@interface FFSTNativeFrameExecution ()
@property(nonatomic,readwrite,strong) id<MTLTexture> texture;
@property(nonatomic,readwrite,strong) NSData *pixels;
@property(nonatomic,readwrite) NSUInteger rowBytes;
@property(nonatomic,readwrite,strong) NSDictionary *metrics;
@property(nonatomic,readwrite,strong) NSArray<FFSTNativeBufferReadback *> *bufferReadbacks;
@end
@implementation FFSTNativeFrameExecution @end

@interface FFSTFrameRoot : NSObject
@property(nonatomic) uint64_t kind,root,generation,version;
@property(nonatomic) BOOL written,initialized;
@property(nonatomic) uint32_t definedAspects; /* color=1, depth=2, stencil=4 */
@property(nonatomic,strong) id<MTLTexture> texture;
@property(nonatomic,strong) id<MTLBuffer> buffer;
@property(nonatomic) uint64_t bufferOrigin,bufferLength;
@property(nonatomic,strong) NSMutableData *liveShadow;
@property(nonatomic,strong) NSMutableIndexSet *liveShadowDefined;
@property(nonatomic,strong) id<MTLBuffer> directBuffer;
@property(nonatomic,strong) NSMutableDictionary<NSData *,id<MTLBuffer>> *directSlices;
@property(nonatomic) uint64_t directCost;
@property(nonatomic) uint64_t directEpoch,directOffset,directLength;
@property(nonatomic,strong) NSMutableIndexSet *bufferDefined;
@property(nonatomic) uint64_t lastUseSerial;
@property(nonatomic) uint64_t accountedBytes;
@property(nonatomic,weak) id<MTLTexture> initialTexture;
@property(nonatomic) uint64_t initialTextureVersion;
@property(nonatomic) NSUInteger initialMipCount;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSMutableIndexSet *> *definedMips;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSMutableIndexSet *> *definedFaces;
@end
@implementation FFSTFrameRoot @end

static void frame_mark_mips(FFSTFrameRoot *root,uint32_t aspect,NSRange range,BOOL defined) {
    if(!root.definedMips)root.definedMips=[NSMutableDictionary dictionary];
    NSMutableIndexSet *mips=root.definedMips[@(aspect)];if(!mips){mips=[NSMutableIndexSet indexSet];root.definedMips[@(aspect)]=mips;}
    if(defined)[mips addIndexesInRange:range];else [mips removeIndexesInRange:range];
    if([mips containsIndex:0])root.definedAspects|=aspect;else root.definedAspects&=~aspect;
}
/* A cube mip is globally defined only when all six physical faces are known.
 * Keep the existing 2D fast path and aggregate mip semantics for sampling. */
static void frame_define_mips(FFSTFrameRoot *root,uint32_t aspect,NSRange range,BOOL defined) {
    if(root.texture.textureType==MTLTextureTypeCube){
        if(!root.definedFaces)root.definedFaces=[NSMutableDictionary new];NSMutableIndexSet *faces=root.definedFaces[@(aspect)];
        if(!faces){faces=[NSMutableIndexSet new];root.definedFaces[@(aspect)]=faces;}
        for(NSUInteger slice=0;slice<6;++slice){NSRange r=NSMakeRange(slice*32+range.location,range.length);
            if(defined)[faces addIndexesInRange:r];else [faces removeIndexesInRange:r];}}
    frame_mark_mips(root,aspect,range,defined);
}
static BOOL frame_face_defined(FFSTFrameRoot *root,uint32_t aspect,NSUInteger mip,NSUInteger slice) {
    if(root.texture.textureType!=MTLTextureTypeCube)return !slice&&[root.definedMips[@(aspect)] containsIndex:mip];
    return slice<6&&mip<root.texture.mipmapLevelCount&&[root.definedFaces[@(aspect)] containsIndex:slice*32+mip];
}
static void frame_define_face(FFSTFrameRoot *root,uint32_t aspect,NSUInteger mip,NSUInteger slice) {
    if(root.texture.textureType!=MTLTextureTypeCube){frame_define_mips(root,aspect,NSMakeRange(mip,1),YES);return;}
    if(!root.definedFaces)root.definedFaces=[NSMutableDictionary new];NSMutableIndexSet *faces=root.definedFaces[@(aspect)];
    if(!faces){faces=[NSMutableIndexSet new];root.definedFaces[@(aspect)]=faces;}[faces addIndex:slice*32+mip];
    BOOL complete=YES;for(NSUInteger s=0;s<6;++s)if(![faces containsIndex:s*32+mip]){complete=NO;break;}
    frame_mark_mips(root,aspect,NSMakeRange(mip,1),complete);
}
static BOOL frame_view_defined(FFSTFrameRoot *root,NSDictionary *reference,uint32_t aspect) {
    uint64_t base,count,limit=root.texture.mipmapLevelCount;
    return limit&&pass_u64(reference[@"base_mip"],limit-1,&base)&&pass_u64(reference[@"mip_count"],limit-base,&count)&&count&&
        [root.definedMips[@(aspect)] containsIndexesInRange:NSMakeRange((NSUInteger)base,(NSUInteger)count)];
}

/* Private native keys only. Call after the reference/retirement integer
 * validator. Initialized uint64 arrays preserve every bit without padding or
 * NSNumber descriptions; these bytes never enter the wire or public APIs. */
static NSData *frame_root_key(NSDictionary *reference) {
    NSData *typed=ffmd_resource_root_key(reference);if(typed)return typed;
    const uint64_t fields[]={[reference[@"kind"] unsignedLongLongValue],[reference[@"root"] unsignedLongLongValue],
        [reference[@"allocation_generation"] unsignedLongLongValue]};
    return [NSData dataWithBytes:fields length:sizeof(fields)];
}
static uint64_t frame_monotonic_ns(void) {
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;
    return (uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
}
enum { FFST_PROFILE_COVERAGE,FFST_PROFILE_DECODE,FFST_PROFILE_ASSETS,FFST_PROFILE_PIPELINES,
    FFST_PROFILE_TABLES,FFST_PROFILE_ATTACHMENTS,FFST_PROFILE_COMMANDS,FFST_RENDER_PROFILE_COUNT };
static void frame_add_ns(uint64_t *total,uint64_t elapsed) {
    *total=elapsed>UINT64_MAX-*total?UINT64_MAX:*total+elapsed;
}
/* Disjoint host stages measured at pass boundaries, never per draw. These
 * exclude transport decode, GPU execution and retirement/import acknowledgement.
 * Rejected passes never publish completed-work metrics. */
static void frame_profile_mark(uint64_t *profile,unsigned stage,uint64_t *started) {
    uint64_t now=frame_monotonic_ns();if(*started&&now>=*started)frame_add_ns(&profile[stage],now-*started);*started=now;
}
static NSDictionary *frame_render_profile(const uint64_t *profile) {
    return @{@"coverage_seconds":@(profile[FFST_PROFILE_COVERAGE]/1e9),@"decode_seconds":@(profile[FFST_PROFILE_DECODE]/1e9),
        @"assets_seconds":@(profile[FFST_PROFILE_ASSETS]/1e9),@"pipeline_draw_seconds":@(profile[FFST_PROFILE_PIPELINES]/1e9),
        @"tables_seconds":@(profile[FFST_PROFILE_TABLES]/1e9),@"attachments_seconds":@(profile[FFST_PROFILE_ATTACHMENTS]/1e9),
        @"commands_seconds":@(profile[FFST_PROFILE_COMMANDS]/1e9)};
}
static NSData *frame_initial_key(NSDictionary *reference,uint64_t offset,size_t length) {
    ffmd_sidecar_resource r;if(ffmd_resource_raw(reference,&r,NULL)){const uint64_t values[]={r.kind,r.root,r.allocation_generation,r.view,r.input_content_version,offset,length};return [NSData dataWithBytes:values length:sizeof(values)];}
    const uint64_t fields[]={[reference[@"kind"] unsignedLongLongValue],[reference[@"root"] unsignedLongLongValue],
        [reference[@"allocation_generation"] unsignedLongLongValue],[reference[@"view"] unsignedLongLongValue],
        [reference[@"input_content_version"] unsignedLongLongValue],offset,(uint64_t)length};
    return [NSData dataWithBytes:fields length:sizeof(fields)];
}
static NSData *frame_asset_texture_descriptor(const ff_texture_snapshot *s) {
    if(!s||!s->plane_count||s->plane_count>FF_TEXTURE_PLANE_LIMIT)return nil;
    const uint64_t fields[]={s->format,s->texture_type,s->width,s->height,s->mip_count,s->array_length,
        s->has_swizzle,s->swizzle[0],s->swizzle[1],s->swizzle[2],s->swizzle[3],s->plane_count,1};
    NSMutableData *descriptor=[NSMutableData dataWithBytes:fields length:sizeof(fields)];
    for(size_t i=0;i<s->plane_count;i++){ff_texture_plane p=s->planes[i];
        const uint64_t plane[]={p.mip,p.slice,p.offset,p.row_bytes,p.length};[descriptor appendBytes:plane length:sizeof(plane)];}
    return descriptor;
}
static BOOL frame_reference(NSDictionary *r) {
    if(ffmd_resource_raw(r,NULL,NULL))return ffmd_resource_valid(r);
    uint64_t kind,root,view,generation,input,output,payload,offset,length;
    return pass_record(r)&&pass_u64(r[@"kind"],FFS_TEXTURE,&kind)&&kind&&
        pass_u64(r[@"root"],UINT64_MAX,&root)&&root&&pass_u64(r[@"view"],UINT64_MAX,&view)&&view&&
        pass_u64(r[@"allocation_generation"],UINT64_MAX,&generation)&&generation&&
        pass_u64(r[@"input_content_version"],UINT64_MAX-1,&input)&&input&&
        pass_u64(r[@"output_content_version"],UINT64_MAX,&output)&&(output==input||output==input+1)&&
        pass_u64(r[@"payload_id"],UINT64_MAX,&payload)&&payload&&pass_u64(r[@"offset"],UINT64_MAX,&offset)&&
        pass_u64(r[@"length"],UINT64_MAX-offset,&length)&&(kind!=FFS_BUFFER||length);
}
static BOOL frame_matches_record(NSDictionary *r,const ffs_record *record) {
    ffmd_sidecar_resource raw;uint64_t payload;
    if(ffmd_resource_raw(r,&raw,&payload)){if(!ffmd_resource_valid(r)||record->kind!=FFS_RESOURCE)return NO;
        const uint64_t fields[]={raw.kind,raw.root,raw.view,raw.allocation_generation,raw.input_content_version,raw.offset,raw.length,payload,raw.output_content_version};return !memcmp(fields,record->data,sizeof(fields));}
    if(!frame_reference(r)||record->kind!=FFS_RESOURCE)return NO;
    NSArray *keys=@[@"kind",@"root",@"view",@"allocation_generation",@"input_content_version",@"offset",@"length",@"payload_id",@"output_content_version"];
    uint64_t value;for(unsigned i=0;i<keys.count;++i)if(!pass_u64(r[keys[i]],UINT64_MAX,&value)||value!=record->data[i])return NO;
    return YES;
}
/* Only call after frame_reference/frame_matches_record validated integer types
 * and ranges. All eight membership fields are exact uint64_t values; payload
 * IDs remain checked against the ledger, but are not membership identity. */
static NSData *frame_reference_key(NSDictionary *reference) {
    NSData *typed=ffmd_resource_member_key(reference);if(typed)return typed;
    const uint64_t fields[]={[reference[@"kind"] unsignedLongLongValue],[reference[@"root"] unsignedLongLongValue],
        [reference[@"view"] unsignedLongLongValue],[reference[@"allocation_generation"] unsignedLongLongValue],
        [reference[@"input_content_version"] unsignedLongLongValue],[reference[@"output_content_version"] unsignedLongLongValue],
        [reference[@"offset"] unsignedLongLongValue],[reference[@"length"] unsignedLongLongValue]};
    return [NSData dataWithBytes:fields length:sizeof(fields)];
}
static unsigned frame_access(uint32_t flags) {
    return ((flags&FFS_READ)?1u:0u)|((flags&FFS_WRITE)?2u:0u);
}
/* Private, encoder-local snapshot. Never cache across encoder/version changes.
 * A state bit represents one record's complete access flags: separate READ and
 * WRITE records must not manufacture a READ|WRITE dependency. */
@interface FFSTFrameResourceIndex : NSObject
- (instancetype)initWithResources:(NSArray *)resources records:(NSArray<NSData *> *)records;
- (BOOL)containsReference:(NSDictionary *)reference flags:(uint32_t)flags;
@end
@implementation FFSTFrameResourceIndex {
    NSDictionary<NSData *,NSNumber *> *_members;
}
- (instancetype)initWithResources:(NSArray *)resources records:(NSArray<NSData *> *)records {
    if(![resources isKindOfClass:[NSArray class]]||![records isKindOfClass:[NSArray class]]||
       resources.count!=records.count||resources.count>FFS_MAX_RECORDS)return nil;
    self=[super init];if(!self)return nil;
    NSMutableDictionary<NSData *,NSNumber *> *members=[NSMutableDictionary dictionaryWithCapacity:resources.count];
    for(NSUInteger i=0;i<resources.count;++i){
        NSData *bytes=records[i];if(![bytes isKindOfClass:[NSData class]]||bytes.length!=sizeof(ffs_record))return nil;
        ffs_record record;memcpy(&record,bytes.bytes,sizeof(record));
        if(!frame_matches_record(resources[i],&record))return nil;
        unsigned access=frame_access(record.flags);if(!access)return nil;
        NSData *key=frame_reference_key(resources[i]);
        members[key]=@([members[key] unsignedIntValue]|(1u<<access));
    }
    _members=[members copy];return self;
}
- (BOOL)containsReference:(NSDictionary *)reference flags:(uint32_t)flags {
    unsigned access=frame_access(flags);
    if(!access||(flags&~(FFS_READ|FFS_WRITE))||!frame_reference(reference))return NO;
    unsigned states=[_members[frame_reference_key(reference)] unsignedIntValue];
    return (states&(1u<<access))||(access!=3&&(states&(1u<<3)));
}
@end
static BOOL frame_header(NSDictionary *bindings,const char *format,const ffs_record *begin) {
    uint64_t value;
    if(!pass_record(bindings)||![bindings[@"format"] isEqual:@(format)]||![bindings[@"version"] isEqual:@1])return NO;
    const uint64_t values[]={begin->stream,begin->frame,begin->chunk,begin->encoder,begin->data[4]};
    NSArray *keys=@[@"stream",@"frame",@"chunk",@"encoder",@"payload_id"];
    for(unsigned i=0;i<5;++i)if(!pass_u64(bindings[keys[i]],UINT64_MAX,&value)||value!=values[i])return NO;
    return YES;
}
static BOOL frame_view_fields(NSDictionary *r) {
    uint64_t value;
    for(NSString *key in @[@"base_mip",@"base_slice",@"mip_count",@"slice_count",@"format",@"type",@"width",@"height",@"array_length",@"sample_count"])
        if(!pass_u64(r[key],UINT32_MAX,&value))return NO;
    if(!pass_numbers(r[@"swizzle"],4))return NO;
    for(id item in r[@"swizzle"])if(!pass_u64(item,MTLTextureSwizzleAlpha,&value))return NO;
    return YES;
}
static BOOL frame_snapshot_view(NSDictionary *r,const ff_texture_snapshot *texture) {
    ffmd_sidecar_resource raw;if(ffmd_resource_raw(r,&raw,NULL)){
        if(raw.kind!=FFS_TEXTURE||raw.mip_count!=texture->mip_count||raw.slice_count!=(texture->texture_type==MTLTextureTypeCube?6:texture->array_length)||raw.format!=texture->format||raw.type!=texture->texture_type||raw.width!=texture->width||raw.height!=texture->height||raw.array_length!=texture->array_length||raw.sample_count!=1)return NO;
        const uint32_t identity[]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
        for(unsigned i=0;i<4;i++)if(raw.swizzle[i]>MTLTextureSwizzleAlpha||raw.swizzle[i]!=(texture->has_swizzle?texture->swizzle[i]:identity[i]))return NO;return YES;}

    if(!frame_view_fields(r))return NO;
    uint64_t value;const uint64_t values[]={texture->mip_count,texture->texture_type==MTLTextureTypeCube?6:texture->array_length,
        texture->format,texture->texture_type,texture->width,texture->height,texture->array_length,1};
    NSArray *keys=@[@"mip_count",@"slice_count",@"format",@"type",@"width",@"height",@"array_length",@"sample_count"];
    for(unsigned i=0;i<keys.count;++i)if(!pass_u64(r[keys[i]],UINT32_MAX,&value)||value!=values[i])return NO;
    const uint32_t identity[]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
    for(unsigned i=0;i<4;++i)if([r[@"swizzle"][i] unsignedIntValue]!=(texture->has_swizzle?texture->swizzle[i]:identity[i]))return NO;
    return YES;
}
static id<MTLTexture> frame_native_view(FFSTFrameRoot *root,NSDictionary *r) {
    id<MTLTexture> texture=root.texture;if(!texture||!frame_view_fields(r)||[r[@"base_slice"] unsignedLongLongValue])return nil;
    NSUInteger base=[r[@"base_mip"] unsignedIntegerValue],mips=[r[@"mip_count"] unsignedIntegerValue];
    if(base>=texture.mipmapLevelCount||!mips||mips>texture.mipmapLevelCount-base||
       [r[@"width"] unsignedLongLongValue]!=MAX((NSUInteger)1,texture.width>>base)||[r[@"height"] unsignedLongLongValue]!=MAX((NSUInteger)1,texture.height>>base)||
       [r[@"array_length"] unsignedLongLongValue]!=texture.arrayLength||
       [r[@"sample_count"] unsignedLongLongValue]!=texture.sampleCount||[r[@"type"] unsignedLongLongValue]!=texture.textureType||
       [r[@"slice_count"] unsignedLongLongValue]!=(texture.textureType==MTLTextureTypeCube?6:texture.arrayLength))return nil;
    MTLTextureSwizzleChannels s=texture.swizzle;
    BOOL same=!base&&mips==texture.mipmapLevelCount&&[r[@"format"] unsignedLongLongValue]==texture.pixelFormat&&[r[@"swizzle"][0] unsignedIntValue]==s.red&&
        [r[@"swizzle"][1] unsignedIntValue]==s.green&&[r[@"swizzle"][2] unsignedIntValue]==s.blue&&[r[@"swizzle"][3] unsignedIntValue]==s.alpha;
    if(same)return texture;
    if(texture.sampleCount!=1)return nil;
    s=(MTLTextureSwizzleChannels){[r[@"swizzle"][0] unsignedIntValue],[r[@"swizzle"][1] unsignedIntValue],
        [r[@"swizzle"][2] unsignedIntValue],[r[@"swizzle"][3] unsignedIntValue]};
    return [texture newTextureViewWithPixelFormat:[r[@"format"] unsignedIntegerValue] textureType:texture.textureType
        levels:NSMakeRange(base,mips) slices:NSMakeRange(0,[r[@"slice_count"] unsignedIntegerValue]) swizzle:s];
}
static BOOL frame_draw_command(uint64_t type){return type==19||type==20;}
static BOOL frame_supported_command(uint64_t type) {
    /* Exact pinned WMTRenderCommandType values, matching the FFST walker. */
    return type<=5||(type>=10&&type<=20)||type==25||(type>=33&&type<=36);
}
static BOOL frame_identity_sdr(NSDictionary *state,id<MTLTexture> texture) {
    if(!pass_record(state)||![state[@"mode"] isEqual:@"identity-sdr"]||
       (texture.pixelFormat!=MTLPixelFormatRGBA8Unorm&&texture.pixelFormat!=MTLPixelFormatBGRA8Unorm))return NO;
    const uint64_t expected[]={texture.pixelFormat,0,0,1,texture.width,texture.height};
    NSArray *keys=@[@"source_format",@"effective_colorspace",@"gamma_version",@"sample_count",@"drawable_width",@"drawable_height"];
    uint64_t value;for(unsigned i=0;i<keys.count;++i)if(!pass_u64(state[keys[i]],UINT64_MAX,&value)||value!=expected[i])return NO;
    id declared=state[@"presenter_format"]?:state[@"source_format"];
    if(!pass_u64(declared,UINT32_MAX,&value)||(value!=MTLPixelFormatRGBA8Unorm&&value!=MTLPixelFormatBGRA8Unorm))return NO;
    for(NSString *key in @[@"edr_scale",@"max_content_luminance",@"max_display_luminance"]){id number=state[key];
        if(![number isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)number)==CFBooleanGetTypeID()||!isfinite([number doubleValue]))return NO;}
    BOOL hdr;if(!pass_bool(state[@"hdr_metadata_enabled"],&hdr)||hdr||[state[@"edr_scale"] doubleValue]!=1)return NO;
    return texture.sampleCount==1;
}

@protocol FFSTNativeExecutionRequest <NSObject>
@property(nonatomic,readonly) NSData *records;
@property(nonatomic,readonly) id<FFSTNativeFramePayloadProvider> payloads;
@property(nonatomic,readonly) size_t retainedBytes;
@end
@interface FFSTNativeFrameEngine : NSObject {
@public
    uint64_t renderProfileNs[FFST_RENDER_PROFILE_COUNT];
    uint64_t operationNs;
}
@property(nonatomic,strong) id<FFSTNativeExecutionRequest> request;
@property(nonatomic,strong) id<MTLDevice> device;
@property(nonatomic,strong) id<MTLCommandBuffer> command;
@property(nonatomic,strong) id<MTLCommandQueue> queue;
@property(nonatomic,strong) NSMutableArray<id<MTLCommandBuffer>> *commands;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id<MTLCommandBuffer>> *chunkCommands;
@property(nonatomic,strong) NSMutableDictionary<NSString *,id<MTLSharedEvent>> *events;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *timestampRequests,*signalRequests;
@property(nonatomic,strong) NSMutableDictionary<NSData *,FFSTFrameRoot *> *roots;
@property(nonatomic,strong) NSMutableSet<FFSTFrameRoot *> *dirtyRoots;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSData *> *initialDigests;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSMutableSet<NSData *> *> *initialDigestKeys;
@property(nonatomic,strong) NSMutableArray<FFSTFrameRenderContext *> *contexts;
@property(nonatomic,strong) NSMutableDictionary *libraries;
@property(nonatomic,strong) FFSTNativeSessionCache *libraryCache,*pipelineCache,*depthCache,*assetCache;
@property(nonatomic,strong) NSMutableIndexSet *evidence;
@property(nonatomic,strong) FFSTFrameResourceIndex *resourceIndex;
@property(nonatomic,strong) FFSTOwnedBlobs *ownedBlobs;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSDictionary *> *liveReferenceIndex;
@property(nonatomic,strong) NSMutableDictionary<NSData *,id<MTLSamplerState>> *liveSamplers;
@property(nonatomic,strong) id<MTLBuffer> liveTableArena;
@property(nonatomic) NSUInteger liveTableOffset,liveTableBytes;
@property(nonatomic,strong) id<MTLBuffer> uploadPool;
@property(nonatomic) NSUInteger uploadOffset;
@property(nonatomic,copy) FFSTPassLibraryResolver libraryResolver;
@property(nonatomic,copy) BOOL (^cancelled)(void);
@property(nonatomic,strong) NSString *failure;
@property(nonatomic) uint64_t firstSequence,libraryBytes,allocatedBytes,payloadBytes,drawCount,passCount;
@property(nonatomic) uint64_t maxBytes,serial;
@property(nonatomic) uint64_t initialMipCopies;
@property(nonatomic) uint64_t textureUploadBytes;
@property(nonatomic) uint64_t readbackBytes;
@property(nonatomic) uint64_t sharedSnapshotBuffers,sharedSnapshotBufferBytes;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *bufferReadbackRequests,*bufferReadbackStaging;
@property(nonatomic) uint64_t operationCount,currentChunk,copyBytes;
@property(nonatomic) BOOL committed,imports,retired,snapshotSubmissionNotified;
@property(nonatomic,strong) id<MTLTexture> finalTexture;
@property(nonatomic,strong) NSDictionary *presentReference;
@property(nonatomic,strong) NSDictionary *presentation;
- (BOOL)reject:(NSString *)reason;
- (BOOL)render:(const ffs_record *)begin resources:(NSArray<NSData *> *)resources commands:(NSArray<NSData *> *)commands;
- (BOOL)present:(const ffs_record *)begin resources:(NSArray<NSData *> *)resources commands:(NSArray<NSData *> *)commands present:(const ffs_record *)present;
- (BOOL)retire;
- (void)commitPrepared;
- (BOOL)stageBufferReadbacks;
- (NSArray<FFSTNativeBufferReadback *> *)completedBufferReadbacks;
- (BOOL)operation:(const ffs_record *)begin resources:(NSArray<NSData *> *)resources commands:(NSArray<NSData *> *)commands dependencies:(NSArray<NSData *> *)dependencies;
- (id<MTLTexture>)staticTexture:(const ff_texture_snapshot *)snapshot reference:(NSDictionary *)reference;
- (id<MTLBuffer>)staticBuffer:(const ff_vertex_snapshot *)snapshot reference:(NSDictionary *)reference offset:(uint64_t)offset nativeOffset:(NSUInteger *)nativeOffset;
- (id<MTLBuffer>)wrapSharedSnapshot:(NSData<FFSTSharedSnapshotMemory> *)shared;
- (id<MTLTexture>)allocateFormat:(NSUInteger)format width:(NSUInteger)width height:(NSUInteger)height samples:(NSUInteger)samples mips:(NSUInteger)mips;
- (void)rememberInitialTexture:(id<MTLTexture>)texture reference:(NSDictionary *)reference;
@end

@implementation FFSTNativeFrameEngine
- (BOOL)reject:(NSString *)reason {if(!self.failure)self.failure=reason;return NO;}
- (BOOL)selectDevice:(uint64_t)registry {
    if(!registry)return [self reject:@"operation lacks exact Metal device"];
    if(!self.device)for(id<MTLDevice> device in MTLCopyAllDevices())if(device.registryID==registry){self.device=device;break;}
    return self.device&&self.device.registryID==registry?YES:[self reject:@"native operation device mismatch"];
}
- (BOOL)ensureCommand {
    if(self.command)return YES;if(!self.device)return [self reject:@"native command device unavailable"];
    if(!self.queue)self.queue=[self.device newCommandQueue];self.command=[self.queue commandBuffer];
    if(!self.command)return [self reject:@"native chunk command unavailable"];
    self.chunkCommands[@(self.currentChunk)]=self.command;return YES;
}
- (void)beginChunk:(uint64_t)chunk {
    if(self.command){[self.commands addObject:self.command];self.command=nil;}self.currentChunk=chunk;
}
- (FFSTFrameRoot *)root:(NSDictionary *)reference {
    if(!frame_reference(reference)){[self reject:@"invalid logical frame resource"];return nil;}
    NSData *key=frame_root_key(reference);FFSTFrameRoot *root=self.roots[key];uint64_t version=[reference[@"input_content_version"] unsignedLongLongValue];
    if(!root){if(self.roots.count>=FFS_MAX_GENERATIONS){[self reject:@"native frame root limit"];return nil;}
        root=[FFSTFrameRoot new];root.kind=[reference[@"kind"] unsignedLongLongValue];root.root=[reference[@"root"] unsignedLongLongValue];
        root.generation=[reference[@"allocation_generation"] unsignedLongLongValue];root.version=version;self.roots[key]=root;}
    if(root.version!=version){[self reject:@"native frame resource version mismatch"];return nil;}
    root.lastUseSerial=self.serial;return root;
}
- (BOOL)coverage:(NSDictionary *)sidecar begin:(const ffs_record *)begin resources:(NSArray<NSData *> *)resourceRecords commands:(NSArray<NSData *> *)commands render:(BOOL)render {
    const char *format=render?"bedrock-native-frame-pass":begin->data[0]==FFS_PRESENT_ENCODER?"bedrock-native-frame-present":"bedrock-native-frame-operation";
    if([sidecar[@"format"]isEqual:@"bedrock-live-commands"])format="bedrock-live-commands";
    if(!frame_header(sidecar,format,begin))return [self reject:@"frame payload/encoder identity mismatch"];
    NSArray *resources=sidecar[@"resources"],*types=sidecar[@"command_types"];
    if(![resources isKindOfClass:[NSArray class]]||resources.count!=resourceRecords.count||![types isKindOfClass:[NSArray class]]||types.count!=commands.count)return [self reject:@"frame payload coverage count mismatch"];
    self.resourceIndex=[[FFSTFrameResourceIndex alloc] initWithResources:resources records:resourceRecords];
    if(!self.resourceIndex)return [self reject:@"frame payload resource identity mismatch"];
    for(NSUInteger i=0;i<resources.count;++i){const ffs_record *record=resourceRecords[i].bytes;
        if(![self root:resources[i]])return [self reject:@"frame payload resource identity mismatch"];
        [self.evidence addIndex:(NSUInteger)(record->sequence-self.firstSequence)];}
    for(NSUInteger i=0;i<commands.count;++i){const ffs_record *record=commands[i].bytes;uint64_t type;
        if(!pass_u64(types[i],UINT16_MAX,&type)||type!=record->data[0]||record->data[1]!=begin->data[4]||(render&&!frame_supported_command(type)))return [self reject:@"frame command payload/order unsupported"];
        [self.evidence addIndex:(NSUInteger)(record->sequence-self.firstSequence)];}
    [self.evidence addIndex:(NSUInteger)(begin->sequence-self.firstSequence)];return YES;
}
- (id<MTLTexture>)allocateFormat:(NSUInteger)format width:(NSUInteger)width height:(NSUInteger)height samples:(NSUInteger)samples {
    return [self allocateFormat:format width:width height:height samples:samples mips:1];
}
- (id<MTLTexture>)allocateFormat:(NSUInteger)format width:(NSUInteger)width height:(NSUInteger)height samples:(NSUInteger)samples mips:(NSUInteger)mips {
    if(!width||!height||width>8192||height>8192||!ffst_sample_count_supported(self.device,samples))return nil;
    if(!mips||mips>32-(uint32_t)__builtin_clz((uint32_t)MAX(width,height))||(samples>1&&mips!=1))return nil;
    uint64_t estimate=0;for(NSUInteger m=0;m<mips;++m)estimate+=(uint64_t)MAX((NSUInteger)1,width>>m)*MAX((NSUInteger)1,height>>m)*16*samples;
    if(self.payloadBytes>self.maxBytes-self.allocatedBytes||estimate>self.maxBytes-self.allocatedBytes-self.payloadBytes)return nil;
    id<MTLTexture> texture=pass_texture(self.device,format,width,height,samples,mips);
    if(!texture||texture.allocatedSize>self.maxBytes-self.allocatedBytes-self.payloadBytes)return nil;
    self.allocatedBytes+=texture.allocatedSize;return texture;
}
- (id<MTLTexture>)attachment:(NSDictionary *)reference format:(NSUInteger)format width:(NSUInteger)width height:(NSUInteger)height samples:(NSUInteger)samples load:(NSUInteger)load aspect:(uint32_t)aspect {
    if(!frame_view_fields(reference)||[reference[@"base_mip"] unsignedLongLongValue]||[reference[@"base_slice"] unsignedLongLongValue]||
       [reference[@"format"] unsignedLongLongValue]!=format||[reference[@"width"] unsignedLongLongValue]!=width||[reference[@"height"] unsignedLongLongValue]!=height||
       [reference[@"sample_count"] unsignedLongLongValue]!=samples||[reference[@"mip_count"] unsignedLongLongValue]!=1||
       [reference[@"array_length"] unsignedLongLongValue]!=1||[reference[@"slice_count"] unsignedLongLongValue]!=1||
       [reference[@"type"] unsignedLongLongValue]!=(samples>1?MTLTextureType2DMultisample:MTLTextureType2D))return nil;
    const uint32_t identity[]={MTLTextureSwizzleRed,MTLTextureSwizzleGreen,MTLTextureSwizzleBlue,MTLTextureSwizzleAlpha};
    for(unsigned i=0;i<4;++i)if([reference[@"swizzle"][i] unsignedIntValue]!=identity[i])return nil;
    FFSTFrameRoot *root=[self root:reference];if(!root||root.kind!=FFS_TEXTURE)return nil;
    if(load==MTLLoadActionLoad&&root.written&&!frame_view_defined(root,reference,aspect))return nil;
    if(!root.texture){
        if(root.initialMipCount>1){id<MTLTexture> initial=root.initialTexture;
            if(root.written||root.initialTextureVersion!=root.version||!initial||initial.device.registryID!=self.device.registryID||
               initial.pixelFormat!=format||initial.textureType!=MTLTextureType2D||initial.width!=width||initial.height!=height||
               initial.sampleCount!=1||samples!=1||initial.arrayLength!=1||initial.mipmapLevelCount!=root.initialMipCount||aspect!=1){
                [self reject:@"qualified full initial mip chain unavailable for native write"];return nil;}
            id<MTLTexture> full=[self allocateFormat:format width:width height:height samples:1 mips:initial.mipmapLevelCount];
            id<MTLBlitCommandEncoder> copy=full&&full!=initial?[self.command blitCommandEncoder]:nil;if(!copy)return nil;
            for(NSUInteger m=0;m<initial.mipmapLevelCount;++m)[copy copyFromTexture:initial sourceSlice:0 sourceLevel:m sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(MAX((NSUInteger)1,width>>m),MAX((NSUInteger)1,height>>m),1) toTexture:full destinationSlice:0 destinationLevel:m destinationOrigin:MTLOriginMake(0,0,0)];
            [copy endEncoding];root.texture=full;[self.dirtyRoots addObject:root];root.initialized=YES;
            frame_define_mips(root,1,NSMakeRange(0,initial.mipmapLevelCount),YES);++self.initialMipCopies;
        }else {root.texture=[self allocateFormat:format width:width height:height samples:samples];if(root.texture)[self.dirtyRoots addObject:root];}
    }
    id<MTLTexture> target=frame_native_view(root,reference);if(!target)return nil;
    /* An exported first-use lease must retire even when the initial CPU-owned
     * mip chain already supplied these bytes. Copy only this attachment view. */
    BOOL exportedLease=reference[@"shared_cut_id"]!=nil;
    if(load==MTLLoadActionLoad&&!root.written&&(!root.initialized||exportedLease)){id<FFSTNativeFramePayloadProvider> provider=self.request.payloads;
        if(![provider respondsToSelector:@selector(initialTexture:device:failure:)]||![provider respondsToSelector:@selector(finishImportsWithCommand:failure:)]||
           ![provider respondsToSelector:@selector(waitForImportRetirement:)]||![provider respondsToSelector:@selector(abandonImports)])return nil;
        NSString *failure=nil;id<MTLTexture> source=[provider initialTexture:reference device:self.device failure:&failure];
        if(!source){[self reject:failure?:@"initial attachment version unavailable"];return nil;}self.imports=YES;
        if(source.device.registryID!=self.device.registryID||source.pixelFormat!=format||source.width!=width||source.height!=height||source.sampleCount!=samples||source.mipmapLevelCount!=1||source.arrayLength!=1)return nil;
        id<MTLBlitCommandEncoder> copy=[self.command blitCommandEncoder];if(!copy)return nil;[copy copyFromTexture:source toTexture:target];[copy endEncoding];root.initialized=YES;
        for(uint32_t bit=1;bit<=4;bit<<=1)frame_define_mips(root,bit,NSMakeRange(0,1),YES);
    }
    return target;
}
- (BOOL)initialBytes:(const void *)bytes length:(size_t)length reference:(NSDictionary *)reference offset:(uint64_t)offset {
    if(!bytes||!length)return [self reject:@"missing immutable initial resource bytes"];
    NSData *key=frame_initial_key(reference,offset,length);
    BOOL pagedBuffer=[reference[@"kind"] unsignedIntValue]==FFS_BUFFER&&length>=FFST_CONTENT_PAGE_MIN_BYTES;
    NSData *data=pagedBuffer?[self.ownedBlobs verifiedBufferIDForBytes:bytes length:length]:
        [self.ownedBlobs verifiedDigestForBytes:bytes length:length];
    if(!data&&pagedBuffer){data=ffst_buffer_content_id(bytes,length);if(!data)return [self reject:@"invalid canonical buffer identity extent"];}
    if(!data){unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(bytes,(CC_LONG)length,digest);data=[NSData dataWithBytes:digest length:sizeof(digest)];}
    if(self.initialDigests[key]&&![self.initialDigests[key] isEqual:data])return [self reject:@"contradictory initial resource version"];
    if(!self.initialDigests[key]&&self.initialDigests.count>=FFS_MAX_RESOURCES*4)return [self reject:@"native immutable input identity limit"];
    if(!self.initialDigests[key]){NSData *root=frame_root_key(reference);NSMutableSet *keys=self.initialDigestKeys[root];
        if(!keys){keys=[NSMutableSet new];self.initialDigestKeys[root]=keys;}[keys addObject:key];}
    self.initialDigests[key]=data;return YES;
}
- (id<MTLBuffer>)wrapSharedSnapshot:(NSData<FFSTSharedSnapshotMemory> *)shared {
    NSUInteger physical=shared.allocatedLength;
    if(!shared||!shared.length||physical<shared.length||self.allocatedBytes>self.maxBytes||
       self.payloadBytes>self.maxBytes-self.allocatedBytes||
       physical>self.maxBytes-self.allocatedBytes-self.payloadBytes){
        [self reject:@"shared snapshot Metal wrapper exceeds native budget"];return nil;}
    id<MTLBuffer> transient=[self.device newBufferWithBytesNoCopy:(void *)shared.bytes length:physical
        options:MTLResourceStorageModeShared deallocator:^(__unused void *bytes,__unused NSUInteger length){
            /* The captured view keeps its exact arena pin until Metal no
             * longer uses this wrapper, after actual command retirement. */
            (void)shared.length;
        }];
    uint64_t cost=transient?MAX((uint64_t)1,transient.allocatedSize):0;
    if(!transient||cost>self.maxBytes-self.allocatedBytes-self.payloadBytes){
        [self reject:@"shared snapshot Metal wrapper unavailable"];return nil;}
    self.allocatedBytes+=cost;++self.sharedSnapshotBuffers;
    self.sharedSnapshotBufferBytes+=shared.length;return transient;
}
- (id<MTLBuffer>)staticBuffer:(const ff_vertex_snapshot *)snapshot reference:(NSDictionary *)reference offset:(uint64_t)offset nativeOffset:(NSUInteger *)nativeOffset {
    if(nativeOffset)*nativeOffset=0;
    NSData *identity=frame_initial_key(reference,offset,snapshot->length);BOOL firstIdentity=!self.initialDigests[identity];
    /* Logical consistency is checked even when another root already cached
     * identical bytes. A content hit must never hide a changed CPU version. */
    if(![self initialBytes:snapshot->bytes length:snapshot->length reference:reference offset:offset])return nil;
    if(nativeOffset&&self.uploadPool&&snapshot->length<=65536){
        NSUInteger offset=(self.uploadOffset+255)&~(NSUInteger)255;
        if(offset<=self.uploadPool.length&&snapshot->length<=self.uploadPool.length-offset){
            memcpy((uint8_t *)self.uploadPool.contents+offset,snapshot->bytes,snapshot->length);
            self.uploadOffset=offset+snapshot->length;*nativeOffset=offset;return self.uploadPool;}}
    NSData<FFSTSharedSnapshotMemory> *shared=[self.ownedBlobs verifiedSharedSnapshotForBytes:snapshot->bytes length:snapshot->length];
    if(shared)return [self wrapSharedSnapshot:shared];
    NSData *key=nil;id<MTLBuffer> buffer=[self.assetCache objectForAssetKind:FFST_ASSET_BUFFER digest:self.initialDigests[identity] length:snapshot->length descriptor:nil key:&key];if(!key)return nil;
    if(buffer){[self.assetCache recordAssetContentHit:FFST_ASSET_BUFFER firstIdentity:firstIdentity];return buffer;}
    if(snapshot->length>self.maxBytes-self.allocatedBytes)return nil;
    buffer=[self.device newBufferWithBytes:snapshot->bytes length:snapshot->length options:MTLResourceStorageModeShared];
    uint64_t cost=MAX((uint64_t)1,buffer.allocatedSize);
    if(!buffer||cost>self.maxBytes-self.allocatedBytes||![self.assetCache setObject:buffer forKey:key cost:cost])return nil;
    self.allocatedBytes+=cost;[self.assetCache recordAssetUpload:FFST_ASSET_BUFFER bytes:snapshot->length];return buffer;
}
- (id<MTLTexture>)staticTexture:(const ff_texture_snapshot *)snapshot reference:(NSDictionary *)reference {
    NSData *identity=frame_initial_key(reference,0,snapshot->length);BOOL firstIdentity=!self.initialDigests[identity];
    if(![self initialBytes:snapshot->bytes length:snapshot->length reference:reference offset:0])return nil;
    NSData *key=nil;id<MTLTexture> cached=[self.assetCache objectForAssetKind:FFST_ASSET_TEXTURE digest:self.initialDigests[identity] length:snapshot->length
        descriptor:frame_asset_texture_descriptor(snapshot) key:&key];if(!key)return nil;
    if(cached){
        [self.assetCache recordAssetContentHit:FFST_ASSET_TEXTURE firstIdentity:firstIdentity];
        [self rememberInitialTexture:cached reference:reference];return cached;}
    if(![self ensureCommand]||snapshot->length>self.maxBytes-self.allocatedBytes)return nil;
    MTLTextureDescriptor *d=[MTLTextureDescriptor new];d.textureType=snapshot->texture_type;d.pixelFormat=snapshot->format;
    d.width=snapshot->width;d.height=snapshot->height;d.mipmapLevelCount=snapshot->mip_count;d.arrayLength=snapshot->array_length;
    d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> texture=[self.device newTextureWithDescriptor:d];
    if(!texture||texture.allocatedSize>self.maxBytes-self.allocatedBytes)return nil;uint64_t cost=MAX((uint64_t)1,texture.allocatedSize);
    id<MTLBuffer> upload=[self.device newBufferWithBytes:snapshot->bytes length:snapshot->length options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=upload?[self.command blitCommandEncoder]:nil;if(!blit)return nil;
    for(size_t p=0;p<snapshot->plane_count;++p){ff_texture_plane plane=snapshot->planes[p];
        [blit copyFromBuffer:upload sourceOffset:plane.offset sourceBytesPerRow:plane.row_bytes sourceBytesPerImage:plane.length
            sourceSize:MTLSizeMake(MAX((NSUInteger)1,snapshot->width>>plane.mip),MAX((NSUInteger)1,snapshot->height>>plane.mip),1)
            toTexture:texture destinationSlice:plane.slice destinationLevel:plane.mip destinationOrigin:MTLOriginMake(0,0,0)];}
    [blit endEncoding];
    if(snapshot->has_swizzle){MTLTextureSwizzleChannels s={(MTLTextureSwizzle)snapshot->swizzle[0],(MTLTextureSwizzle)snapshot->swizzle[1],
            (MTLTextureSwizzle)snapshot->swizzle[2],(MTLTextureSwizzle)snapshot->swizzle[3]};
        texture=[texture newTextureViewWithPixelFormat:snapshot->format textureType:snapshot->texture_type levels:NSMakeRange(0,snapshot->mip_count)
            slices:NSMakeRange(0,snapshot->texture_type==MTLTextureTypeCube?6:snapshot->array_length) swizzle:s];if(!texture)return nil;}
    uint64_t uploadCost=upload.allocatedSize;
    if(cost>self.maxBytes-self.allocatedBytes||uploadCost>self.maxBytes-self.allocatedBytes-cost||
       ![self.assetCache setObject:texture forKey:key cost:cost])return nil;
    self.allocatedBytes+=cost+uploadCost;[self.assetCache recordAssetUpload:FFST_ASSET_TEXTURE bytes:snapshot->length];
    [self rememberInitialTexture:texture reference:reference];return texture;
}
- (void)rememberInitialTexture:(id<MTLTexture>)texture reference:(NSDictionary *)reference {
    FFSTFrameRoot *root=self.roots[frame_root_key(reference)];
    if(root&&!root.written&&texture.textureType==MTLTextureType2D&&texture.arrayLength==1&&texture.sampleCount==1&&
       ![reference[@"base_mip"] unsignedLongLongValue]&&![reference[@"base_slice"] unsignedLongLongValue]&&
       texture.mipmapLevelCount>=root.initialMipCount){root.initialTexture=texture;root.initialTextureVersion=root.version;root.initialMipCount=texture.mipmapLevelCount;}
}
- (FFSTFrameRoot *)buffer:(NSDictionary *)reference {
    FFSTFrameRoot *root=[self root:reference];uint64_t origin,length,offset,viewLength;
    if(!root||root.kind!=FFS_BUFFER||!pass_u64(reference[@"buffer_base_offset"],UINT64_MAX,&origin)||
       !pass_u64(reference[@"buffer_length"],32u*1024u*1024u,&length)||!length||origin>UINT64_MAX-length||
       !pass_u64(reference[@"offset"],UINT64_MAX,&offset)||offset<origin||offset-origin>length||
       !pass_u64(reference[@"length"],length-(offset-origin),&viewLength)||!viewLength){[self reject:@"invalid native buffer root extent"];return nil;}
    if(root.buffer){if(root.bufferOrigin!=origin||root.bufferLength!=length){[self reject:@"native buffer allocation shape changed"];return nil;}return root;}
    if(self.allocatedBytes>self.maxBytes-self.payloadBytes||length>self.maxBytes-self.payloadBytes-self.allocatedBytes){[self reject:@"native buffer allocation budget"];return nil;}
    root.buffer=[self.device newBufferWithLength:(NSUInteger)length options:MTLResourceStorageModePrivate];
    if(!root.buffer||root.buffer.allocatedSize>self.maxBytes-self.payloadBytes-self.allocatedBytes){[self reject:@"native buffer allocation unavailable"];return nil;}
    self.allocatedBytes+=root.buffer.allocatedSize;[self.dirtyRoots addObject:root];root.bufferOrigin=origin;root.bufferLength=length;root.bufferDefined=[NSMutableIndexSet indexSet];return root;
}
/* BLIT destinations retain full private storage, independent of cached initial
 * textures. Preservation uses the active encoder; nested encoders are invalid. */
/* A first native write can target a one-mip attachment view before the source
 * ever samples its full chain. Higher levels outside that native allocation
 * have never been written by us: seed only those from the exact-version source
 * snapshot. Existing native levels, including undefined/discarded levels, must
 * never be overwritten or silently redefined by captured bytes. */
- (BOOL)extendWrittenTexture:(FFSTFrameRoot *)root snapshot:(const ff_texture_snapshot *)snapshot reference:(NSDictionary *)reference {
    id<MTLTexture> old=root.texture;NSUInteger first=old.mipmapLevelCount,levels=snapshot->mip_count;
    if(!root.written||!old||!first||levels<=first||old.textureType!=MTLTextureType2D||old.arrayLength!=1||old.sampleCount!=1||
       snapshot->texture_type!=MTLTextureType2D||snapshot->array_length!=1||old.pixelFormat!=snapshot->format||
       old.width!=snapshot->width||old.height!=snapshot->height||[reference[@"base_mip"] unsignedLongLongValue]||
       [reference[@"base_slice"] unsignedLongLongValue]||root.version!=[reference[@"input_content_version"] unsignedLongLongValue])return NO;
    NSMutableIndexSet *fresh=[NSMutableIndexSet indexSet];
    for(size_t i=0;i<snapshot->plane_count;++i){ff_texture_plane plane=snapshot->planes[i];
        if(plane.mip<first)continue;
        if(plane.slice||plane.mip>=levels||[fresh containsIndex:plane.mip])return NO;[fresh addIndex:plane.mip];}
    if(![fresh containsIndexesInRange:NSMakeRange(first,levels-first)]||![self ensureCommand])return NO;
    id<MTLTexture> expanded=[self allocateFormat:old.pixelFormat width:old.width height:old.height samples:1 mips:levels];
    if(!expanded)return NO;
    if(snapshot->length>self.maxBytes-self.allocatedBytes-self.payloadBytes)return NO;
    id<MTLBuffer> upload=[self.device newBufferWithBytes:snapshot->bytes length:snapshot->length options:MTLResourceStorageModeShared];
    if(!upload||upload.allocatedSize>self.maxBytes-self.allocatedBytes-self.payloadBytes)return NO;
    self.allocatedBytes+=upload.allocatedSize;
    id<MTLBlitCommandEncoder> copy=[self.command blitCommandEncoder];if(!copy)return NO;
    for(NSUInteger m=0;m<first;++m)if(frame_face_defined(root,1,m,0))
        [copy copyFromTexture:old sourceSlice:0 sourceLevel:m sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(MAX((NSUInteger)1,old.width>>m),MAX((NSUInteger)1,old.height>>m),1)
            toTexture:expanded destinationSlice:0 destinationLevel:m destinationOrigin:MTLOriginMake(0,0,0)];
    for(size_t i=0;i<snapshot->plane_count;++i){ff_texture_plane plane=snapshot->planes[i];if(plane.mip<first)continue;
        [copy copyFromBuffer:upload sourceOffset:plane.offset sourceBytesPerRow:plane.row_bytes sourceBytesPerImage:plane.length
            sourceSize:MTLSizeMake(MAX((NSUInteger)1,old.width>>plane.mip),MAX((NSUInteger)1,old.height>>plane.mip),1)
            toTexture:expanded destinationSlice:0 destinationLevel:plane.mip destinationOrigin:MTLOriginMake(0,0,0)];}
    [copy endEncoding];root.texture=expanded;[self.dirtyRoots addObject:root];frame_define_mips(root,1,NSMakeRange(first,levels-first),YES);
    ++self.initialMipCopies;return YES;
}
- (FFSTFrameRoot *)blitTexture:(NSDictionary *)reference encoder:(id<MTLBlitCommandEncoder>)encoder preimage:(BOOL)preimage {
    FFSTFrameRoot *root=[self root:reference];
    if(!root||root.kind!=FFS_TEXTURE||!frame_view_fields(reference))return nil;
    NSUInteger width=[reference[@"width"] unsignedIntegerValue],height=[reference[@"height"] unsignedIntegerValue];
    NSUInteger format=[reference[@"format"] unsignedIntegerValue],mips=[reference[@"mip_count"] unsignedIntegerValue],type=[reference[@"type"] unsignedIntegerValue];
    if(!root.texture){
        if(root.written){[self reject:@"native-written blit texture storage unavailable"];return nil;}
        /* A complete preimage can replace an unavailable smaller cached donor.
         * A larger known chain still needs preservation beyond this view. */
        BOOL seedFromImport=preimage&&mips>=root.initialMipCount;
        id<MTLTexture> donor=seedFromImport?nil:root.initialTexture;
        NSUInteger levels=MAX(mips,root.initialMipCount);
        if(!seedFromImport&&root.initialMipCount&&(!donor||root.initialTextureVersion!=root.version||
            donor.device.registryID!=self.device.registryID||donor.pixelFormat!=format||donor.textureType!=type||
            donor.width!=width||donor.height!=height||donor.sampleCount!=1||donor.arrayLength!=1||donor.mipmapLevelCount!=levels)){
            [self reject:@"initial blit texture mip chain unavailable"];return nil;}
        if(type==MTLTextureTypeCube){uint64_t estimate=0;
            for(NSUInteger m=0;m<levels;++m)estimate+=(uint64_t)MAX((NSUInteger)1,width>>m)*MAX((NSUInteger)1,height>>m)*16*6;
            if(self.payloadBytes>self.maxBytes-self.allocatedBytes||estimate>self.maxBytes-self.allocatedBytes-self.payloadBytes){[self reject:@"native cube allocation budget"];return nil;}
            MTLTextureDescriptor *d=[MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:format size:width mipmapped:NO];
            d.mipmapLevelCount=levels;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
            root.texture=[self.device newTextureWithDescriptor:d];
            if(!root.texture||root.texture.allocatedSize>self.maxBytes-self.allocatedBytes-self.payloadBytes){[self reject:@"native cube allocation unavailable"];return nil;}
            self.allocatedBytes+=root.texture.allocatedSize;
        }else root.texture=[self allocateFormat:format width:width height:height samples:1 mips:levels];
        if(!root.texture)return nil;[self.dirtyRoots addObject:root];
        if(donor){
            for(NSUInteger slice=0;slice<(type==MTLTextureTypeCube?6u:1u);++slice)for(NSUInteger m=0;m<levels;++m)[encoder copyFromTexture:donor sourceSlice:slice sourceLevel:m sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(MAX((NSUInteger)1,width>>m),MAX((NSUInteger)1,height>>m),1)
                toTexture:root.texture destinationSlice:slice destinationLevel:m destinationOrigin:MTLOriginMake(0,0,0)];
            root.initialized=YES;frame_define_mips(root,1,NSMakeRange(0,levels),YES);++self.initialMipCopies;
        }
    }
    if(!frame_native_view(root,reference)){[self reject:@"blit destination view differs from native storage"];return nil;}
    return root;
}
- (BOOL)stageBufferReadbacks {
    if(!self.bufferReadbackRequests.count)return YES;
    if(![self ensureCommand])return NO;
    id<MTLBlitCommandEncoder> encoder=[self.command blitCommandEncoder];
    if(!encoder)return [self reject:@"native readback encoder unavailable"];
    if(!self.bufferReadbackStaging)self.bufferReadbackStaging=[NSMutableArray array];
    for(NSDictionary *request in self.bufferReadbackRequests){
        FFSTFrameRoot *root=request[@"root"];FFSTNativeBufferReadback *result=request[@"result"];
        uint64_t length=result.rowLength*result.rowCount,offset=result.offset-root.bufferOrigin;
        if((offset|result.rowBytes|result.rowLength)&3){[encoder endEncoding];return [self reject:@"native readback staging requires four-byte alignment"];}
        if(self.payloadBytes>self.maxBytes||self.allocatedBytes>self.maxBytes-self.payloadBytes){
            [encoder endEncoding];return [self reject:@"native buffer readback budget exhausted"];}
        uint64_t remaining=self.maxBytes-self.payloadBytes-self.allocatedBytes;
        if(length>remaining/2){[encoder endEncoding];return [self reject:@"native buffer readback ownership budget exhausted"];}
        id<MTLBuffer> staging=[self.device newBufferWithLength:(NSUInteger)length options:MTLResourceStorageModeShared];
        /* Charge both shared GPU staging and the independent returned NSData. */
        if(!staging||staging.allocatedSize>remaining||length>remaining-staging.allocatedSize){
            [encoder endEncoding];return [self reject:@"native buffer readback budget or allocation failed"];}
        self.allocatedBytes+=staging.allocatedSize+length;
        for(uint64_t row=0;row<result.rowCount;++row){NSUInteger source=(NSUInteger)(offset+row*result.rowBytes);
            if(![root.bufferDefined containsIndexesInRange:NSMakeRange(source,(NSUInteger)result.rowLength)]){
                [encoder endEncoding];return [self reject:@"native readback row became undefined"];}
            [encoder copyFromBuffer:root.buffer sourceOffset:source toBuffer:staging
                destinationOffset:(NSUInteger)(row*result.rowLength) size:(NSUInteger)result.rowLength];
        }
        result.contentVersion=root.version;
        [self.bufferReadbackStaging addObject:@{@"result":result,@"buffer":staging}];
    }
    [encoder endEncoding];[self.bufferReadbackRequests removeAllObjects];return YES;
}
- (NSArray<FFSTNativeBufferReadback *> *)completedBufferReadbacks {
    if(!self.committed||!self.retired||self.failure){[self reject:@"native readback requested before GPU retirement"];return nil;}
    NSMutableArray *results=[NSMutableArray arrayWithCapacity:self.bufferReadbackStaging.count];
    for(NSDictionary *entry in self.bufferReadbackStaging){FFSTNativeBufferReadback *result=entry[@"result"];id<MTLBuffer> staging=entry[@"buffer"];
        NSUInteger length=(NSUInteger)(result.rowLength*result.rowCount);
        if(!staging.contents||length>staging.length){[self reject:@"native readback staging unavailable"];return nil;}
        result.bytes=[[NSData alloc]initWithBytes:staging.contents length:length];
        if(!result.bytes||result.bytes.length!=length){[self reject:@"native readback ownership failed"];return nil;}
        [results addObject:result];
    }
    return [results copy];
}
#include "live_command_native.inc"
- (BOOL)operation:(const ffs_record *)begin resources:(NSArray<NSData *> *)resourceRecords commands:(NSArray<NSData *> *)commands dependencies:(NSArray<NSData *> *)dependencies {
    if(![self.request.payloads respondsToSelector:@selector(operationPayload:stream:frame:failure:)])return [self reject:@"native operation payload provider unavailable"];
    NSString *failure=nil;FFSTNativeFrameOperationPayload *payload=[self.request.payloads operationPayload:begin->data[4] stream:begin->stream frame:begin->frame failure:&failure];
    if(!payload)return [self reject:failure?:@"native operation payload missing"];
    if(live_native_enabled()){if(![payload.bindings[@"format"]isEqual:@"bedrock-live-commands"])return [self reject:@"live operation capture fallback forbidden"];return [self liveExecute:payload.bindings blobs:payload.blobs begin:begin resources:resourceRecords commands:commands];}
    NSDictionary *sidecar=payload.bindings;uint64_t device,category;
    if(!pass_u64(sidecar[@"category"],FFS_CATEGORY_COUNT-1,&category)||category!=begin->data[0])return [self reject:@"operation category differs from ledger"];
    if(!pass_u64(sidecar[@"device_id"],UINT64_MAX,&device)||![self selectDevice:device]||
       ![self coverage:sidecar begin:begin resources:resourceRecords commands:commands render:NO]||![self ensureCommand])return NO;
    if(self.payloadBytes>self.maxBytes-self.allocatedBytes)return [self reject:@"native operation byte budget"];
    self.ownedBlobs=payload.ownedBlobs;
    FFSTNativeFrameOperations *decoded=payload.ownedBlobs?ffst_native_frame_operations_load_owned(payload.ownedBlobs,sidecar,self.maxBytes-self.payloadBytes-self.allocatedBytes,&failure):
        payload.blobs?ffst_native_frame_operations_load_blobs(payload.blobs,sidecar,self.maxBytes-self.payloadBytes-self.allocatedBytes,&failure):ffst_native_frame_operations_load(payload.directory,sidecar,self.maxBytes-self.payloadBytes-self.allocatedBytes,&failure);
    if(!decoded)return [self reject:failure?:@"native operation payload malformed"];
    if(decoded.importedBytes>self.request.retainedBytes-self.request.records.length||self.payloadBytes>self.request.retainedBytes-self.request.records.length-decoded.importedBytes)return [self reject:@"operation reservation understated"];
    self.payloadBytes+=decoded.importedBytes;NSArray *resources=sidecar[@"resources"];
    if(begin->data[0]==FFS_BLIT){
        for(NSDictionary *reference in resources)if([reference[@"kind"] unsignedIntValue]==FFS_BUFFER&&![self buffer:reference])return NO;
        id<MTLBlitCommandEncoder> encoder=[self.command blitCommandEncoder];if(!encoder)return [self reject:@"native buffer blit encoder unavailable"];
        NSMutableSet *preimageRoots=[NSMutableSet set];
        for(NSNumber *index in decoded.textureImports)[preimageRoots addObject:frame_root_key(resources[index.unsignedIntegerValue])];
        NSMutableDictionary<NSData *,NSDictionary *> *mustDefine=[NSMutableDictionary new];
        for(NSDictionary *operation in decoded.operations)if([operation[@"op"] isEqual:@"copy_texture_to_texture"]){
            NSDictionary *r=resources[[operation[@"destination_resource"] unsignedIntegerValue]];NSData *key=frame_root_key(r);FFSTFrameRoot *root=[self root:r];
            if(!root.written&&!root.initialized&&![preimageRoots containsObject:key])mustDefine[key]=r;}
        for(NSDictionary *reference in resources)if([reference[@"kind"] unsignedIntValue]==FFS_TEXTURE&&
            ![self blitTexture:reference encoder:encoder preimage:[preimageRoots containsObject:frame_root_key(reference)]]){
            [encoder endEncoding];return [self reject:self.failure?:@"native blit texture allocation unavailable"];}
        for(NSNumber *index in decoded.bufferImports){NSDictionary *reference=resources[index.unsignedIntegerValue];FFSTFrameRoot *root=[self root:reference];NSData *bytes=decoded.bufferImports[index];
            uint64_t offset=[reference[@"offset"] unsignedLongLongValue]-root.bufferOrigin;
            if(root.written){
                if(![root.bufferDefined containsIndexesInRange:NSMakeRange((NSUInteger)offset,bytes.length)]){
                    [encoder endEncoding];return [self reject:@"captured bytes cannot supply an undefined earlier native buffer range"];}
                continue;
            }
            if(![self initialBytes:bytes.bytes length:bytes.length reference:reference offset:[reference[@"offset"] unsignedLongLongValue]]){[encoder endEncoding];return NO;}
            NSData<FFSTSharedSnapshotMemory> *shared=[self.ownedBlobs verifiedSharedSnapshotForBytes:bytes.bytes length:bytes.length];
            id<MTLBuffer> upload=shared?[self wrapSharedSnapshot:shared]:
                [self.device newBufferWithBytes:bytes.bytes length:bytes.length options:MTLResourceStorageModeShared];
            if(!upload||(!shared&&upload.allocatedSize>self.maxBytes-self.payloadBytes-self.allocatedBytes)){
                [encoder endEncoding];return [self reject:self.failure?:@"native buffer import upload unavailable"];}
            if(!shared)self.allocatedBytes+=upload.allocatedSize;
            [encoder copyFromBuffer:upload sourceOffset:0 toBuffer:root.buffer destinationOffset:(NSUInteger)offset size:bytes.length];
            [root.bufferDefined addIndexesInRange:NSMakeRange((NSUInteger)offset,bytes.length)];
        }
        /* Seed each new destination once, before any original upload commands.
         * Existing native writes always win over stale captured preimages. */
        for(NSNumber *index in decoded.textureImports){NSDictionary *reference=resources[index.unsignedIntegerValue];FFSTFrameRoot *root=[self root:reference];
            NSDictionary *entry=decoded.textureImports[index],*metadata=entry[@"metadata"];NSData *bytes=entry[@"bytes"];
            if(![self.resourceIndex containsReference:reference flags:FFS_READ]){[encoder endEncoding];return [self reject:@"texture preimage lacks a read dependency"];}
            if(root.written)continue;
            if(![self initialBytes:bytes.bytes length:bytes.length reference:reference offset:0]){[encoder endEncoding];return NO;}
            if(root.initialized)continue;
            id<MTLBuffer> upload=[self.device newBufferWithBytes:bytes.bytes length:bytes.length options:MTLResourceStorageModeShared];
            if(!upload||upload.allocatedSize>self.maxBytes-self.payloadBytes-self.allocatedBytes){[encoder endEncoding];return [self reject:@"native texture preimage upload unavailable"];}
            self.allocatedBytes+=upload.allocatedSize;
            for(NSDictionary *plane in metadata[@"planes"]){NSUInteger m=[plane[@"mip"] unsignedIntegerValue];
                [encoder copyFromBuffer:upload sourceOffset:[plane[@"offset"] unsignedIntegerValue]
                    sourceBytesPerRow:[plane[@"row_bytes"] unsignedIntegerValue] sourceBytesPerImage:[plane[@"length"] unsignedIntegerValue]
                    sourceSize:MTLSizeMake(MAX((NSUInteger)1,root.texture.width>>m),MAX((NSUInteger)1,root.texture.height>>m),1)
                    toTexture:root.texture destinationSlice:[plane[@"slice"] unsignedIntegerValue] destinationLevel:m destinationOrigin:MTLOriginMake(0,0,0)];
            }
            frame_define_mips(root,1,NSMakeRange(0,[metadata[@"mip_count"] unsignedIntegerValue]),YES);root.initialized=YES;
        }
        for(NSUInteger operationIndex=0;operationIndex<decoded.operations.count;++operationIndex){
            NSDictionary *operation=decoded.operations[operationIndex];if([operation[@"op"] isEqual:@"nop"])continue;
            NSDictionary *source=resources[[operation[@"source_resource"] unsignedIntegerValue]],*destination=resources[[operation[@"destination_resource"] unsignedIntegerValue]];
            if(![self.resourceIndex containsReference:source flags:FFS_READ]||![self.resourceIndex containsReference:destination flags:FFS_WRITE]){[encoder endEncoding];return [self reject:@"copy lacks read/write dependency"];}
            FFSTFrameRoot *src=[self root:source],*dst=[self root:destination];
            if([operation[@"op"] isEqual:@"copy_texture_to_texture"]){
                if(![self.resourceIndex containsReference:destination flags:FFS_READ|FFS_WRITE]){
                    [encoder endEncoding];return [self reject:@"texture copy destination lacks read/write dependency"];}
                if(src.texture==dst.texture){[encoder endEncoding];return [self reject:@"Aliased native texture copy is unsupported"];}
                NSArray *size=operation[@"source_size"],*from=operation[@"source_origin"],*to=operation[@"destination_origin"];
                NSUInteger sourceLevel=[operation[@"source_level"] unsignedIntegerValue],destinationLevel=[operation[@"destination_level"] unsignedIntegerValue];
                NSUInteger sourceSlice=[operation[@"source_slice"] unsignedIntegerValue],destinationSlice=[operation[@"destination_slice"] unsignedIntegerValue];
                NSUInteger width=[size[0] unsignedIntegerValue],height=[size[1] unsignedIntegerValue],
                    x=[to[0] unsignedIntegerValue],y=[to[1] unsignedIntegerValue];
                BOOL full=!x&&!y&&width==MAX((NSUInteger)1,dst.texture.width>>destinationLevel)&&height==MAX((NSUInteger)1,dst.texture.height>>destinationLevel);
                if(!frame_face_defined(src,1,sourceLevel,sourceSlice)){[encoder endEncoding];return [self reject:@"texture copy source mip is undefined"];}
                if(!full&&!frame_face_defined(dst,1,destinationLevel,destinationSlice)){[encoder endEncoding];return [self reject:@"partial texture copy requires a defined destination mip"];}
                [encoder copyFromTexture:src.texture sourceSlice:sourceSlice sourceLevel:sourceLevel
                    sourceOrigin:MTLOriginMake([from[0] unsignedIntegerValue],[from[1] unsignedIntegerValue],0)
                    sourceSize:MTLSizeMake(width,height,1) toTexture:dst.texture destinationSlice:destinationSlice destinationLevel:destinationLevel
                    destinationOrigin:MTLOriginMake(x,y,0)];
                if(full)frame_define_face(dst,1,destinationLevel,destinationSlice);dst.initialized=YES;continue;
            }
            if([operation[@"op"] isEqual:@"copy_texture_to_buffer"]){
                if(![self.resourceIndex containsReference:destination flags:FFS_READ|FFS_WRITE]){
                    [encoder endEncoding];return [self reject:@"texture readback destination lacks read/write dependency"];}
                NSArray *size=operation[@"source_size"],*origin=operation[@"source_origin"];
                NSUInteger width=[size[0] unsignedIntegerValue],height=[size[1] unsignedIntegerValue],level=[operation[@"source_level"] unsignedIntegerValue];
                NSUInteger rowBytes=[operation[@"destination_bytes_per_row"] unsignedIntegerValue],tight=width*ff_texture_pixel_size((uint32_t)src.texture.pixelFormat);
                uint64_t packed=(uint64_t)tight*height;
                if(![src.definedMips[@1] containsIndex:level]){[encoder endEncoding];return [self reject:@"texture readback source mip is undefined"];}
                if(self.bufferReadbackRequests.count+self.bufferReadbackStaging.count>=FFST_NATIVE_READBACK_MAX_RANGES||
                    packed>FFST_NATIVE_READBACK_MAX_BYTES-self.readbackBytes){[encoder endEncoding];return [self reject:@"native buffer readback output exceeds its bound"];}
                NSUInteger destinationOffset=(NSUInteger)([destination[@"offset"] unsignedLongLongValue]-dst.bufferOrigin)+[operation[@"destination_offset"] unsignedIntegerValue];
                [encoder copyFromTexture:src.texture sourceSlice:0 sourceLevel:level
                    sourceOrigin:MTLOriginMake([origin[0] unsignedIntegerValue],[origin[1] unsignedIntegerValue],0)
                    sourceSize:MTLSizeMake(width,height,1) toBuffer:dst.buffer destinationOffset:destinationOffset
                    destinationBytesPerRow:rowBytes destinationBytesPerImage:[operation[@"destination_bytes_per_image"] unsignedIntegerValue]];
                for(NSUInteger row=0;row<height;++row)[dst.bufferDefined addIndexesInRange:NSMakeRange(destinationOffset+row*rowBytes,tight)];
                FFSTNativeBufferReadback *result=[FFSTNativeBufferReadback new];
                result.chunk=begin->chunk;result.encoder=begin->encoder;result.command=(uint32_t)operationIndex;
                result.root=dst.root;result.generation=dst.generation;
                result.offset=[destination[@"offset"] unsignedLongLongValue]+[operation[@"destination_offset"] unsignedLongLongValue];
                result.rowBytes=rowBytes;result.rowLength=tight;result.rowCount=height;
                if(!self.bufferReadbackRequests)self.bufferReadbackRequests=[NSMutableArray array];
                [self.bufferReadbackRequests addObject:@{@"root":dst,@"result":result}];self.readbackBytes+=packed;continue;
            }
            NSUInteger sourceOffset=(NSUInteger)([source[@"offset"] unsignedLongLongValue]-src.bufferOrigin)+[operation[@"source_offset"] unsignedIntegerValue];
            if([operation[@"op"] isEqual:@"copy_buffer_to_texture"]){
                NSArray *size=operation[@"source_size"],*origin=operation[@"destination_origin"];
                NSUInteger width=[size[0] unsignedIntegerValue],height=[size[1] unsignedIntegerValue];
                NSUInteger x=[origin[0] unsignedIntegerValue],y=[origin[1] unsignedIntegerValue],level=[operation[@"destination_level"] unsignedIntegerValue];
                NSUInteger row=[operation[@"source_bytes_per_row"] unsignedIntegerValue],tight=width*ff_texture_pixel_size((uint32_t)dst.texture.pixelFormat);
                BOOL full=!x&&!y&&width==MAX((NSUInteger)1,dst.texture.width>>level)&&height==MAX((NSUInteger)1,dst.texture.height>>level);
                if(!full&&![dst.definedMips[@1] containsIndex:level]){[encoder endEncoding];return [self reject:@"partial upload requires a defined native texture mip"];}
                for(NSUInteger iy=0;iy<height;++iy)if(![src.bufferDefined containsIndexesInRange:NSMakeRange(sourceOffset+iy*row,tight)]){
                    [encoder endEncoding];return [self reject:@"texture upload reads an undefined native buffer row"];}
                [encoder copyFromBuffer:src.buffer sourceOffset:sourceOffset sourceBytesPerRow:row
                    sourceBytesPerImage:[operation[@"source_bytes_per_image"] unsignedIntegerValue]
                    sourceSize:MTLSizeMake(width,height,1) toTexture:dst.texture destinationSlice:0 destinationLevel:level destinationOrigin:MTLOriginMake(x,y,0)];
                if(full)frame_define_mips(dst,1,NSMakeRange(level,1),YES);
                dst.initialized=YES;self.textureUploadBytes+=(uint64_t)tight*height;continue;
            }
            NSUInteger length=[operation[@"length"] unsignedIntegerValue];
            NSUInteger destinationOffset=(NSUInteger)([destination[@"offset"] unsignedLongLongValue]-dst.bufferOrigin)+[operation[@"destination_offset"] unsignedIntegerValue];
            if(![src.bufferDefined containsIndexesInRange:NSMakeRange(sourceOffset,length)]){[encoder endEncoding];return [self reject:@"copy reads an undefined native buffer range"];}
            [encoder copyFromBuffer:src.buffer sourceOffset:sourceOffset toBuffer:dst.buffer destinationOffset:destinationOffset size:length];
            [dst.bufferDefined addIndexesInRange:NSMakeRange(destinationOffset,length)];self.copyBytes+=length;
        }
        for(NSData *key in mustDefine)if(!frame_view_defined(self.roots[key],mustDefine[key],1)){
            [encoder endEncoding];return [self reject:@"texture copy omitted preimage without full subresource coverage"];}
        [encoder endEncoding];NSMutableDictionary *versions=[NSMutableDictionary dictionary];
        for(NSUInteger i=0;i<resources.count;++i){const ffs_record *record=resourceRecords[i].bytes;if(!(record->flags&FFS_WRITE))continue;
            NSData *key=frame_root_key(resources[i]);NSNumber *version=@(record->data[8]);if(versions[key]&&![versions[key] isEqual:version])return [self reject:@"blit alias output versions disagree"];versions[key]=version;}
        for(NSData *key in versions){self.roots[key].version=[versions[key] unsignedLongLongValue];self.roots[key].written=YES;}
    }else if(begin->data[0]==FFS_TIMESTAMP){
        NSDictionary *operation=decoded.operations[0];[self.timestampRequests addObject:@{@"chunk":@(begin->chunk),@"readback_index":operation[@"readback_index"],@"query_count":operation[@"query_count"],@"command":self.command}];
    }else if(begin->data[0]==FFS_SIGNAL_EVENT){
        NSDictionary *operation=decoded.operations[0];BOOL matches=NO;
        for(NSData *data in dependencies){const ffs_record *record=data.bytes;
            if(record->data[0]==[operation[@"domain"] unsignedLongLongValue]&&record->data[1]==[operation[@"id"] unsignedLongLongValue]&&
               record->data[2]==[operation[@"value"] unsignedLongLongValue]&&record->data[4]==FFS_SIGNAL)matches=YES;}
        if(!matches||dependencies.count!=1)return [self reject:@"native event signal differs from ledger"];
        NSString *key=[NSString stringWithFormat:@"%@:%@",operation[@"domain"],operation[@"id"]];id<MTLSharedEvent> event=self.events[key];
        if(!event){if(self.events.count>=FFS_MAX_DEPENDENCIES)return [self reject:@"native shared event identity limit"];
            event=[self.device newSharedEvent];if(!event)return [self reject:@"native shared event unavailable"];self.events[key]=event;}
        [self.command encodeSignalEvent:event value:[operation[@"value"] unsignedLongLongValue]];
        [self.signalRequests addObject:@{@"domain":operation[@"domain"],@"id":operation[@"id"],@"value":operation[@"value"],@"event":event}];
    }else return [self reject:@"native auxiliary category unsupported"];
    self.operationCount++;return YES;
}
- (BOOL)render:(const ffs_record *)begin resources:(NSArray<NSData *> *)resourceRecords commands:(NSArray<NSData *> *)commands {
#define RFAIL(reason) return [self reject:@reason]
    uint64_t profileStarted=frame_monotonic_ns();
    BOOL utility=begin->data[0]==FFS_CLEAR||begin->data[0]==FFS_RESOLVE,resolving=begin->data[0]==FFS_RESOLVE;
    if(self.cancelled&&self.cancelled())RFAIL("native frame cancelled before render");
    NSString *failure=nil;FFSTNativeFramePassPayload *payload=[self.request.payloads renderPayload:begin->data[4] stream:begin->stream frame:begin->frame failure:&failure];
    if(!payload)return [self reject:failure?:@"frame render payload unavailable"];
    if(live_native_enabled()){if(![payload.bindings[@"format"]isEqual:@"bedrock-live-commands"])return [self reject:@"live capture fallback forbidden"];return [self liveExecute:payload.bindings blobs:payload.blobs begin:begin resources:resourceRecords commands:commands];}
    self.ownedBlobs=payload.ownedBlobs;
    NSDictionary *manifest=payload.manifest,*sidecar=payload.bindings,*a=manifest[@"attachments"];
    if(![self coverage:sidecar begin:begin resources:resourceRecords commands:commands render:YES])return NO;
    uint64_t width,height,samples,format,depthFormat,stencilFormat,value,registry;
    if(!pass_record(a)||!pass_u64(a[@"width"],8192,&width)||!width||!pass_u64(a[@"height"],8192,&height)||!height||
       !pass_u64(a[@"device_id"],UINT64_MAX,&registry)||!registry||!pass_u64(a[@"samples"],8,&samples)||
       !pass_u64(a[@"pixel_format"],UINT32_MAX,&format)||(format?!ffst_attachment_format_supported(format,FFST_COLOR):!utility)||
       !pass_u64(a[@"depth_format"],UINT32_MAX,&depthFormat)||(depthFormat&&!ffst_attachment_format_supported(depthFormat,FFST_DEPTH))||
       !pass_u64(a[@"stencil_format"],UINT32_MAX,&stencilFormat)||(stencilFormat&&!ffst_attachment_format_supported(stencilFormat,FFST_STENCIL)))RFAIL("invalid native frame attachment descriptor");
    if(!self.device){for(id<MTLDevice> device in MTLCopyAllDevices())if(device.registryID==registry){self.device=device;break;}}
    if(!self.device||self.device.registryID!=registry||!ffst_sample_count_supported(self.device,samples))RFAIL("frame device/sample mismatch");
    if(![self ensureCommand])return NO;
    uint64_t loads[3];NSArray *loadKeys=@[@"color_load",@"depth_load",@"stencil_load"];
    for(unsigned i=0;i<3;++i)if(!pass_u64(a[loadKeys[i]],MTLLoadActionClear,&loads[i]))RFAIL("invalid frame load action");
    uint64_t stores[3];NSArray *storeKeys=@[@"color_store",@"depth_store",@"stencil_store"];
    for(unsigned i=0;i<3;++i)if(!pass_u64(a[storeKeys[i]],MTLStoreActionStoreAndMultisampleResolve,&stores[i])||stores[i]==MTLStoreActionUnknown)RFAIL("invalid frame store action");
    BOOL alias,complete;
    if(!pass_bool(a[@"depth_stencil_alias"],&alias)||!pass_bool(manifest[@"complete_pass"],&complete)||!complete||
       !pass_numbers(a[@"clear"],4)||![a[@"depth_clear"] isKindOfClass:[NSNumber class]]||!isfinite([a[@"depth_clear"] doubleValue])||
       [a[@"depth_clear"] doubleValue]<0||[a[@"depth_clear"] doubleValue]>1||!pass_u64(a[@"stencil_clear"],255,&value)||
       (alias&&(!depthFormat||depthFormat!=stencilFormat))||(!format&&!depthFormat&&!stencilFormat))RFAIL("invalid whole-pass attachment state");
    NSArray *drawRecords=manifest[@"draws"],*pipelineRecords=manifest[@"pipelines"],*resources=sidecar[@"resources"];
    if(![drawRecords isKindOfClass:[NSArray class]]||drawRecords.count>FFST_PASS_DRAW_LIMIT||
       ![pipelineRecords isKindOfClass:[NSArray class]]||pipelineRecords.count>FFST_PASS_DRAW_LIMIT||
       (utility?(drawRecords.count||pipelineRecords.count||commands.count):(!drawRecords.count||!pipelineRecords.count)))RFAIL("invalid frame pass draw count");
    NSUInteger coveredDraws=0;for(NSNumber *type in sidecar[@"command_types"])if(frame_draw_command(type.unsignedLongLongValue))++coveredDraws;
    if(coveredDraws!=drawRecords.count)RFAIL("frame command/draw coverage mismatch");
    frame_profile_mark(renderProfileNs,FFST_PROFILE_COVERAGE,&profileStarted);
    NSData *graphData=pass_payload_read(payload.directory,payload.blobs,"draw-resource-cut.json",8u*1024u*1024u);
    NSDictionary *graph=payload.ownedBlobs?[payload.ownedBlobs jsonDictionary:@"draw-resource-cut.json"]:
        graphData?[NSJSONSerialization JSONObjectWithData:graphData options:0 error:nil]:nil;
    BOOL typedGraph=[graph[@"version"] isEqual:@3];
    BOOL direct=[graph[@"direct_pass"] boolValue];
    if((direct&&!ffjp_enabled())||(ffjp_enabled()&&!utility&&!direct))RFAIL("direct pass requires complete replacement; legacy fallback forbidden");
    if(!pass_record(graph)||![graph[@"format"] isEqual:@"bedrock-draw-resource-cut"]||
       (![graph[@"version"] isEqual:@2]&&!typedGraph)||
       ![graph[@"cut_id"] isEqual:manifest[@"resource_cut_id"]]||![graph[@"complete_pass"] boolValue])RFAIL("frame resource cut is incomplete");
    FFSTFrameRenderContext *context=[FFSTFrameRenderContext new];
    if(utility){
        for(NSString *name in payload.blobs)if(ff_native_buffer_ref_index(name))RFAIL("utility payload contains native buffer marker");
        if(typedGraph){NSData *wire=payload.ownedBlobs.blobs[@"draw-resource-cut.bin"];ffmd_view view;
            if(!wire||!ffmd_view_decode(wire.bytes,wire.length,FFMD_GRAPH,&view)||
               view.sections[0].count||view.sections[1].count||view.sections[4].count||view.sections[6].count)
                RFAIL("utility payload contains unexpected typed draw assets");}
        else for(NSString *key in @[@"snapshots",@"textures",@"samplers",@"draws"])
            if(![graph[key] isKindOfClass:[NSArray class]]||[graph[key] count])RFAIL("utility payload contains unexpected draw assets");}
    else if(direct)context.direct=ffdp_decode(payload.blobs);
    else context.decoded=payload.ownedBlobs?ffst_pass_resources_load_owned(payload.ownedBlobs):
        payload.blobs?ffst_pass_resources_load_blobs(payload.blobs):ffst_pass_resources_load(payload.directory,graph);
    if((!utility&&!(direct?context.direct!=nil:context.decoded!=NULL))||(direct?context.direct->nd:ffst_pass_resources_draw_count(context.decoded))!=drawRecords.count||
       !pass_u64(manifest[@"captured_prefix_draws"],FFST_PASS_DRAW_LIMIT,&value)||value!=drawRecords.count)RFAIL("frame pass/cut draw mismatch");
    frame_profile_mark(renderProfileNs,FFST_PROFILE_DECODE,&profileStarted);
    [self.contexts addObject:context];size_t ns,nt,nsa;
    const ff_vertex_snapshot *snapshots=direct?context.direct->buffers:ffst_pass_resources_snapshots(context.decoded,&ns);
    const ff_texture_snapshot *textures=direct?context.direct->textures:ffst_pass_resources_textures(context.decoded,&nt);
    const ff_sampler_snapshot *samplers=direct?context.direct->samplers:ffst_pass_resources_samplers(context.decoded,&nsa);
    if(direct){ns=context.direct->nb;nt=context.direct->nt;nsa=context.direct->ns;}
    NSData *directReplay=direct?payload.blobs[@"replay.json"]:nil;pr_header directHeader={0};
    const uint8_t *directRows=NULL;NSArray *directDepths=manifest[PR_DEPTH_KEY];
    if(direct){if(directReplay.length<sizeof(directHeader))RFAIL("direct command rows missing");memcpy(&directHeader,directReplay.bytes,sizeof(directHeader));
      if(directHeader.magic!=PR_MAGIC||directHeader.version!=1||directHeader.total!=directReplay.length||directHeader.rows!=drawRecords.count||directHeader.row_bytes!=sizeof(pr_row)||directHeader.header_bytes>directReplay.length-sizeof(directHeader)||(uint64_t)directHeader.rows*sizeof(pr_row)!=directReplay.length-sizeof(directHeader)-directHeader.header_bytes)RFAIL("direct command extent mismatch");
      directRows=(const uint8_t*)directReplay.bytes+sizeof(directHeader)+directHeader.header_bytes;
    }
    NSArray *snapshotRefs=sidecar[@"snapshots"],*textureRefs=sidecar[@"textures"],*attachmentRefs=sidecar[@"attachments"];
    if(![snapshotRefs isKindOfClass:[NSArray class]]||snapshotRefs.count!=ns||![textureRefs isKindOfClass:[NSArray class]]||textureRefs.count!=nt||
       ![attachmentRefs isKindOfClass:[NSArray class]]||!attachmentRefs.count||attachmentRefs.count>4)RFAIL("frame logical binding count mismatch");
    NSMutableSet *writtenRoots=[NSMutableSet set];NSMutableDictionary *roles=[NSMutableDictionary dictionary];
    for(NSDictionary *reference in attachmentRefs){NSString *role=reference[@"role"];
        BOOL resolveSource=resolving&&[role isEqual:@"color"];
        if(![@[@"color",@"color_resolve",@"depth",@"stencil"] containsObject:role]||roles[role]||![self.resourceIndex containsReference:reference flags:resolveSource?FFS_READ:FFS_WRITE]||
           !pass_u64(reference[@"index"],0,&value)||!pass_u64(reference[@"level"],0,&value)||!pass_u64(reference[@"slice"],0,&value)||!pass_u64(reference[@"depth_plane"],0,&value))RFAIL("unsupported frame attachment mapping");
        if(resolveSource&&![reference[@"input_content_version"] isEqual:reference[@"output_content_version"]])RFAIL("resolve source content version changes");
        roles[role]=reference;if(!resolveSource)[writtenRoots addObject:frame_root_key(reference)];}
    if((format!=0)!=(roles[@"color"]!=nil)||(depthFormat!=0)!=(roles[@"depth"]!=nil)||(stencilFormat!=0)!=(roles[@"stencil"]!=nil)||
       (roles[@"color_resolve"]&&(!format||samples==1)))RFAIL("frame attachment role mismatch");
    if(resolving&&(!roles[@"color_resolve"]||loads[0]!=MTLLoadActionLoad||depthFormat||stencilFormat))RFAIL("unsupported standalone resolve descriptor");
    if(resolving&&stores[0]!=MTLStoreActionMultisampleResolve&&stores[0]!=MTLStoreActionStoreAndMultisampleResolve)RFAIL("resolve payload lacks resolve store action");
    if(utility&&!resolving&&!((format&&loads[0]==MTLLoadActionClear)||(depthFormat&&loads[1]==MTLLoadActionClear)||(stencilFormat&&loads[2]==MTLLoadActionClear)))RFAIL("clear payload clears no attachment");
    if((roles[@"color_resolve"]!=nil)!=(format&&(stores[0]==MTLStoreActionMultisampleResolve||stores[0]==MTLStoreActionStoreAndMultisampleResolve)))RFAIL("frame resolve target/store mismatch");
    if((depthFormat&&stores[1]>MTLStoreActionStore)||(stencilFormat&&stores[2]>MTLStoreActionStore))RFAIL("depth/stencil resolve store unsupported");
    NSArray *loadRoles=@[@"color",@"depth",@"stencil"];
    for(unsigned i=0;i<3;++i)if(roles[loadRoles[i]]&&loads[i]==MTLLoadActionLoad&&
        ![self.resourceIndex containsReference:roles[loadRoles[i]] flags:(resolving&&i==0)?FFS_READ:(FFS_READ|FFS_WRITE)])RFAIL("frame Load lacks declared read dependency");
    for(NSUInteger i=0;i<resources.count;++i){const ffs_record *record=resourceRecords[i].bytes;
        if((record->flags&FFS_WRITE)&&![writtenRoots containsObject:frame_root_key(resources[i])])RFAIL("frame shader/buffer write unsupported");}
    uint64_t retained=graphData.length;ff_native_texture_override overrides[FF_TEXTURE_RESOURCE_LIMIT]={0};size_t overrideCount=0;
    ff_native_buffer_override bufferOverrides[FF_DRAW_RESOURCE_LIMIT]={0};size_t bufferOverrideCount=0;
    for(size_t i=0;i<ns;++i){NSDictionary *reference=snapshotRefs[i];
        if(!pass_u64(reference[@"id"],ns,&value)||value!=i+1||[reference[@"kind"] unsignedIntValue]!=FFS_BUFFER||
           ![self.resourceIndex containsReference:reference flags:FFS_READ]||![self root:reference])RFAIL("frame buffer snapshot identity mismatch");
        uint64_t offset=0;NSDictionary *source=typedGraph?nil:graph[@"snapshots"][i];
        ffmd_graph_snapshot directSnapshot={0};if(direct&&!ffmd_view_row(&context.direct->wire,0,i,&directSnapshot,sizeof(directSnapshot)))RFAIL("direct buffer extent absent");
        if(direct)offset=directSnapshot.source_offset;
        if(!direct&&!(typedGraph?ffst_pass_resources_snapshot_source_offset(context.decoded,i,&offset):
             pass_u64(source[@"source_offset"],UINT64_MAX,&offset)))RFAIL("frame buffer source range missing");
        uint64_t beginOffset=[reference[@"offset"] unsignedLongLongValue],logicalLength=[reference[@"length"] unsignedLongLongValue];
        if(offset<beginOffset||offset-beginOffset>logicalLength||snapshots[i].length>logicalLength-(offset-beginOffset))RFAIL("frame buffer payload range/version mismatch");
        FFSTFrameRoot *root=[self root:reference];
        ff_native_buffer_ref nativeRef={0};
        if(direct){
            ffjp_entry event=context.direct->events[i];const uint8_t *eventBytes=(const uint8_t*)context.direct.journal.bytes+event.offset;ffjp_record r;memcpy(&r,eventBytes,sizeof(r));
            if(r.root!=root.root||r.generation!=root.generation)RFAIL("direct resource generation mismatch");
            id<MTLBuffer> buffer=nil;NSUInteger base=0;
            if(r.flags==FFJP_NATIVE){
              if(!root.written||r.epoch!=root.version||r.epoch!=[reference[@"input_content_version"] unsignedLongLongValue]||offset<root.bufferOrigin||offset-root.bufferOrigin>root.bufferLength||snapshots[i].length>root.bufferLength-(offset-root.bufferOrigin)||![root.bufferDefined containsIndexesInRange:NSMakeRange(offset-root.bufferOrigin,snapshots[i].length)])RFAIL("direct native write version or defined range mismatch");
              buffer=root.buffer;base=offset-root.bufferOrigin;
            }else{
              if(root.written||[reference[@"input_content_version"] unsignedLongLongValue]!=1)RFAIL("CPU journal cannot replace a native writer");
              uint64_t range[2]={r.offset,r.length};NSData *key=[NSData dataWithBytes:range length:sizeof(range)];
              if(r.flags==FFJP_UPDATE){
                if(r.epoch<root.directEpoch||r.length>self.maxBytes-self.allocatedBytes)RFAIL("direct update epoch or budget mismatch");
                if(r.epoch>root.directEpoch){root.directSlices=[NSMutableDictionary new];root.directEpoch=r.epoch;root.directCost=0;}
                buffer=root.directSlices[key];
                if(buffer){if(buffer.length!=r.length||memcmp(buffer.contents,eventBytes+sizeof(r),r.length))RFAIL("same direct epoch changed its owned bytes");}
                else {
                  if(root.directSlices.count>=256)RFAIL("direct immutable range count exceeded");
                  buffer=[self.device newBufferWithBytes:eventBytes+sizeof(r) length:r.length options:MTLResourceStorageModeShared];if(!buffer||buffer.allocatedSize>self.maxBytes-self.allocatedBytes)RFAIL("direct owned range allocation failed");
                  self.allocatedBytes+=buffer.allocatedSize;root.directCost+=buffer.allocatedSize;root.directSlices[key]=buffer;
                }
                [self.dirtyRoots addObject:root];
              }
              if(root.directEpoch!=r.epoch||!root.directSlices[key])RFAIL("direct range reference precedes its owned update");
              buffer=root.directSlices[key];base=offset-r.offset;
            }
            if(!buffer)RFAIL("direct resource not live");bufferOverrides[bufferOverrideCount++]=(ff_native_buffer_override){.snapshot_id=i+1,.buffer=buffer,.base_offset=base};
            retained+=event.bytes;continue;
        }
        BOOL hasNativeRef=ffst_pass_resources_snapshot_native_ref(context.decoded,i,&nativeRef)!=0;
        if(hasNativeRef){
            uint64_t refRoot=0,refGeneration=0,refVersion=0;
            if(!ff_native_buffer_ref_enabled()||!typedGraph||!payload.ownedBlobs||snapshots[i].bytes||
               !ff_native_buffer_ref_valid(nativeRef)||nativeRef.stream!=begin->stream||nativeRef.frame!=begin->frame||
               nativeRef.chunk!=begin->chunk||nativeRef.payload!=begin->data[4]||nativeRef.snapshot_id!=i+1||
               !pass_u64(reference[@"root"],UINT64_MAX,&refRoot)||
               !pass_u64(reference[@"allocation_generation"],UINT64_MAX,&refGeneration)||
               !pass_u64(reference[@"input_content_version"],UINT64_MAX,&refVersion)||
               nativeRef.root!=refRoot||nativeRef.generation!=refGeneration||nativeRef.input_version!=refVersion||
               nativeRef.root!=root.root||nativeRef.generation!=root.generation||nativeRef.input_version!=root.version||
               nativeRef.offset!=offset||nativeRef.length!=snapshots[i].length||!root.written)
                RFAIL("native buffer marker lacks exact written-root authority");
        }else if(!snapshots[i].bytes)RFAIL("missing buffer bytes without a validated native marker");
        if(root.written){
            if(!root.buffer||offset<root.bufferOrigin||offset-root.bufferOrigin>root.bufferLength||
               snapshots[i].length>root.bufferLength-(offset-root.bufferOrigin)||
               ![root.bufferDefined containsIndexesInRange:NSMakeRange((NSUInteger)(offset-root.bufferOrigin),snapshots[i].length)])RFAIL("prior native buffer slice unavailable");
            bufferOverrides[bufferOverrideCount++]=(ff_native_buffer_override){.snapshot_id=i+1,.buffer=root.buffer,.base_offset=offset-root.bufferOrigin};
        }else {
            if(self.assetCache){NSUInteger pooledOffset=0;id<MTLBuffer> buffer=[self staticBuffer:&snapshots[i] reference:reference offset:offset nativeOffset:&pooledOffset];
                if(!buffer)RFAIL("native cached buffer unavailable");
                bufferOverrides[bufferOverrideCount++]=(ff_native_buffer_override){.snapshot_id=i+1,.buffer=buffer,.base_offset=pooledOffset};
            }else if(![self initialBytes:snapshots[i].bytes length:snapshots[i].length reference:reference offset:offset])return NO;
        }
        retained+=snapshots[i].length;
    }
    for(size_t i=0;i<nt;++i){NSDictionary *reference=textureRefs[i];
        if(!pass_u64(reference[@"id"],nt,&value)||value!=i+1||[reference[@"kind"] unsignedIntValue]!=FFS_TEXTURE||
           ![self.resourceIndex containsReference:reference flags:FFS_READ]||!frame_snapshot_view(reference,&textures[i])||
           [writtenRoots containsObject:frame_root_key(reference)])RFAIL("frame sampled texture identity/view mismatch");
        FFSTFrameRoot *root=[self root:reference];if(!root)return NO;
        if(direct&&!textures[i].bytes){NSData *marker=payload.blobs[[NSString stringWithFormat:@"journal-texture-%02zu.bin",i+1]];uint64_t version=0;if(marker.length==8)memcpy(&version,marker.bytes,8);
          if(!root.written||version!=root.version||version!=[reference[@"input_content_version"] unsignedLongLongValue])RFAIL("direct texture native version mismatch");}
        if(root.written){
            if(root.texture.mipmapLevelCount<textures[i].mip_count&&
               ![self extendWrittenTexture:root snapshot:&textures[i] reference:reference])
                RFAIL("native texture mip growth lacks qualified source levels or allocation budget");
            id<MTLTexture> texture=frame_native_view(root,reference);
            if(!texture||!frame_view_defined(root,reference,1))return [self reject:[NSString stringWithFormat:
                @"earlier native texture view unavailable root=%llu gen=%llu version=%llu native=%lux%lu/mips%lu/fmt%lu requested=%@x%@/base%@/mips%@/fmt%@ defined=%u",
                (unsigned long long)root.root,(unsigned long long)root.generation,(unsigned long long)root.version,
                (unsigned long)root.texture.width,(unsigned long)root.texture.height,(unsigned long)root.texture.mipmapLevelCount,
                (unsigned long)root.texture.pixelFormat,reference[@"width"],reference[@"height"],reference[@"base_mip"],reference[@"mip_count"],reference[@"format"],root.definedAspects]];
            overrides[overrideCount++]=(ff_native_texture_override){.snapshot_id=i+1,.texture=texture};}
        else {
            if(self.assetCache){id<MTLTexture> texture=[self staticTexture:&textures[i] reference:reference];if(!texture)RFAIL("native cached sampled texture unavailable");
                overrides[overrideCount++]=(ff_native_texture_override){.snapshot_id=i+1,.texture=texture};}
            else if(![self initialBytes:textures[i].bytes length:textures[i].length reference:reference offset:0])return NO;
        }
        retained+=direct&&!textures[i].bytes?sizeof(uint64_t):textures[i].length;
    }
    if(self.allocatedBytes>self.maxBytes-self.payloadBytes||retained>self.maxBytes-self.payloadBytes-self.allocatedBytes)RFAIL("frame payload byte limit exceeded");self.payloadBytes+=retained;
    if(self.payloadBytes+self.request.records.length>self.request.retainedBytes)RFAIL("frame retained-byte reservation understated");
    frame_profile_mark(renderProfileNs,FFST_PROFILE_ASSETS,&profileStarted);
    NSMutableArray<FFSTFrameRenderPipeline *> *pipelines=[NSMutableArray array];uint64_t libraryBytes=self.libraryBytes;
    for(NSUInteger i=0;i<pipelineRecords.count;++i){FFSTFrameRenderPipeline *pipeline=pass_pipeline(self.device,payload.directory,payload.blobs,pipelineRecords[i],a,i,self.libraryResolver,self.libraries,self.libraryCache,self.pipelineCache,&libraryBytes);
        if(!pipeline)RFAIL("native frame shader/reflection rejected");[pipelines addObject:pipeline];}
    self.libraryBytes=libraryBytes;NSMutableArray<FFSTFrameRenderDraw *> *draws=[NSMutableArray array];NSMutableIndexSet *used=[NSMutableIndexSet indexSet];
    uint64_t invocations=0,materials=0,geometry=0;
    for(NSUInteger i=0;i<drawRecords.count;++i){NSDictionary *record=drawRecords[i];uint64_t pipelineID,resourceID;
        pr_row directRow={0};
        if(direct){memcpy(&directRow,directRows+i*sizeof(directRow),sizeof(directRow));pipelineID=directRow.pipeline;resourceID=directRow.resources;if(pipelineID>=pipelines.count||resourceID!=i)RFAIL("unordered direct commands");}
        else if(!pass_u64(record[@"pipeline"],pipelines.count-1,&pipelineID)||!pass_u64(record[@"resources"],drawRecords.count-1,&resourceID)||resourceID!=i)RFAIL("unordered frame draw payload");
        FFSTFrameRenderPipeline *pipeline=pipelines[(NSUInteger)pipelineID];ff_draw_layout layout=pipeline.layout;FFSTPassDrawInfo info;ff_draw_bindings bindings;FFDPDrawScratch scratch;
        if(direct?!ffdp_draw(context.direct,i,&layout,&info,&scratch,&bindings):(!ffst_pass_resources_draw_info(context.decoded,i,&info)||!ffst_pass_resources_draw_bindings(context.decoded,i,&layout,&bindings)))RFAIL("frame draw resource reflection mismatch");
        FFSTFrameRenderDraw *draw=direct?pass_direct_draw(self.device,&directRow,directDepths,pipeline,&info,width,height,self.depthCache):pass_draw(self.device,record,pipeline,&info,width,height,self.depthCache);if(!draw)RFAIL("frame dynamic draw state rejected");
        BOOL material=NO;for(unsigned stage=0;stage<2;++stage)for(size_t f=0;f<bindings.argument_count[stage];++f)
            if(bindings.arguments[stage][f].kind==FF_FIELD_TEXTURE&&bindings.arguments[stage][f].value)material=YES;
        BOOL isGeometry=material&&info.count>6&&layout.ia_slot_mask&&layout.constant_count[0],declared;
        if((direct?(declared=directRow.material_geometry,directRow.material_geometry>1):!pass_bool(record[@"material_geometry"],&declared))||declared!=isGeometry||info.count*info.instances>10000000-invocations)RFAIL("frame draw work metadata mismatch");
        materials+=material;geometry+=isGeometry;invocations+=info.count*info.instances;[draws addObject:draw];[used addIndex:(NSUInteger)pipelineID];
    }
    if(used.count!=pipelines.count||!pass_u64(manifest[@"vertex_invocations"],10000000,&value)||value!=invocations||
       !pass_u64(manifest[@"material_draw_count"],FFST_PASS_DRAW_LIMIT,&value)||value!=materials||
       !pass_u64(manifest[@"material_geometry_draw_count"],FFST_PASS_DRAW_LIMIT,&value)||value!=geometry)RFAIL("frame aggregate draw metadata mismatch");
    frame_profile_mark(renderProfileNs,FFST_PROFILE_PIPELINES,&profileStarted);
    if(direct){
      context.directTables=ffdp_tables(self.device,context.direct,draws,bufferOverrides,bufferOverrideCount,overrides,overrideCount,self.depthCache);
      if(!context.directTables)RFAIL("direct command binding failed");
      if(context.directTables.arena.length>self.maxBytes-self.payloadBytes-self.allocatedBytes)RFAIL("direct table budget exceeded");self.allocatedBytes+=context.directTables.arena.length;
    }else{
    context.graph=ff_vertex_resources_create_graph_native_assets(self.device,snapshots,ns,textures,nt,samplers,nsa,bufferOverrides,bufferOverrideCount,overrides,overrideCount);
    if(!context.graph)RFAIL("native frame asset graph creation failed");
    _Static_assert(FF_NATIVE_PASS_DRAW_LIMIT==FFST_PASS_DRAW_LIMIT,"native pass table draw bound");
    ff_draw_bindings passBindings[FF_NATIVE_PASS_DRAW_LIMIT]={0};
    for(NSUInteger i=0;i<draws.count;++i){ff_draw_layout layout=draws[i].pipeline.layout;
        if(!ffst_pass_resources_draw_bindings(context.decoded,i,&layout,&passBindings[i]))RFAIL("frame draw bindings unavailable");}
    if(self.allocatedBytes>self.maxBytes-self.payloadBytes)RFAIL("native frame table arena budget exceeded");
    context.passTables=ff_vertex_pass_resources_create(context.graph,passBindings,draws.count,self.maxBytes-self.payloadBytes-self.allocatedBytes);
    if(!context.passTables)RFAIL("native frame table relocation or arena budget failed");
    context.graph=NULL; /* ownership transferred only after full construction */
    self.allocatedBytes+=ff_vertex_pass_resources_allocated_bytes(context.passTables);
    }
    frame_profile_mark(renderProfileNs,FFST_PROFILE_TABLES,&profileStarted);
    id<MTLTexture> color=format?[self attachment:roles[@"color"] format:format width:width height:height samples:samples load:loads[0] aspect:1]:nil;
    id<MTLTexture> depth=depthFormat?[self attachment:roles[@"depth"] format:depthFormat width:width height:height samples:samples load:loads[1] aspect:2]:nil;
    id<MTLTexture> stencil=stencilFormat?[self attachment:roles[@"stencil"] format:stencilFormat width:width height:height samples:samples load:loads[2] aspect:4]:nil;
    id<MTLTexture> resolved=roles[@"color_resolve"]?[self attachment:roles[@"color_resolve"] format:format width:width height:height samples:1 load:MTLLoadActionDontCare aspect:1]:nil;
    if((format&&!color)||(depthFormat&&!depth)||(stencilFormat&&!stencil)||(roles[@"color_resolve"]&&!resolved)||(alias&&depth!=stencil)||(!alias&&depth&&depth==stencil))RFAIL("native frame attachment version unavailable");
    frame_profile_mark(renderProfileNs,FFST_PROFILE_ATTACHMENTS,&profileStarted);
    MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    if(color){pass.colorAttachments[0].texture=color;pass.colorAttachments[0].loadAction=loads[0];
        pass.colorAttachments[0].clearColor=MTLClearColorMake([a[@"clear"][0] doubleValue],[a[@"clear"][1] doubleValue],[a[@"clear"][2] doubleValue],[a[@"clear"][3] doubleValue]);
        pass.colorAttachments[0].storeAction=stores[0];pass.colorAttachments[0].resolveTexture=resolved;}
    if(depth){pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=loads[1];pass.depthAttachment.storeAction=stores[1];pass.depthAttachment.clearDepth=[a[@"depth_clear"] doubleValue];}
    if(stencil){pass.stencilAttachment.texture=stencil;pass.stencilAttachment.loadAction=loads[2];pass.stencilAttachment.storeAction=stores[2];pass.stencilAttachment.clearStencil=[a[@"stencil_clear"] unsignedIntValue];}
    if(self.cancelled&&self.cancelled())RFAIL("native frame cancelled before encoding");
    id<MTLRenderCommandEncoder> encoder=[self.command renderCommandEncoderWithDescriptor:pass];if(!encoder)RFAIL("native frame render encoder failed");
    if(direct){id<MTLResource> __unsafe_unretained resident[FF_DRAW_RESOURCE_LIMIT+FF_TEXTURE_RESOURCE_LIMIT];NSUInteger count=0;for(id resource in context.directTables.held)if([resource conformsToProtocol:@protocol(MTLResource)]){if(count>=FF_DRAW_RESOURCE_LIMIT+FF_TEXTURE_RESOURCE_LIMIT)RFAIL("direct residency bound exceeded");resident[count++]=resource;}if(count)[encoder useResources:resident count:count usage:MTLResourceUsageRead stages:MTLRenderStageVertex|MTLRenderStageFragment];}
    else ff_vertex_pass_resources_declare(context.passTables,encoder);
    FFSTDrawStateShadow stateShadow={0};
    for(NSUInteger i=0;i<draws.count;++i){FFSTFrameRenderDraw *draw=draws[i];FFSTDrawState state=draw.state;uint32_t changed=ffst_draw_state_update(&stateShadow,&state);
        if(changed&FFST_STATE_PIPELINE)[encoder setRenderPipelineState:draw.pipeline.state];
        if(changed&FFST_STATE_DEPTH)[encoder setDepthStencilState:draw.depth];
        if(changed&FFST_STATE_VIEWPORT)[encoder setViewport:draw.viewport];
        if(changed&FFST_STATE_SCISSOR)[encoder setScissorRect:draw.scissor];
        if(changed&FFST_STATE_FILL)[encoder setTriangleFillMode:state.raster[0]];
        if(changed&FFST_STATE_CULL)[encoder setCullMode:state.raster[1]];
        if(changed&FFST_STATE_CLIP)[encoder setDepthClipMode:state.raster[2]];
        if(changed&FFST_STATE_WINDING)[encoder setFrontFacingWinding:state.raster[3]];
        if(changed&FFST_STATE_BIAS)[encoder setDepthBias:state.bias[0] slopeScale:state.bias[1] clamp:state.bias[2]];
        if(changed&FFST_STATE_BLEND)[encoder setBlendColorRed:state.blend[0] green:state.blend[1] blue:state.blend[2] alpha:state.blend[3]];
        if(changed&FFST_STATE_STENCIL)[encoder setStencilReferenceValue:state.stencil];
        if(direct)ffdp_bind(context.directTables,i,encoder);else ff_vertex_pass_resources_bind(context.passTables,i,encoder);
        if(draw.info.indexed){NSUInteger offset=direct?context.directTables->indexOffsets[i]:0;id<MTLBuffer> index=direct?context.directTables.indices[i]:ff_vertex_pass_resources_index(context.passTables,i,&offset);
            if(!index){[encoder endEncoding];RFAIL("native frame index buffer unavailable");}
            [encoder drawIndexedPrimitives:draw.info.primitive indexCount:draw.info.index_count indexType:draw.info.index_type indexBuffer:index indexBufferOffset:offset
                instanceCount:draw.info.instances baseVertex:draw.info.base_vertex baseInstance:draw.info.base_instance];}
        else [encoder drawPrimitives:draw.info.primitive vertexStart:draw.info.start vertexCount:draw.info.count instanceCount:draw.info.instances baseInstance:draw.info.base_instance];
    }
    [encoder endEncoding];
    const char *reference=getenv("BEDROCK_BOUNDARY_PASS_DIRECTORY");
    if(reference&&color&&(stores[0]==MTLStoreActionStore||stores[0]==MTLStoreActionStoreAndMultisampleResolve)){
        int directory=open(reference,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;
        BOOL safe=directory>=0&&!fstat(directory,&st)&&st.st_uid==getuid()&&!(st.st_mode&077);
        BOOL scheduled=safe&&boundary_pass_capture(self.command,color,directory,@"native",begin->stream,begin->frame,begin->data[4],
            ^(BOOL ok){if(!ok)fprintf(stderr,"[boundary-pass] native output failed\n");});
        if(directory>=0)close(directory);if(!scheduled)RFAIL("native pass reference scheduling failed");
    }
    NSMutableDictionary<NSData *,NSNumber *> *versions=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<resources.count;++i){const ffs_record *record=resourceRecords[i].bytes;if(!(record->flags&FFS_WRITE))continue;
        NSData *key=frame_root_key(resources[i]);NSNumber *version=@(record->data[8]);if(versions[key]&&![versions[key] isEqual:version])RFAIL("aliased frame writes disagree");versions[key]=version;}
    for(NSData *key in versions){FFSTFrameRoot *root=self.roots[key];root.version=versions[key].unsignedLongLongValue;root.written=YES;root.initialized=YES;}
    for(unsigned i=0;i<3;++i)if(roles[loadRoles[i]]){FFSTFrameRoot *root=self.roots[frame_root_key(roles[loadRoles[i]])];
        frame_define_mips(root,1u<<i,NSMakeRange([roles[loadRoles[i]][@"base_mip"] unsignedIntegerValue],1),
            stores[i]==MTLStoreActionStore||stores[i]==MTLStoreActionStoreAndMultisampleResolve);}
    if(roles[@"color_resolve"])frame_define_mips(self.roots[frame_root_key(roles[@"color_resolve"])],1,NSMakeRange(0,1),YES);
    self.passCount++;self.drawCount+=draws.count;
    if(direct){static _Atomic uint64_t passes,drawsTotal;uint64_t n=atomic_fetch_add(&passes,1)+1;atomic_fetch_add(&drawsTotal,draws.count);
      if(n<=2||!(n%256))fprintf(stderr,"[direct-pass] passes=%llu draws=%llu legacy_graphs=0\n",(unsigned long long)n,(unsigned long long)atomic_load(&drawsTotal));}
    frame_profile_mark(renderProfileNs,FFST_PROFILE_COMMANDS,&profileStarted);return YES;
#undef RFAIL
}
- (BOOL)present:(const ffs_record *)begin resources:(NSArray<NSData *> *)resourceRecords commands:(NSArray<NSData *> *)commands present:(const ffs_record *)present {
    if(!present||![self.request.payloads respondsToSelector:@selector(presentPayload:stream:frame:failure:)])return [self reject:@"native present payload unavailable"];
    NSString *failure=nil;NSDictionary *sidecar=[self.request.payloads presentPayload:begin->data[4] stream:begin->stream frame:begin->frame failure:&failure];
    if(!sidecar)return [self reject:failure?:@"native present payload missing"];
    if(![self coverage:sidecar begin:begin resources:resourceRecords commands:commands render:NO])return NO;
    NSDictionary *reference=sidecar[@"reference"];uint64_t value;
    if(!frame_reference(reference)||[reference[@"kind"] unsignedIntValue]!=FFS_TEXTURE||![self.resourceIndex containsReference:reference flags:FFS_READ])return [self reject:@"native present resource coverage missing"];
    NSArray *keys=@[@"root",@"view",@"allocation_generation",@"input_content_version"];
    for(unsigned i=0;i<4;++i)if(!pass_u64(reference[keys[i]],UINT64_MAX,&value)||value!=present->data[i])return [self reject:@"native present version mismatch"];
    FFSTFrameRoot *root=[self root:reference];id<MTLTexture> texture=frame_native_view(root,reference);
    if(!root.written||!frame_view_defined(root,reference,1)||!texture||texture.sampleCount!=1||texture.textureType!=MTLTextureType2D)return [self reject:@"final frame version was not written natively"];
    if(!frame_identity_sdr(sidecar[@"presentation"],texture))return [self reject:@"native Present transfer is not qualified identity SDR"];
    if(![self ensureCommand])return NO;
    NSMutableDictionary *presentation=[sidecar[@"presentation"] mutableCopy];
    if(!presentation[@"presenter_format"])presentation[@"presenter_format"]=presentation[@"source_format"];
    self.finalTexture=texture;self.presentReference=reference;self.presentation=presentation;
    [self.evidence addIndex:(NSUInteger)(present->sequence-self.firstSequence)];return YES;
}
- (BOOL)retire {
    if(self.retired)return self.failure==nil;
    if(self.committed){for(id<MTLCommandBuffer> command in self.commands){
            @try {if(command.status>=MTLCommandBufferStatusCommitted)[command waitUntilCompleted];}
            @catch(__unused NSException *exception){[self reject:@"native GPU retirement exception"];}}
        if(self.imports){@try {NSString *failure=nil;if(![self.request.payloads waitForImportRetirement:&failure])[self reject:failure?:@"frame import retirement failed"];}
            @catch(__unused NSException *exception){[self reject:@"native import retirement exception"];}}
        BOOL allTerminal=YES;for(id<MTLCommandBuffer> command in self.commands){
            if(command.status>=MTLCommandBufferStatusCommitted&&command.status<MTLCommandBufferStatusCompleted)allTerminal=NO;
            if(command.status!=MTLCommandBufferStatusCompleted)[self reject:@"native frame GPU failed"];}
        if(self.snapshotSubmissionNotified&&[self.request.payloads respondsToSelector:@selector(sharedSnapshotGPUCompleted:)]){
            NSString *reason=nil;if(!allTerminal||![self.request.payloads sharedSnapshotGPUCompleted:&reason])
                [self reject:reason?:@"shared snapshot GPU retirement unconfirmed"];}
    }else if(self.imports){@try {[self.request.payloads abandonImports];}
        @catch(__unused NSException *exception){[self reject:@"native import abandonment exception"];}}
    if(!self.committed&&[self.request.payloads respondsToSelector:@selector(sharedSnapshotAbandon)])
        [self.request.payloads sharedSnapshotAbandon];
    self.retired=YES;
    return self.failure==nil;
}
- (void)commitPrepared {
    if(self.command&&[self.commands indexOfObjectIdenticalTo:self.command]==NSNotFound)[self.commands addObject:self.command];
    if(!self.snapshotSubmissionNotified&&[self.request.payloads respondsToSelector:@selector(sharedSnapshotWillSubmit:)]){
        NSString *reason=nil;if(![self.request.payloads sharedSnapshotWillSubmit:&reason]){
            [self reject:reason?:@"shared snapshot submission rejected"];return;}
        self.snapshotSubmissionNotified=YES;}
    for(id<MTLCommandBuffer> command in self.commands){[command commit];self.committed=YES;}
}
@end

typedef struct { __unsafe_unretained NSIndexSet *records; uint64_t first; } FFSTFrameEvidence;
static int frame_evidence(const ffs_record *record,void *context) {
    FFSTFrameEvidence *e=context;return record->sequence>=e->first&&record->sequence-e->first<=FFS_MAX_RECORDS&&
        [e->records containsIndex:(NSUInteger)(record->sequence-e->first)];
}
static BOOL frame_encode_records(FFSTNativeFrameEngine *engine,const ffs_record *records,size_t count) {
    ffs_record begin={0},present={0};BOOL inEncoder=NO,hasPresent=NO;
    NSMutableArray<NSData *> *resourceRecords=[NSMutableArray array],*commands=[NSMutableArray array],*dependencies=[NSMutableArray array];
    for(size_t i=0;i<count;++i){const ffs_record *record=&records[i];
        if(engine.cancelled&&engine.cancelled()){[engine reject:@"native frame cancelled"];return NO;}
        switch(record->kind){
        case FFS_CHUNK_BEGIN:[engine beginChunk:record->chunk];break;
        case FFS_ENCODER_BEGIN:
            begin=*record;inEncoder=YES;hasPresent=NO;[resourceRecords removeAllObjects];[commands removeAllObjects];[dependencies removeAllObjects];break;
        case FFS_RESOURCE:[resourceRecords addObject:[NSData dataWithBytes:record length:sizeof(*record)]];break;
        case FFS_COMMAND:[commands addObject:[NSData dataWithBytes:record length:sizeof(*record)]];break;
        case FFS_PRESENT:present=*record;hasPresent=YES;break;
        case FFS_DEPENDENCY:
            if(inEncoder)[dependencies addObject:[NSData dataWithBytes:record length:sizeof(*record)]];
            if(record->flags&FFS_EXTERNAL){NSString *failure=nil;
                if(![engine.request.payloads respondsToSelector:@selector(externalDependencyCompleted:failure:)]||
                   ![engine.request.payloads externalDependencyCompleted:record failure:&failure]){[engine reject:failure?:@"external frame dependency lacks completed payload"];return NO;}
                [engine.evidence addIndex:(NSUInteger)(record->sequence-engine.firstSequence)];}
            break;
        case FFS_ENCODER_END:
            if(!inEncoder){[engine reject:@"native frame encoder ordering mismatch"];return NO;}
            if(begin.data[0]==FFS_RENDER||begin.data[0]==FFS_CLEAR||begin.data[0]==FFS_RESOLVE){if(engine.finalTexture){[engine reject:@"render work follows frame present"];return NO;}
                if(hasPresent||engine.passCount+engine.operationCount>=FFST_NATIVE_FRAME_MAX_PASSES||![engine render:&begin resources:resourceRecords commands:commands])return NO;}
            else if(begin.data[0]==FFS_BLIT||begin.data[0]==FFS_TIMESTAMP||begin.data[0]==FFS_SIGNAL_EVENT){
                uint64_t started=frame_monotonic_ns();
                if(engine.finalTexture||hasPresent||engine.passCount+engine.operationCount>=FFST_NATIVE_FRAME_MAX_PASSES||
                   ![engine operation:&begin resources:resourceRecords commands:commands dependencies:dependencies])return NO;
                uint64_t now=frame_monotonic_ns();if(started&&now>=started)frame_add_ns(&engine->operationNs,now-started);}
            else if(begin.data[0]==FFS_PRESENT_ENCODER){if(!hasPresent||engine.finalTexture||![engine present:&begin resources:resourceRecords commands:commands present:&present])return NO;}
            else if(begin.data[0]!=FFS_NULL){[engine reject:@"native frame encoder category unsupported"];return NO;}
            inEncoder=NO;break;
        case FFS_CHUNK_END:if(![engine stageBufferReadbacks])return NO;break;
        default:break;
        }
    }
    return YES;
}
static FFSTNativeFrameExecution *frame_run(FFSTNativeFrameEngine *engine,ffs_collector *ledger) {
    ffs_summary summary=ffs_inspect(ledger);size_t count=0;const ffs_record *records=ffs_records(ledger,&count);
    if(summary.status!=FFS_COMPLETE||!count){[engine reject:@"frame ledger is not complete"];return nil;}
    engine.firstSequence=summary.first_sequence;
    if(!frame_encode_records(engine,records,count))return nil;
    if(!engine.finalTexture||!engine.passCount||!engine.command){[engine reject:@"no complete native-written present frame"];return nil;}
    FFSTFrameEvidence evidence={engine.evidence,summary.first_sequence};
    if(!ffs_can_replay(ledger,frame_evidence,&evidence)){[engine reject:@"native frame lacks complete payload evidence"];return nil;}
    id<MTLTexture> source=engine.finalTexture;NSUInteger pixelBytes=pass_pixel_size(source.pixelFormat);
    if(!pixelBytes||source.width>SIZE_MAX/pixelBytes){[engine reject:@"native present format unsupported"];return nil;}
    NSUInteger row=(source.width*pixelBytes+255)&~(NSUInteger)255;
    if(!row||source.height>SIZE_MAX/row||row*source.height>128u*1024u*1024u){[engine reject:@"native frame readback limit"];return nil;}
    id<MTLTexture> output=[engine allocateFormat:source.pixelFormat width:source.width height:source.height samples:1];
    id<MTLBuffer> pixels=[engine.device newBufferWithLength:row*source.height options:MTLResourceStorageModeShared];
    if(!output||!pixels){[engine reject:@"native frame output allocation failed"];return nil;}
    id<MTLBlitCommandEncoder> blit=[engine.command blitCommandEncoder];if(!blit){[engine reject:@"native frame output encoder failed"];return nil;}
    [blit copyFromTexture:source toTexture:output];
    [blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(source.width,source.height,1)
        toBuffer:pixels destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*source.height];[blit endEncoding];
    if(engine.cancelled&&engine.cancelled()){[engine reject:@"native frame cancelled before commit"];return nil;}
    if(engine.imports){NSString *failure=nil;if(![engine.request.payloads finishImportsWithCommand:engine.command failure:&failure]){
        /* Some imports may already have consumed their leases and installed
         * completion handlers. Complete this owned command for cleanup, then
         * retire every import; the failed frame is never published. */
        [engine reject:failure?:@"native frame import completion rejected"];
        [engine commitPrepared];[engine retire];return nil;
    }}
    [engine commitPrepared];if(![engine retire])return nil;
    NSMutableArray *timestamps=[NSMutableArray array],*signals=[NSMutableArray array];
    static _Atomic uint64_t timestampWatermark;
    for(NSDictionary *sample in engine.timestampRequests){id<MTLCommandBuffer> command=sample[@"command"];double seconds=command.GPUEndTime;
        if(!isfinite(seconds)||seconds<0||seconds>(double)UINT64_MAX/1e9){[engine reject:@"native GPU timestamp unavailable"];return nil;}
        uint64_t value=(uint64_t)(seconds*1e9),previous=atomic_load(&timestampWatermark);
        while(value>previous&&!atomic_compare_exchange_weak(&timestampWatermark,&previous,value)){}if(previous>value)value=previous;
        [timestamps addObject:@{@"chunk":sample[@"chunk"],@"readback_index":sample[@"readback_index"],@"query_count":sample[@"query_count"],@"value_ns":@(value)}];}
    for(NSDictionary *signal in engine.signalRequests){id<MTLSharedEvent> event=signal[@"event"];uint64_t value=event.signaledValue;
        if(value<[signal[@"value"] unsignedLongLongValue]){[engine reject:@"native event did not reach its declared GPU signal"];return nil;}
        [signals addObject:@{@"domain":signal[@"domain"],@"id":signal[@"id"],@"value":signal[@"value"],@"signaled_value":@(value)}];}
    NSArray *bufferReadbacks=[engine completedBufferReadbacks];if(!bufferReadbacks)return nil;
    FFSTNativeFrameExecution *result=[FFSTNativeFrameExecution new];result.texture=output;result.rowBytes=row;result.pixels=[NSData dataWithBytes:pixels.contents length:row*source.height];
    result.bufferReadbacks=bufferReadbacks;
    result.metrics=@{@"format":@"bedrock-native-frame-result",@"version":@1,@"status":@"gpu_completed",@"stream":@(summary.stream),@"frame":@(summary.frame),
        @"ledger_digest":@(summary.digest),@"first_sequence":@(summary.first_sequence),@"next_sequence":@(summary.next_sequence),
        @"encoders":@(summary.encoders),@"render_passes":@(engine.passCount),@"render_encoders":@(summary.category_count[FFS_RENDER]),
        @"clear_encoders":@(summary.category_count[FFS_CLEAR]),@"resolve_encoders":@(summary.category_count[FFS_RESOLVE]),@"draws":@(engine.drawCount),@"covered_records":@(engine.evidence.count),
        @"payload_bytes":@(engine.payloadBytes),@"native_attachment_bytes":@(engine.allocatedBytes),@"device_id":@(engine.device.registryID),
        @"operation_encoders":@(engine.operationCount),@"command_buffers":@(engine.commands.count),@"buffer_copy_bytes":@(engine.copyBytes),@"texture_upload_bytes":@(engine.textureUploadBytes),@"timestamps":timestamps,@"signals":signals,
        @"texture_readback_bytes":@(engine.readbackBytes),
        @"initial_mip_copies":@(engine.initialMipCopies),
        @"width":@(output.width),@"height":@(output.height),@"pixel_format":@(output.pixelFormat),@"row_bytes":@(row),
        @"present_reference":engine.presentReference,@"presentation":engine.presentation,@"gpu_completed":@YES,@"imports_retired":@YES,
        @"presenter_completed":@NO,@"present_transfer_applied":@NO,@"present_profile":@"qualified identity SDR",
        @"output_scope":@"native backbuffer before presenter transfer"};
    return result;
}
FFSTNativeFrameExecution *ffst_native_frame_execute(FFSTNativeFrameRequest *request,FFSTPassLibraryResolver libraries,BOOL (^cancelled)(void),NSString **failure) {
    if(failure)*failure=nil;
    if(!request||!request.records.length||request.records.length%sizeof(ffs_record)){if(failure)*failure=@"invalid native frame request";return nil;}
    ffs_record first;memcpy(&first,request.records.bytes,sizeof(first));
    ffs_collector *ledger=ffs_create(request.streamID,first.sequence,request.records.length/sizeof(ffs_record));
    if(!ledger){if(failure)*failure=@"native frame ledger allocation failed";return nil;}
    FFSTNativeFrameEngine *engine=[FFSTNativeFrameEngine new];engine.maxBytes=FFST_NATIVE_FRAME_MAX_BYTES;engine.request=(id<FFSTNativeExecutionRequest>)request;engine.libraryResolver=libraries;engine.cancelled=cancelled;
    engine.roots=[NSMutableDictionary dictionary];engine.initialDigests=[NSMutableDictionary dictionary];engine.initialDigestKeys=[NSMutableDictionary dictionary];engine.contexts=[NSMutableArray array];
    engine.commands=[NSMutableArray array];engine.chunkCommands=[NSMutableDictionary dictionary];engine.events=[NSMutableDictionary dictionary];
    engine.timestampRequests=[NSMutableArray array];engine.signalRequests=[NSMutableArray array];
    engine.libraries=[NSMutableDictionary dictionary];engine.evidence=[NSMutableIndexSet indexSet];FFSTNativeFrameExecution *result=nil;
    @try {
        const uint8_t *bytes=request.records.bytes;
        for(size_t i=0;i<request.records.length/sizeof(ffs_record);++i){ffs_record record;memcpy(&record,bytes+i*sizeof(record),sizeof(record));
            if(!ffs_consume(ledger,&record)){[engine reject:@"native frame ledger changed or invalid"];break;}}
        if(!engine.failure)result=frame_run(engine,ledger);
    } @catch(NSException *exception){[engine reject:[NSString stringWithFormat:@"native frame exception: %@",exception.name]];}
    @finally { [engine retire];ffs_destroy(ledger); }
    if(engine.failure){if(failure)*failure=engine.failure;return nil;}return result;
}

@interface FFSTNativeChunkExecution ()
@property(nonatomic,readwrite,strong) NSDictionary *metrics;
@property(nonatomic,readwrite,strong) FFSTNativeFrameExecution *frameOutput;
@property(nonatomic,readwrite,strong) NSArray<FFSTNativeBufferReadback *> *bufferReadbacks;
@end
@implementation FFSTNativeChunkExecution @end

static BOOL chunk_completed_operations(FFSTNativeFrameEngine *engine,NSMutableArray *timestamps,NSMutableArray *signals) {
    static _Atomic uint64_t watermark;
    for(NSDictionary *sample in engine.timestampRequests){id<MTLCommandBuffer> command=sample[@"command"];double seconds=command.GPUEndTime;
        if(!isfinite(seconds)||seconds<=0||seconds>(double)UINT64_MAX/1e9)return [engine reject:@"native chunk GPU timestamp unavailable"];
        uint64_t value=(uint64_t)(seconds*1e9),prior=atomic_load(&watermark);
        while(value>prior&&!atomic_compare_exchange_weak(&watermark,&prior,value)){}if(prior>value)value=prior;
        [timestamps addObject:@{@"chunk":sample[@"chunk"],@"readback_index":sample[@"readback_index"],@"query_count":sample[@"query_count"],@"value_ns":@(value)}];}
    for(NSDictionary *signal in engine.signalRequests){id<MTLSharedEvent> event=signal[@"event"];uint64_t value=event.signaledValue;
        if(value<[signal[@"value"] unsignedLongLongValue])return [engine reject:@"native chunk event signal incomplete"];
        [signals addObject:@{@"domain":signal[@"domain"],@"id":signal[@"id"],@"value":signal[@"value"],@"signaled_value":@(value)}];}
    return YES;
}

@implementation FFSTNativeSession {
    NSRecursiveLock *_guard;
    ffs_collector *_ledger;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    NSMutableDictionary<NSData *,FFSTFrameRoot *> *_roots;
    NSMutableDictionary<NSData *,NSData *> *_initialDigests;
    NSMutableDictionary<NSData *,NSMutableSet<NSData *> *> *_initialDigestKeys;
    NSMutableDictionary<NSString *,id<MTLSharedEvent>> *_events;
    FFSTNativeSessionCache *_libraryCache,*_pipelineCache,*_depthCache,*_assetCache;
    FFSTPassLibraryResolver _resolver;
    uint64_t _maxBytes,_rootBytes,_libraryReservation,_stream,_frame,_lastSerial,_lastChunk,_nextSequence;
    uint64_t _completedChunks,_completedFrames,_frameDraws,_framePasses,_frameOperations,_frameMipCopies;
    uint64_t _firstExecutionNs,_lastCompletionNs,_executionActiveNs;
    uint64_t _prepareNs,_encodeNs,_gpuRetireNs;
    uint64_t _sharedSnapshotBuffers,_sharedSnapshotBufferBytes;
    uint64_t _operationNs,_retirementNs,_cleanupNs;
    uint64_t _renderProfileNs[FFST_RENDER_PROFILE_COUNT];
    BOOL _readback,_closed,_poisoned;
    id<MTLBuffer> _uploadPool;
}
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes diagnosticReadback:(BOOL)readback {
    return [self initWithMaxRetainedBytes:maxBytes diagnosticReadback:readback libraries:nil];
}
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes diagnosticReadback:(BOOL)readback libraries:(FFSTPassLibraryResolver)libraries {
    if(maxBytes<1024u*1024u||maxBytes>FFST_NATIVE_FRAME_MAX_BYTES)return nil;
    self=[super init];if(self){_guard=[NSRecursiveLock new];_maxBytes=maxBytes;_readback=readback;_resolver=[libraries copy];
        _roots=[NSMutableDictionary dictionary];_initialDigests=[NSMutableDictionary dictionary];_initialDigestKeys=[NSMutableDictionary dictionary];_events=[NSMutableDictionary dictionary];
        _libraryReservation=MIN(64u*1024u*1024u,maxBytes/4);
        _libraryCache=[[FFSTNativeSessionCache alloc] initWithMaxEntries:128 maxCost:_libraryReservation];
        _pipelineCache=[[FFSTNativeSessionCache alloc] initWithMaxEntries:256 maxCost:256];
        _depthCache=[[FFSTNativeSessionCache alloc] initWithMaxEntries:256 maxCost:256];
        _assetCache=[[FFSTNativeSessionCache alloc] initWithMaxEntries:2048 maxCost:MIN(128u*1024u*1024u,maxBytes/4)];
        _device=MTLCreateSystemDefaultDevice();_queue=[_device newCommandQueue];
        const char *poolMode=getenv("BEDROCK_NATIVE_UPLOAD_POOL");
        if(poolMode&&!strcmp(poolMode,"1")){_uploadPool=[_device newBufferWithLength:4u*1024u*1024u options:MTLResourceStorageModeShared];if(!_uploadPool)return nil;}
        if(!_device||!_queue||!_libraryCache||!_pipelineCache||!_depthCache||!_assetCache)return nil;}
    return self;
}
- (void)dealloc {ffs_destroy(_ledger);}
- (NSDictionary *)stats {
    [_guard lock];
    uint64_t interval=_lastCompletionNs>=_firstExecutionNs&&_firstExecutionNs?_lastCompletionNs-_firstExecutionNs:0;
    NSDictionary *result=@{@"closed":@(_closed),@"poisoned":@(_poisoned),@"roots":@(_roots.count),
        @"native_resource_bytes":@(_rootBytes),@"completed_chunks":@(_completedChunks),@"completed_frames":@(_completedFrames),
        @"last_serial":@(_lastSerial),@"next_sequence":@(_nextSequence),@"library_cache":_libraryCache.stats?:@{},
        @"pipeline_cache":_pipelineCache.stats?:@{},@"depth_cache":_depthCache.stats?:@{},@"asset_cache":_assetCache.stats?:@{},
        @"captured_execution_active_seconds":@(_executionActiveNs/1e9),@"native_completion_interval_seconds":@(interval/1e9),
        @"native_completed_frames_per_second":@(interval?(double)_completedFrames*1e9/interval:0),
        @"native_prepare_seconds":@(_prepareNs/1e9),@"native_encode_seconds":@(_encodeNs/1e9),
        @"native_operation_seconds":@(_operationNs/1e9),@"native_retirement_seconds":@(_retirementNs/1e9),@"native_cleanup_seconds":@(_cleanupNs/1e9),
        @"native_render_profile":frame_render_profile(_renderProfileNs),
        @"native_gpu_retire_seconds":@(_gpuRetireNs/1e9),
        @"shared_snapshot_buffers":@(_sharedSnapshotBuffers),@"shared_snapshot_buffer_bytes":@(_sharedSnapshotBufferBytes)};
    [_guard unlock];return result;
}
- (void)close {
    [_guard lock];_closed=YES;ffs_destroy(_ledger);_ledger=NULL;[_roots removeAllObjects];[_initialDigests removeAllObjects];[_initialDigestKeys removeAllObjects];[_events removeAllObjects];
    [_libraryCache removeAll];[_pipelineCache removeAll];[_depthCache removeAll];[_assetCache removeAll];_uploadPool=nil;_rootBytes=0;[_guard unlock];
}
- (BOOL)refreshRootBytes:(NSSet<FFSTFrameRoot *> *)dirtyRoots {
    /* Only storage assignments change a root's resident cost. Remove all old
     * costs before adding replacements, so a simultaneous replacement cannot
     * spuriously exceed the limit due to iteration order. */
    uint64_t bytes=_rootBytes;
    for(FFSTFrameRoot *root in dirtyRoots){if(root.accountedBytes>bytes)return NO;bytes-=root.accountedBytes;}
    for(FFSTFrameRoot *root in dirtyRoots){uint64_t texture=root.texture.allocatedSize,buffer=root.buffer.allocatedSize+root.directCost;
        if(texture>_maxBytes-bytes)return NO;bytes+=texture;if(buffer>_maxBytes-bytes)return NO;bytes+=buffer;}
    for(FFSTFrameRoot *root in dirtyRoots)root.accountedBytes=root.texture.allocatedSize+root.buffer.allocatedSize+root.directCost;
    _rootBytes=bytes;return YES;
}
- (FFSTNativeChunkExecution *)executeChunk:(FFSTNativeChunkRequest *)request consumed:(void (^)(void))consumed
    cancelled:(BOOL (^)(void))cancelled failure:(NSString **)failure {
    if(failure)*failure=nil;[_guard lock];FFSTNativeFrameEngine *engine=nil;FFSTNativeChunkExecution *result=nil;
    BOOL completionHooksAttempted=NO;uint64_t executionStarted=0;
    @try {
        if(_closed||_poisoned||!request||_lastSerial==UINT64_MAX||request.serial!=_lastSerial+1||
           (_stream&&request.streamID!=_stream)||(_nextSequence&&request.firstSequence!=_nextSequence)||
           (_lastSerial&&(_lastChunk==UINT64_MAX||request.chunkID!=_lastChunk+1))){
            if(failure)*failure=@"Native session identity or order mismatch";_poisoned=YES;return nil;}
        /* Starts with captured work, excluding pre-arm/loading. Completion
         * throughput includes capture gaps and is not display/presentation FPS. */
        executionStarted=frame_monotonic_ns();if(!_firstExecutionNs)_firstExecutionNs=executionStarted;
        if(request.beginsFrame){
            if((_ledger&&ffs_inspect(_ledger).status!=FFS_COMPLETE)||(_frame&&request.frameID<=_frame)){
                if(failure)*failure=@"Native frame overlaps prior frame";_poisoned=YES;return nil;}
            if(_ledger){if(!ffs_begin_next_frame(_ledger,request.firstSequence)){
                    if(failure)*failure=@"Native persistent ledger frame transition failed";_poisoned=YES;return nil;}}
            else _ledger=ffs_create(request.streamID,request.firstSequence,FFS_MAX_RECORDS);
            if(!_ledger){if(failure)*failure=@"Native incremental ledger allocation failed";_poisoned=YES;return nil;}
            _frame=request.frameID;_frameDraws=_framePasses=_frameOperations=_frameMipCopies=0;
        }else if(!_ledger||request.frameID!=_frame||ffs_inspect(_ledger).status==FFS_COMPLETE){
            if(failure)*failure=@"Native chunk lacks active original frame";_poisoned=YES;return nil;}
        const uint8_t *wire=request.records.bytes;uint64_t queueCompletion=0;
        for(size_t i=0;i<request.records.length/sizeof(ffs_record);++i){ffs_record r;memcpy(&r,wire+i*sizeof(r),sizeof(r));
            if(!ffs_consume(_ledger,&r)){if(failure)*failure=@"Native incremental ledger rejected chunk";_poisoned=YES;return nil;}
            if(r.kind==FFS_CHUNK_BEGIN)queueCompletion=r.data[3];}
        ffs_summary summary=ffs_inspect(_ledger);size_t count=0;const ffs_record *records=ffs_records(_ledger,&count);
        if((request.endsFrame&&summary.status!=FFS_COMPLETE)||(!request.endsFrame&&summary.status!=FFS_INCOMPLETE)){
            if(failure)*failure=@"Native chunk frame boundary mismatch";_poisoned=YES;return nil;}
        engine=[FFSTNativeFrameEngine new];engine.request=(id<FFSTNativeExecutionRequest>)request;engine.maxBytes=_maxBytes;engine.serial=request.serial;
        engine.device=_device;engine.queue=_queue;engine.roots=_roots;engine.dirtyRoots=[NSMutableSet set];engine.initialDigests=_initialDigests;engine.initialDigestKeys=_initialDigestKeys;engine.events=_events;
        engine.commands=[NSMutableArray array];engine.chunkCommands=[NSMutableDictionary dictionary];engine.timestampRequests=[NSMutableArray array];
        engine.signalRequests=[NSMutableArray array];engine.contexts=[NSMutableArray array];engine.libraries=[NSMutableDictionary dictionary];engine.evidence=[NSMutableIndexSet indexSet];
        engine.libraryCache=_libraryCache;engine.pipelineCache=_pipelineCache;engine.depthCache=_depthCache;engine.assetCache=_assetCache;engine.uploadPool=_uploadPool;
        engine.libraryResolver=_resolver;engine.cancelled=cancelled;engine.firstSequence=request.firstSequence;
        uint64_t cached=[_assetCache.stats[@"cost"] unsignedLongLongValue]+(_uploadPool?_uploadPool.allocatedSize:0);
        if(_rootBytes>_maxBytes-_libraryReservation||cached>_maxBytes-_libraryReservation-_rootBytes){[engine reject:@"Native session resident budget exceeded"];return nil;}
        engine.allocatedBytes=_rootBytes+_libraryReservation+cached;
        uint64_t encodingStarted=frame_monotonic_ns();
        uint64_t prepareNs=executionStarted&&encodingStarted>=executionStarted?encodingStarted-executionStarted:0;
        if(!frame_encode_records(engine,records,count))return nil;
        uint64_t encodingFinished=frame_monotonic_ns();
        uint64_t encodeNs=encodingStarted&&encodingFinished>=encodingStarted?encodingFinished-encodingStarted:0;
        FFSTFrameEvidence evidence={engine.evidence,request.firstSequence};
        if(!ffs_can_replay_chunk(_ledger,request.firstSequence,frame_evidence,&evidence)){[engine reject:@"Native chunk lacks complete payload evidence"];return nil;}
        if((engine.finalTexture!=nil)!=request.endsFrame){[engine reject:@"Native Present must end its original frame"];return nil;}
        for(NSDictionary *retirement in request.retiredRoots){FFSTFrameRoot *root=_roots[frame_root_key(retirement)];
            if(root&&root.lastUseSerial>[retirement[@"last_use_serial"] unsignedLongLongValue]){[engine reject:@"Native resource retirement precedes its last use"];return nil;}}
        if(![engine ensureCommand])return nil;
        id<MTLTexture> output=nil;id<MTLBuffer> pixels=nil;NSUInteger row=0;
        if(engine.finalTexture){id<MTLTexture> source=engine.finalTexture;NSUInteger pixelBytes=pass_pixel_size(source.pixelFormat);
            if(!pixelBytes||source.width>SIZE_MAX/pixelBytes){[engine reject:@"Native output pixel format unsupported"];return nil;}
            output=[engine allocateFormat:source.pixelFormat width:source.width height:source.height samples:1];
            if(_readback){row=(source.width*pixelBytes+255)&~(NSUInteger)255;
                if(!row||source.height>SIZE_MAX/row||row*source.height>128u*1024u*1024u){[engine reject:@"Native diagnostic readback limit"];return nil;}
                pixels=[_device newBufferWithLength:row*source.height options:MTLResourceStorageModeShared];}
            id<MTLBlitCommandEncoder> blit=output&&(!_readback||pixels)?[engine.command blitCommandEncoder]:nil;
            if(!blit){[engine reject:@"Native independent output copy unavailable"];return nil;}
            [blit copyFromTexture:source toTexture:output];
            if(pixels)[blit copyFromTexture:output sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
                sourceSize:MTLSizeMake(source.width,source.height,1) toBuffer:pixels destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:row*source.height];
            [blit endEncoding];}
        if(cancelled&&cancelled()){[engine reject:@"Native chunk cancelled before commit"];return nil;}
        if(consumed)consumed();
        if(engine.imports){NSString *reason=nil;completionHooksAttempted=YES;
            if(![request.payloads finishImportsWithCommand:engine.command failure:&reason]){
                [engine reject:reason?:@"Native chunk import completion rejected"];[engine commitPrepared];[engine retire];return nil;}}
        uint64_t retiringStarted=frame_monotonic_ns();
        [engine commitPrepared];if(![engine retire])return nil;
        uint64_t retiringFinished=frame_monotonic_ns();
        /* Host wait/retirement includes import acknowledgement, not GPU time. */
        uint64_t gpuRetireNs=retiringStarted&&retiringFinished>=retiringStarted?retiringFinished-retiringStarted:0;
        NSArray *bufferReadbacks=[engine completedBufferReadbacks];if(!bufferReadbacks)return nil;
        NSMutableArray *timestamps=[NSMutableArray array],*signals=[NSMutableArray array];
        if(!chunk_completed_operations(engine,timestamps,signals))return nil;
        _frameDraws+=engine.drawCount;_framePasses+=engine.passCount;_frameOperations+=engine.operationCount;_frameMipCopies+=engine.initialMipCopies;
        NSMutableDictionary *metrics=[@{@"format":@"bedrock-native-chunk-result",@"version":@1,@"status":@"gpu_completed",
            @"serial":@(request.serial),@"stream":@(request.streamID),@"frame":@(request.frameID),@"chunk":@(request.chunkID),
            @"record_digest":@(request.recordDigest),@"queue_completion":@(queueCompletion),@"first_sequence":@(request.firstSequence),
            @"next_sequence":@(request.nextSequence),@"gpu_completed":@YES,@"imports_retired":@YES,@"presenter_completed":@NO,
            @"timestamps":timestamps,@"signals":signals,@"draws":@(engine.drawCount),@"render_passes":@(engine.passCount),
            @"operation_encoders":@(engine.operationCount),@"command_buffers":@(engine.commands.count),@"buffer_copy_bytes":@(engine.copyBytes),
            @"texture_upload_bytes":@(engine.textureUploadBytes),
            @"texture_readback_bytes":@(engine.readbackBytes),
            @"shared_snapshot_buffers":@(engine.sharedSnapshotBuffers),
            @"shared_snapshot_buffer_bytes":@(engine.sharedSnapshotBufferBytes),
            @"initial_mip_copies":@(engine.initialMipCopies),
            @"native_prepare_seconds":@(prepareNs/1e9),@"native_encode_seconds":@(encodeNs/1e9),
            @"native_operation_seconds":@(engine->operationNs/1e9),
            @"native_render_profile":frame_render_profile(engine->renderProfileNs),
            @"native_gpu_retire_seconds":@(gpuRetireNs/1e9),
            @"diagnostic_readback":@(_readback&&output!=nil)} mutableCopy];
        result=[FFSTNativeChunkExecution new];result.bufferReadbacks=bufferReadbacks;
        if(output){FFSTNativeFrameExecution *frame=[FFSTNativeFrameExecution new];frame.texture=output;frame.rowBytes=row;
            frame.pixels=pixels?[NSData dataWithBytes:pixels.contents length:row*output.height]:nil;
            frame.bufferReadbacks=bufferReadbacks;
            NSMutableDictionary *frameMetrics=[metrics mutableCopy];[frameMetrics addEntriesFromDictionary:@{@"format":@"bedrock-native-frame-result",
                @"ledger_digest":@(summary.digest),@"draws":@(_frameDraws),@"render_passes":@(_framePasses),@"operation_encoders":@(_frameOperations),
                @"initial_mip_copies":@(_frameMipCopies),
                @"width":@(output.width),@"height":@(output.height),@"pixel_format":@(output.pixelFormat),@"row_bytes":@(row),
                @"present_reference":engine.presentReference,@"presentation":engine.presentation,@"present_transfer_applied":@NO,
                @"output_scope":@"native backbuffer before presenter transfer"}];frame.metrics=[frameMetrics copy];result.frameOutput=frame;
            metrics[@"ledger_digest"]=@(summary.digest);}
        uint64_t retirementStarted=frame_monotonic_ns();
        for(NSDictionary *retirement in request.retiredRoots){NSData *key=frame_root_key(retirement);
            if(!ffs_retire_generation(_ledger,[retirement[@"kind"] unsignedLongLongValue],[retirement[@"root"] unsignedLongLongValue],
                [retirement[@"allocation_generation"] unsignedLongLongValue])){[engine reject:@"Native ledger resource retirement failed"];return nil;}
            FFSTFrameRoot *root=_roots[key];if(root.accountedBytes>_rootBytes){[engine reject:@"Native persistent resource accounting mismatch"];return nil;}
            _rootBytes-=root.accountedBytes;if(root)[engine.dirtyRoots removeObject:root];
            [_roots removeObjectForKey:key];[_initialDigests removeObjectsForKeys:_initialDigestKeys[key].allObjects?:@[]];[_initialDigestKeys removeObjectForKey:key];}
        /* Immutable asset keys are NSData content IDs, never logical-root
         * strings. Root retirement must not scan or invalidate that cache. */
        if(![self refreshRootBytes:engine.dirtyRoots]){[engine reject:@"Native persistent resource budget exceeded"];return nil;}
        uint64_t retirementFinished=frame_monotonic_ns();
        uint64_t retirementNs=retirementStarted&&retirementFinished>=retirementStarted?retirementFinished-retirementStarted:0;
        _stream=request.streamID;_lastSerial=request.serial;_lastChunk=request.chunkID;_nextSequence=request.nextSequence;
        if(_completedChunks!=UINT64_MAX)++_completedChunks;if(request.endsFrame&&_completedFrames!=UINT64_MAX)++_completedFrames;
        if(!ffs_discard_consumed_chunks(_ledger)){[engine reject:@"Native ledger chunk retirement failed"];return nil;}
        /* All commands and imports have actually retired. Release transient
         * tables/command ownership here so teardown is measured, rather than
         * hiding its cost in ARC after the execution timer stops. */
        uint64_t cleanupStarted=frame_monotonic_ns();
        [engine.contexts removeAllObjects];engine.command=nil;[engine.commands removeAllObjects];[engine.chunkCommands removeAllObjects];
        uint64_t cleanupFinished=frame_monotonic_ns();
        uint64_t cleanupNs=cleanupStarted&&cleanupFinished>=cleanupStarted?cleanupFinished-cleanupStarted:0;
        uint64_t completedAt=frame_monotonic_ns();
        if(executionStarted&&completedAt>=executionStarted){uint64_t elapsed=completedAt-executionStarted;
            _executionActiveNs=elapsed>UINT64_MAX-_executionActiveNs?UINT64_MAX:_executionActiveNs+elapsed;_lastCompletionNs=completedAt;}
        _prepareNs=prepareNs>UINT64_MAX-_prepareNs?UINT64_MAX:_prepareNs+prepareNs;
        _encodeNs=encodeNs>UINT64_MAX-_encodeNs?UINT64_MAX:_encodeNs+encodeNs;
        _gpuRetireNs=gpuRetireNs>UINT64_MAX-_gpuRetireNs?UINT64_MAX:_gpuRetireNs+gpuRetireNs;
        _sharedSnapshotBuffers+=engine.sharedSnapshotBuffers;
        _sharedSnapshotBufferBytes+=engine.sharedSnapshotBufferBytes;
        frame_add_ns(&_operationNs,engine->operationNs);frame_add_ns(&_retirementNs,retirementNs);frame_add_ns(&_cleanupNs,cleanupNs);
        for(unsigned i=0;i<FFST_RENDER_PROFILE_COUNT;++i)frame_add_ns(&_renderProfileNs[i],engine->renderProfileNs[i]);
        metrics[@"native_retirement_seconds"]=@(retirementNs/1e9);metrics[@"native_cleanup_seconds"]=@(cleanupNs/1e9);
        metrics[@"native_resource_bytes"]=@(_rootBytes);metrics[@"retired_roots"]=@(request.retiredRoots.count);result.metrics=[metrics copy];
    } @catch(NSException *exception) {
        if(engine)[engine reject:[NSString stringWithFormat:@"Native chunk exception: %@",exception.name]];
        else {if(failure)*failure=@"Native chunk ownership exception";_poisoned=YES;}
    } @finally {
        @try {if(engine){if(!result&&!engine.failure)[engine reject:@"Native chunk execution did not complete"];
                if(completionHooksAttempted&&!engine.committed)[engine commitPrepared];[engine retire];
                if(engine.failure){_poisoned=YES;result=nil;if(failure)*failure=engine.failure;}}}
        @catch(__unused NSException *exception){_poisoned=YES;result=nil;if(failure)*failure=@"Native chunk cleanup exception";}
        @finally {[_guard unlock];}
    }
    return result;
}
@end
