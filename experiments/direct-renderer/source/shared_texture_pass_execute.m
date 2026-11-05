#import "shared_texture_pass_execute.h"
#import "shared_texture_pass_resources.h"
#import "shared_texture_executor.h"
#import "shader_bindings.h"
#include <CommonCrypto/CommonDigest.h>
#include <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error shared_texture_pass_execute.m requires ARC
#endif
@interface FFSTPassExecution ()
@property(nonatomic,readwrite,strong) id<MTLTexture> texture;
@property(nonatomic,readwrite,strong) NSData *pixels;
@property(nonatomic,readwrite) NSUInteger rowBytes;
@property(nonatomic,readwrite,strong) NSDictionary *metrics;
@end
@implementation FFSTPassExecution @end
@interface FFSTRenderPipeline : NSObject
@property(nonatomic,strong) id<MTLRenderPipelineState> state;
@property(nonatomic) ff_draw_layout layout;
@end
@implementation FFSTRenderPipeline @end
@interface FFSTRenderDraw : NSObject
@property(nonatomic,strong) FFSTRenderPipeline *pipeline;
@property(nonatomic,strong) id<MTLDepthStencilState> depth;
@property(nonatomic) FFSTPassDrawInfo info;
@property(nonatomic) MTLViewport viewport;
@property(nonatomic) MTLScissorRect scissor;
@property(nonatomic,strong) NSArray *raster,*blend;
@property(nonatomic) uint32_t stencil;
@property(nonatomic) BOOL material,geometry;
@end
@implementation FFSTRenderDraw @end
@interface FFSTRenderContext : NSObject
@property(nonatomic) FFSTPassResources decoded;
@property(nonatomic) ff_vertex_resources *graph;
@property(nonatomic) FFSTExecutorAttachments imported;
@property(nonatomic,strong) NSMutableArray<NSValue *> *tables;
@end
@implementation FFSTRenderContext
- (void)dealloc {
    for(NSValue *value in _tables)ff_vertex_resources_destroy(value.pointerValue);
    ff_vertex_resources_destroy(_graph);ffst_pass_resources_destroy(_decoded);ffst_executor_release(_imported);
}
@end
static BOOL pass_u64(id object,uint64_t maximum,uint64_t *out) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType];if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0]))return NO;
    const char *text=[[object stringValue] UTF8String];if(!text||!*text||strlen(text)>20)return NO;
    uint64_t value=0;for(const char *p=text;*p;++p){if(*p<'0'||*p>'9')return NO;unsigned digit=(unsigned)(*p-'0');
        if(digit>maximum||value>(maximum-digit)/10)return NO;value=value*10+digit;}*out=value;return YES;
}
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
static NSString *pass_hash_name(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];char text[65];CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    for(unsigned i=0;i<32;++i)snprintf(text+2*i,3,"%02x",hash[i]);return [NSString stringWithFormat:@"pass-lib-%s.metallib",text];
}
static id<MTLLibrary> pass_library(id<MTLDevice> device,int directory,id file,FFSTPassLibraryResolver resolver,
    NSMutableDictionary<NSString *,id<MTLLibrary>> *cache,uint64_t *bytes) {
    if(![file isKindOfClass:[NSString class]]||![file length]||[file length]>128)return nil;
    id<MTLLibrary> library=cache[file];if(library)return library;
    if(resolver)library=resolver(file);
    else {
        if([file length]!=82||![file hasPrefix:@"pass-lib-"]||![file hasSuffix:@".metallib"])return nil;
        NSData *blob=pass_read(directory,[file fileSystemRepresentation],8u*1024u*1024u);
        if(!blob||![pass_hash_name(blob) isEqual:file]||blob.length>64u*1024u*1024u-*bytes)return nil;
        dispatch_data_t data=dispatch_data_create(blob.bytes,blob.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        NSError *error=nil;library=[device newLibraryWithData:data error:&error];if(error)return nil;*bytes+=blob.length;
    }
    if(!library||library.device.registryID!=device.registryID)return nil;cache[file]=library;return library;
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
static FFSTRenderPipeline *pass_pipeline(id<MTLDevice> device,int directory,NSDictionary *record,NSDictionary *attachments,NSUInteger identifier,
    FFSTPassLibraryResolver resolver,NSMutableDictionary *libraries,uint64_t *bytes) {
    uint64_t value,mask;NSDictionary *state=record[@"state"];
    if(!pass_record(record)||!pass_record(state)||!pass_u64(record[@"id"],FFST_PASS_DRAW_LIMIT,&value)||value!=identifier||
       !pass_u64(record[@"topology"],MTLPrimitiveTopologyClassTriangle,&value)||!pass_u64(record[@"ia_slot_mask"],UINT32_MAX,&mask))return nil;
    NSUInteger topology=(NSUInteger)value;
    for(NSString *key in @[@"samples",@"depth_format",@"stencil_format"])
        if(!pass_u64(state[key],UINT32_MAX,&value)||![state[key] isEqual:attachments[key]])return nil;
    if(![record[@"vertex_function"] isKindOfClass:[NSString class]]||![record[@"fragment_function"] isKindOfClass:[NSString class]]||
       ![record[@"vertex_function"] length]||[record[@"vertex_function"] length]>512||![record[@"fragment_function"] length]||[record[@"fragment_function"] length]>512)return nil;
    id<MTLLibrary> vertex=pass_library(device,directory,record[@"vertex_file"],resolver,libraries,bytes),fragment=pass_library(device,directory,record[@"fragment_file"],resolver,libraries,bytes);
    id<MTLFunction> vs=[vertex newFunctionWithName:record[@"vertex_function"]],ps=[fragment newFunctionWithName:record[@"fragment_function"]];
    if(!vs||!ps||vs.functionType!=MTLFunctionTypeVertex||ps.functionType!=MTLFunctionTypeFragment||vs.stageInputAttributes.count)return nil;
    MTLRenderPipelineDescriptor *d=[MTLRenderPipelineDescriptor new];d.vertexFunction=vs;d.fragmentFunction=ps;d.inputPrimitiveTopology=topology;
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
    FFSTRenderPipeline *result=[FFSTRenderPipeline new];ff_draw_layout layout;
    if(!pipeline||error||!ff_shader_layout(reflection,(uint32_t)mask,&layout)||!pass_layout_matches(record,&layout))return nil;
    result.state=pipeline;result.layout=layout;return result;
}
static MTLStencilDescriptor *pass_stencil(id record) {
    if(!pass_numbers(record,6))return nil;uint64_t value;
    for(unsigned i=0;i<6;++i)if(!pass_u64(record[i],i<4?7:UINT32_MAX,&value))return nil;
    MTLStencilDescriptor *s=[MTLStencilDescriptor new];s.stencilCompareFunction=[record[0] unsignedIntegerValue];s.stencilFailureOperation=[record[1] unsignedIntegerValue];
    s.depthFailureOperation=[record[2] unsignedIntegerValue];s.depthStencilPassOperation=[record[3] unsignedIntegerValue];s.readMask=[record[4] unsignedIntValue];s.writeMask=[record[5] unsignedIntValue];return s;
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
static FFSTRenderDraw *pass_draw(id<MTLDevice> device,NSDictionary *record,FFSTRenderPipeline *pipeline,const FFSTPassDrawInfo *info,NSUInteger width,NSUInteger height) {
    if(!pass_record(record)||!pass_draw_matches(record,info)||!pass_numbers(record[@"viewport"],6)||!pass_numbers(record[@"scissor"],4)||
       !pass_numbers(record[@"raster"],7)||!pass_numbers(record[@"blend_constant"],4))return nil;
    NSArray *v=record[@"viewport"],*s=record[@"scissor"],*r=record[@"raster"],*b=record[@"blend_constant"];uint64_t scissor[4],value;
    for(unsigned i=0;i<4;++i)if(!pass_u64(s[i],UINT32_MAX,&scissor[i])||!pass_u64(r[i],i==1?2:1,&value)||!isfinite([b[i] floatValue]))return nil;
    if(scissor[0]>width||scissor[1]>height||!scissor[2]||!scissor[3]||scissor[2]>width-scissor[0]||scissor[3]>height-scissor[1]||
       [v[2] doubleValue]<=0||[v[3] doubleValue]<=0||[v[4] doubleValue]<0||[v[5] doubleValue]>1||[v[4] doubleValue]>[v[5] doubleValue])return nil;
    for(unsigned i=4;i<7;++i)if(!isfinite([r[i] floatValue]))return nil;
    if(!pass_u64(record[@"stencil_ref"],255,&value))return nil;BOOL valid;
    id<MTLDepthStencilState> depth=pass_depth(device,record[@"depth_state"],&valid);if(!valid)return nil;
    FFSTRenderDraw *draw=[FFSTRenderDraw new];draw.pipeline=pipeline;draw.depth=depth;draw.info=*info;draw.raster=r;draw.blend=b;draw.stencil=(uint32_t)value;
    draw.viewport=(MTLViewport){[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue],[v[3] doubleValue],[v[4] doubleValue],[v[5] doubleValue]};
    draw.scissor=(MTLScissorRect){scissor[0],scissor[1],scissor[2],scissor[3]};return draw;
}
static NSUInteger pass_pixel_size(MTLPixelFormat format) {
    if(format==MTLPixelFormatRGB10A2Unorm||format==MTLPixelFormatRG11B10Float)return 4;return ff_texture_pixel_size((uint32_t)format);
}
static id<MTLTexture> pass_texture(id<MTLDevice> device,MTLPixelFormat format,NSUInteger width,NSUInteger height,NSUInteger samples) {
    MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.sampleCount=samples;d.textureType=samples>1?MTLTextureType2DMultisample:MTLTextureType2D;d.storageMode=MTLStorageModePrivate;
    d.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;return [device newTextureWithDescriptor:d];
}
FFSTPassExecution *ffst_pass_execute(int directory,NSDictionary *manifest,FFSTPassLibraryResolver resolver,BOOL (^cancelled)(void),NSString **failure) {
    if(failure)*failure=nil;FFSTRenderContext *context=[FFSTRenderContext new];context.tables=[NSMutableArray array];
#define FAIL(reason) do{if(failure)*failure=@reason;return nil;}while(0)
#define CANCEL() do{if(cancelled&&cancelled())FAIL("pass execution cancelled");}while(0)
    CANCEL();struct stat stat;
    if(directory<0||fstat(directory,&stat)||!S_ISDIR(stat.st_mode)||stat.st_uid!=getuid()||(stat.st_mode&077)||!pass_record(manifest)||
       ![manifest[@"format"] isEqual:@"bedrock-native-pass-replay"]||![manifest[@"version"] isEqual:@2]||!pass_record(manifest[@"attachments"]))FAIL("invalid pass manifest");
    NSDictionary *a=manifest[@"attachments"];uint64_t cut,registry,width,height,samples,format,depth_format,stencil_format,value;
    if(!pass_u64(manifest[@"cut_id"],UINT64_MAX,&cut)||!cut||!pass_u64(a[@"device_id"],UINT64_MAX,&registry)||!registry||
       !pass_u64(a[@"width"],8192,&width)||!width||!pass_u64(a[@"height"],8192,&height)||!height||!pass_u64(a[@"samples"],8,&samples)||
       !pass_u64(a[@"pixel_format"],UINT32_MAX,&format)||!ffst_attachment_format_supported(format,FFST_COLOR)||
       !pass_u64(a[@"depth_format"],UINT32_MAX,&depth_format)||(depth_format&&!ffst_attachment_format_supported(depth_format,FFST_DEPTH))||
       !pass_u64(a[@"stencil_format"],UINT32_MAX,&stencil_format)||(stencil_format&&!ffst_attachment_format_supported(stencil_format,FFST_STENCIL))||
       ![manifest[@"resource_cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)cut]])FAIL("invalid pass attachment bounds");
    id<MTLDevice> device=nil;for(id<MTLDevice> d in MTLCopyAllDevices())if(d.registryID==registry){device=d;break;}
    if(!device||!ffst_sample_count_supported(device,samples))FAIL("pass Metal device or sample count unavailable");
    uint64_t loads[3];NSArray *keys=@[@"color_load",@"depth_load",@"stencil_load"];
    for(unsigned i=0;i<3;++i)if(!pass_u64(a[keys[i]],MTLLoadActionClear,&loads[i]))FAIL("invalid pass load action");
    BOOL alias,complete;if(!pass_bool(a[@"depth_stencil_alias"],&alias)||!pass_bool(manifest[@"complete_pass"],&complete)||
       !pass_numbers(a[@"clear"],4)||![a[@"depth_clear"] isKindOfClass:[NSNumber class]]||!isfinite([a[@"depth_clear"] doubleValue])||
       [a[@"depth_clear"] doubleValue]<0||[a[@"depth_clear"] doubleValue]>1||!pass_u64(a[@"stencil_clear"],255,&value))FAIL("invalid pass clear or alias state");
    if(alias&&(!depth_format||depth_format!=stencil_format))FAIL("invalid combined depth stencil formats");
    NSArray *pipeline_records=manifest[@"pipelines"],*draw_records=manifest[@"draws"];
    if(![pipeline_records isKindOfClass:[NSArray class]]||!pipeline_records.count||pipeline_records.count>FFST_PASS_DRAW_LIMIT||
       ![draw_records isKindOfClass:[NSArray class]]||!draw_records.count||draw_records.count>FFST_PASS_DRAW_LIMIT)FAIL("invalid pass draw/pipeline count");
    NSData *graph_data=pass_read(directory,"draw-resource-cut.json",8u*1024u*1024u);
    NSDictionary *graph=graph_data?[NSJSONSerialization JSONObjectWithData:graph_data options:0 error:nil]:nil;
    if(!pass_record(graph)||![graph[@"cut_id"] isEqual:manifest[@"resource_cut_id"]])FAIL("pass resource graph cut mismatch");
    context.decoded=ffst_pass_resources_load(directory,graph);size_t captured=ffst_pass_resources_draw_count(context.decoded);
    if(!context.decoded||!pass_u64(manifest[@"captured_prefix_draws"],FFST_PASS_DRAW_LIMIT,&value)||value!=captured||draw_records.count>captured||
       (complete&&draw_records.count!=captured))FAIL("pass/resource prefix count mismatch");
    NSMutableArray<FFSTRenderPipeline *> *pipelines=[NSMutableArray array];NSMutableDictionary *library_cache=[NSMutableDictionary dictionary];uint64_t library_bytes=0;
    for(NSUInteger i=0;i<pipeline_records.count;++i){CANCEL();FFSTRenderPipeline *p=pass_pipeline(device,directory,pipeline_records[i],a,i,resolver,library_cache,&library_bytes);
        if(!p)FAIL("pass pipeline shader/reflection/state rejected");[pipelines addObject:p];}
    NSMutableArray<FFSTRenderDraw *> *draws=[NSMutableArray array];NSMutableIndexSet *used=[NSMutableIndexSet indexSet];uint64_t invocations=0;
    uint32_t material_draws=0,material_geometry_draws=0;
    for(NSUInteger i=0;i<draw_records.count;++i){CANCEL();NSDictionary *record=draw_records[i];uint64_t p,resource;
        if(!pass_record(record)||!pass_u64(record[@"pipeline"],pipelines.count-1,&p)||!pass_u64(record[@"resources"],captured-1,&resource)||resource!=i)FAIL("unordered pass draw references");
        FFSTPassDrawInfo info;ff_draw_bindings bindings;FFSTRenderPipeline *pipeline=pipelines[(NSUInteger)p];ff_draw_layout expected_layout=pipeline.layout;
        if(!ffst_pass_resources_draw_info(context.decoded,i,&info)||!ffst_pass_resources_draw_bindings(context.decoded,i,&expected_layout,&bindings))FAIL("pass binding/tuple reflection mismatch");
        FFSTRenderDraw *draw=pass_draw(device,record,pipeline,&info,(NSUInteger)width,(NSUInteger)height);if(!draw)FAIL("invalid pass dynamic draw state");
        BOOL material=NO;for(unsigned stage=0;stage<2;++stage)for(size_t j=0;j<bindings.argument_count[stage];++j)
            if(bindings.arguments[stage][j].kind==FF_FIELD_TEXTURE&&bindings.arguments[stage][j].value)material=YES;
        draw.material=material;draw.geometry=info.count>6&&pipeline.layout.ia_slot_mask&&pipeline.layout.constant_count[0];
        BOOL declared;if(!pass_bool(record[@"material_geometry"],&declared)||declared!=(draw.material&&draw.geometry))FAIL("pass material selection metadata mismatch");
        if(material)++material_draws;if(material&&draw.geometry)++material_geometry_draws;
        if(info.count*info.instances>10000000-invocations)FAIL("pass invocation limit exceeded");invocations+=info.count*info.instances;
        [draws addObject:draw];[used addIndex:(NSUInteger)p];
    }
    if(used.count!=pipelines.count||!pass_u64(manifest[@"vertex_invocations"],10000000,&value)||value!=invocations||
       !pass_u64(manifest[@"material_draw_count"],FFST_PASS_DRAW_LIMIT,&value)||value!=material_draws||
       !pass_u64(manifest[@"material_geometry_draw_count"],FFST_PASS_DRAW_LIMIT,&value)||value!=material_geometry_draws)FAIL("pass aggregate metadata mismatch");
    size_t count,texture_count,sampler_count;const ff_vertex_snapshot *snapshots=ffst_pass_resources_snapshots(context.decoded,&count);
    const ff_texture_snapshot *textures=ffst_pass_resources_textures(context.decoded,&texture_count);const ff_sampler_snapshot *samplers=ffst_pass_resources_samplers(context.decoded,&sampler_count);
    context.graph=ff_vertex_resources_create_graph(device,snapshots,count,textures,texture_count,samplers,sampler_count);if(!context.graph)FAIL("native pass asset graph creation failed");
    for(NSUInteger i=0;i<draws.count;++i){CANCEL();ff_draw_bindings bindings;FFSTRenderPipeline *p=draws[i].pipeline;ff_draw_layout expected_layout=p.layout;
        if(!ffst_pass_resources_draw_bindings(context.decoded,i,&expected_layout,&bindings))FAIL("native pass draw bindings unavailable");
        ff_vertex_resources *tables=ff_vertex_resources_create_draw_shared(context.graph,&bindings);if(!tables)FAIL("native pass table relocation failed");[context.tables addObject:[NSValue valueWithPointer:tables]];}
    NSUInteger pixel_bytes=pass_pixel_size((MTLPixelFormat)format);if(!pixel_bytes||width>SIZE_MAX/pixel_bytes)FAIL("unsupported pass readback format");
    NSUInteger row=((NSUInteger)width*pixel_bytes+255)&~(NSUInteger)255;
    if(height>SIZE_MAX/row||row*height>256u*1024u*1024u)FAIL("pass readback byte limit exceeded");NSUInteger length=row*(NSUInteger)height;
    BOOL wanted[]={loads[0]==MTLLoadActionLoad,depth_format&&loads[1]==MTLLoadActionLoad,stencil_format&&loads[2]==MTLLoadActionLoad};
    id<MTLTexture> imported[3]={nil};size_t needed=wanted[0]+wanted[1]+wanted[2];
    if(needed){if(!pass_u64(manifest[@"shared_attachment_cut"],UINT64_MAX,&value)||value!=cut)FAIL("pass Load cut not declared");
        context.imported=ffst_executor_acquire(device,cut,15);if(!context.imported||ffst_executor_attachment_count(context.imported)!=needed)FAIL("pass exact Load bundle unavailable");
        uint64_t formats[]={format,depth_format,stencil_format};
        for(unsigned i=0;i<3;++i){imported[i]=ffst_executor_texture(context.imported,(FFSTAttachmentRole)(i+1),0);
            if(wanted[i]){id<MTLTexture> t=imported[i];if(!t||t.width!=width||t.height!=height||t.sampleCount!=samples||t.pixelFormat!=formats[i]||t.device.registryID!=registry)FAIL("pass imported attachment mismatch");}
            else if(imported[i])FAIL("pass imported unexpected attachment");}
    }else if(manifest[@"shared_attachment_cut"])FAIL("pass has unexpected Load bundle");
    id<MTLTexture> resolved=pass_texture(device,(MTLPixelFormat)format,(NSUInteger)width,(NSUInteger)height,1);
    id<MTLTexture> target=imported[0]?:samples>1?pass_texture(device,(MTLPixelFormat)format,(NSUInteger)width,(NSUInteger)height,(NSUInteger)samples):resolved;
    id<MTLTexture> depth=depth_format?(imported[1]?:pass_texture(device,(MTLPixelFormat)depth_format,(NSUInteger)width,(NSUInteger)height,(NSUInteger)samples)):nil;
    id<MTLTexture> stencil=stencil_format?(imported[2]?:(alias?depth:pass_texture(device,(MTLPixelFormat)stencil_format,(NSUInteger)width,(NSUInteger)height,(NSUInteger)samples))):nil;
    if(alias&&(imported[1]||imported[2])){if(imported[1]&&imported[2]&&imported[1]!=imported[2])FAIL("pass depth stencil alias lost");depth=stencil=imported[1]?:imported[2];}
    if(!resolved||!target||(depth_format&&!depth)||(stencil_format&&!stencil))FAIL("pass target allocation failed");
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> command=[queue commandBuffer];
    id<MTLBuffer> pixels=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBuffer> baseline=loads[0]!=MTLLoadActionDontCare?[device newBufferWithLength:length options:MTLResourceStorageModeShared]:nil;
    if(!queue||!command||!pixels||(loads[0]!=MTLLoadActionDontCare&&!baseline))FAIL("pass command/readback allocation failed");
    NSArray *clear=a[@"clear"];MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture=target;pass.colorAttachments[0].loadAction=(MTLLoadAction)loads[0];
    pass.colorAttachments[0].clearColor=MTLClearColorMake([clear[0] doubleValue],[clear[1] doubleValue],[clear[2] doubleValue],[clear[3] doubleValue]);
    pass.colorAttachments[0].storeAction=samples>1?MTLStoreActionMultisampleResolve:MTLStoreActionStore;if(samples>1)pass.colorAttachments[0].resolveTexture=resolved;
    if(baseline){MTLStoreAction store=pass.colorAttachments[0].storeAction;if(samples>1&&loads[0]==MTLLoadActionLoad)pass.colorAttachments[0].storeAction=MTLStoreActionStoreAndMultisampleResolve;
        id<MTLRenderCommandEncoder> initial=[command renderCommandEncoderWithDescriptor:pass];if(!initial)FAIL("pass baseline encoder failed");[initial endEncoding];pass.colorAttachments[0].storeAction=store;
        id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];if(!blit)FAIL("pass baseline readback failed");
        [blit copyFromTexture:samples>1?resolved:target sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake((NSUInteger)width,(NSUInteger)height,1)
            toBuffer:baseline destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:length];[blit endEncoding];}
    pass.depthAttachment.texture=depth;pass.depthAttachment.loadAction=(MTLLoadAction)loads[1];pass.depthAttachment.storeAction=MTLStoreActionDontCare;pass.depthAttachment.clearDepth=[a[@"depth_clear"] doubleValue];
    pass.stencilAttachment.texture=stencil;pass.stencilAttachment.loadAction=(MTLLoadAction)loads[2];pass.stencilAttachment.storeAction=MTLStoreActionDontCare;pass.stencilAttachment.clearStencil=[a[@"stencil_clear"] unsignedIntValue];
    CANCEL();id<MTLRenderCommandEncoder> encoder=[command renderCommandEncoderWithDescriptor:pass];if(!encoder)FAIL("native pass encoder unavailable");
    for(NSUInteger i=0;i<draws.count;++i){if(cancelled&&cancelled()){[encoder endEncoding];FAIL("pass execution cancelled");}
        FFSTRenderDraw *d=draws[i];[encoder setRenderPipelineState:d.pipeline.state];[encoder setDepthStencilState:d.depth];[encoder setViewport:d.viewport];[encoder setScissorRect:d.scissor];
        [encoder setTriangleFillMode:[d.raster[0] unsignedIntegerValue]];[encoder setCullMode:[d.raster[1] unsignedIntegerValue]];
        [encoder setDepthClipMode:[d.raster[2] unsignedIntegerValue]];[encoder setFrontFacingWinding:[d.raster[3] unsignedIntegerValue]];
        [encoder setDepthBias:[d.raster[4] floatValue] slopeScale:[d.raster[5] floatValue] clamp:[d.raster[6] floatValue]];
        [encoder setBlendColorRed:[d.blend[0] floatValue] green:[d.blend[1] floatValue] blue:[d.blend[2] floatValue] alpha:[d.blend[3] floatValue]];[encoder setStencilReferenceValue:d.stencil];
        ff_vertex_resources *tables=[context.tables[i] pointerValue];ff_vertex_resources_bind(tables,encoder);
        if(d.info.indexed){NSUInteger offset;id<MTLBuffer> index=ff_vertex_resources_index(tables,&offset);if(!index){[encoder endEncoding];FAIL("pass index buffer unavailable");}
            [encoder drawIndexedPrimitives:d.info.primitive indexCount:(NSUInteger)d.info.index_count indexType:d.info.index_type indexBuffer:index indexBufferOffset:offset
                instanceCount:(NSUInteger)d.info.instances baseVertex:d.info.base_vertex baseInstance:(NSUInteger)d.info.base_instance];}
        else [encoder drawPrimitives:d.info.primitive vertexStart:(NSUInteger)d.info.start vertexCount:(NSUInteger)d.info.count instanceCount:(NSUInteger)d.info.instances baseInstance:(NSUInteger)d.info.base_instance];
    }
    [encoder endEncoding];id<MTLBlitCommandEncoder> readback=[command blitCommandEncoder];if(!readback)FAIL("pass output blit unavailable");
    if(samples==1&&target!=resolved)[readback copyFromTexture:target toTexture:resolved];
    [readback copyFromTexture:resolved sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake((NSUInteger)width,(NSUInteger)height,1)
        toBuffer:pixels destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:length];[readback endEncoding];
    if(context.imported&&!ffst_executor_finish(context.imported,command))FAIL("pass Load completion hook rejected");
    [command commit];[command waitUntilCompleted];if(command.status!=MTLCommandBufferStatusCompleted)FAIL("native ordered pass GPU failed");
    if(context.imported&&ffst_executor_wait(context.imported,15)!=FFST_OK)FAIL("pass Load retirement not acknowledged");
    ffst_executor_release(context.imported);context.imported=NULL;
    NSNumber *changed=nil;if(baseline){uint64_t count_changed=0;const uint8_t *after=pixels.contents,*before=baseline.contents;
        for(NSUInteger y=0;y<height;++y)for(NSUInteger x=0;x<width;++x)if(memcmp(after+y*row+x*pixel_bytes,before+y*row+x*pixel_bytes,pixel_bytes))++count_changed;changed=@(count_changed);}
    FFSTPassExecution *result=[FFSTPassExecution new];result.texture=resolved;result.pixels=[NSData dataWithBytes:pixels.contents length:length];result.rowBytes=row;
    result.metrics=@{@"format":@"bedrock-native-pass-result",@"version":@2,@"status":@"completed",@"cut_id":@(cut),@"device_id":@(registry),
        @"width":@(width),@"height":@(height),@"pixel_format":@(format),@"row_bytes":@(row),@"draw_count":@(draws.count),@"pipeline_count":@(pipelines.count),
        @"captured_prefix_draws":@(captured),@"complete_pass":@(complete),@"material_draw_count":@(material_draws),@"material_geometry_draw_count":@(material_geometry_draws),
        @"vertex_invocations":@(invocations),@"changed_pixels":changed?:(id)[NSNull null],@"load_attachments_owned":@(needed!=0),
        @"buffer_count":@(count),@"texture_count":@(texture_count),@"sampler_count":@(sampler_count)};
    return result;
#undef CANCEL
#undef FAIL
}
