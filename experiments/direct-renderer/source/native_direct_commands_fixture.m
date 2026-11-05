#import "native_direct_commands.h"
#include "direct_commands.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>
#define CHECK(x) do {if(!(x)){fprintf(stderr,"failed line %d: %s\n",__LINE__,#x);return 1;}}while(0)
static int count_visit(void *context,const FFDCRecord *r,const void *payload) {
    (void)r;(void)payload;(*(int *)context)++;return 1;
}
@class FFDCPending;
@interface FFDCReceiver (FixtureCompletion)
- (void)recordGPUCompletion:(FFDCPending *)pending success:(BOOL)success;
@end
/* No Metal commands are created in this policy test: synthesize completion
 * callbacks in reverse order to cover an earlier GPU failure explicitly. */
static int check_failure_completion_order(id<MTLDevice> device) {
    FFDCReceiver *receiver=[[FFDCReceiver alloc]initWithDevice:device];CHECK(receiver);
    NSMutableArray *pending=[receiver valueForKey:@"pending"],*results=[NSMutableArray array];
    dispatch_semaphore_t done=dispatch_semaphore_create(0);Class cls=NSClassFromString(@"FFDCPending");CHECK(cls);
    id first=[cls new],second=[cls new];
    for(unsigned i=0;i<2;++i){id item=i?second:first;[item setValue:@(i+1) forKey:@"serial"];
        [item setValue:@(i+11) forKey:@"completionID"];
        FFDCCompletion callback=^(uint64_t serial,uint64_t completion,BOOL ok){
            [results addObject:@[@(serial),@(completion),@(ok)]];if(serial==2)dispatch_semaphore_signal(done);};
        [item setValue:[callback copy] forKey:@"completion"];[pending addObject:item];}
    [receiver setValue:@2 forKey:@"active"];
    [receiver recordGPUCompletion:second success:YES];[receiver recordGPUCompletion:first success:NO];
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
    CHECK(( [results isEqual:@[@[@1,@11,@NO],@[@2,@12,@NO]] ] ));return 0;
}
static int check_multiflight(id<MTLDevice> device,int failureMode) {
    FFDCReceiver *receiver=[[FFDCReceiver alloc]initWithDevice:device];CHECK(receiver);
    /* Hold the receiver's queue ahead of all four real submissions. This makes
     * destroy/recreate happen while the old generation is still in flight. */
    id<MTLCommandQueue> receiverQueue=[receiver valueForKey:@"queue"];
    id<MTLSharedEvent> gate=[device newSharedEvent];id<MTLCommandBuffer> barrier=[receiverQueue commandBuffer];
    CHECK(receiverQueue&&gate&&barrier);[barrier encodeWaitForEvent:gate value:1];[barrier commit];
    dispatch_semaphore_t entered=dispatch_semaphore_create(0),release=dispatch_semaphore_create(0),closed=dispatch_semaphore_create(0);
    NSMutableArray<NSNumber *> *receipts=[NSMutableArray array];
    __block BOOL allOK=YES,closeAccepted=NO,failedAdmission=NO;
    unsigned char wire[4096], old[16], newer[16];memset(old,0x35,sizeof(old));memset(newer,0xa6,sizeof(newer));
    for(uint64_t serial=1;serial<=4;++serial){
        FFDCWriter w;CHECK(ffdc_begin(&w,wire,sizeof(wire),serial,11,1,serial,serial+100));
        FFPSEvent event={0};
        if(serial==1){event=(FFPSEvent){.operation=FFPS_CREATE,.target={100,1},.length=16};CHECK(ffdc_emit(&w,&event));
            event=(FFPSEvent){.operation=FFPS_CREATE,.target={101,1},.length=16};CHECK(ffdc_emit(&w,&event));
            event=(FFPSEvent){.operation=FFPS_WRITE,.target={100,1},.bytes=old,.length=16};CHECK(ffdc_emit(&w,&event));}
        if(serial==2){event=(FFPSEvent){.operation=FFPS_COPY,.target={101,1},.source={100,1},.length=16};CHECK(ffdc_emit(&w,&event));}
        if(serial==3){event=(FFPSEvent){.operation=FFPS_DESTROY,.target={100,1}};CHECK(ffdc_emit(&w,&event));
            event=(FFPSEvent){.operation=FFPS_CREATE,.target={100,2},.length=16};CHECK(ffdc_emit(&w,&event));
            event=(FFPSEvent){.operation=FFPS_CREATE,.target={102,1},.length=16};CHECK(ffdc_emit(&w,&event));
            event=(FFPSEvent){.operation=FFPS_WRITE,.target={100,2},.bytes=newer,.length=16};CHECK(ffdc_emit(&w,&event));}
        if(serial==4){event=(FFPSEvent){.operation=FFPS_COPY,.target={102,1},.source={100,2},.length=16};CHECK(ffdc_emit(&w,&event));}
        CHECK(ffdc_seal(&w));
        CHECK([receiver submit:wire length:w.length completion:^(uint64_t n,uint64_t completion,BOOL ok){
            [receipts addObject:@(n)];allOK=allOK&&(ok==(failureMode==0||n<2))&&completion==n+100;
            if(n==1){dispatch_semaphore_signal(entered);dispatch_semaphore_wait(release,DISPATCH_TIME_FOREVER);
                if(failureMode==2)@throw [NSException exceptionWithName:@"FixtureReceiptFailure" reason:nil userInfo:nil];}
            if(n==2&&failureMode==2){unsigned char extra[256];FFDCWriter writer;
                if(ffdc_begin(&writer,extra,sizeof(extra),5,11,1,5,105)&&ffdc_seal(&writer))
                    failedAdmission=[receiver submit:extra length:writer.length completion:^(uint64_t a,uint64_t b,BOOL c){(void)a;(void)b;(void)c;}]==FFDCSubmitFailed;}
            if(n==4)closeAccepted=[receiver closeWithCompletion:^{dispatch_semaphore_signal(closed);}];
        }]==FFDCSubmitAccepted);
    }
    FFDCWriter fifth;CHECK(ffdc_begin(&fifth,wire,sizeof(wire),5,11,1,5,105));CHECK(ffdc_seal(&fifth));
    CHECK([receiver submit:wire length:fifth.length completion:^(uint64_t a,uint64_t b,BOOL c){(void)a;(void)b;(void)c;}] == FFDCSubmitBusy);
    /* Test the ordered failure watermark independently of Metal error
     * injection: all commands still execute successfully on the real GPU. */
    if(failureMode==1)[receiver setValue:@2 forKey:@"firstFailedSerial"];
    CHECK(receipts.count==0);gate.signaledValue=1;
    CHECK(dispatch_semaphore_wait(entered,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
    dispatch_semaphore_signal(release);CHECK(dispatch_semaphore_wait(closed,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);
    CHECK((closeAccepted&&allOK&&[receipts isEqual:@[@1,@2,@3,@4]]));
    CHECK(failureMode!=2||failedAdmission);
    CHECK(![receiver closeWithCompletion:^{}]);
    CHECK([receiver submit:wire length:fifth.length completion:^(uint64_t a,uint64_t b,BOOL c){(void)a;(void)b;(void)c;}] == FFDCSubmitFailed);
    id<MTLCommandBuffer> command=[[device newCommandQueue] commandBuffer];FFPRBatch *batch=[[FFPRBatch alloc]initWithCommandBuffer:command];
    id<MTLBuffer> b=[receiver.registry buffer:(FFPRHandle){101,1} batch:batch],c=[receiver.registry buffer:(FFPRHandle){102,1} batch:batch];
    id<MTLBuffer> result=[device newBufferWithLength:32 options:MTLResourceStorageModeShared];CHECK(b&&c&&result);
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];CHECK(blit);
    [blit copyFromBuffer:b sourceOffset:0 toBuffer:result destinationOffset:0 size:16];
    [blit copyFromBuffer:c sourceOffset:0 toBuffer:result destinationOffset:16 size:16];[blit endEncoding];
    CHECK([batch finish]);[command commit];[command waitUntilCompleted];CHECK(command.status==MTLCommandBufferStatusCompleted);
    CHECK(!memcmp(result.contents,old,16)&&!memcmp((char *)result.contents+16,newer,16));return 0;
}
static int check_bound_draws(id<MTLDevice> device) {
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
    "struct Material { texture2d<float> image [[id(0)]]; sampler samp [[id(1)]]; device const float4 *tint [[id(2)]]; };\n"
    "vertex float4 v(uint i [[vertex_id]]) { const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\n"
    "fragment float4 f(constant Material &m [[buffer(30)]]) { return m.image.sample(m.samp,float2(0.5))*m.tint[0]; }";
    NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];CHECK(library&&!error);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[library newFunctionWithName:@"v"];pd.fragmentFunction=[library newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    MTLRenderPipelineReflection *reflection=nil;id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&error];CHECK(pipeline&&reflection&&!error);
    FFSTPipelineRegistry *registry=[[FFSTPipelineRegistry alloc]initWithDevice:device maxObjects:4];CHECK([registry defineObject:1 generation:1 pipeline:pipeline reflection:reflection iaMask:0]);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.usage=MTLTextureUsageShaderRead;td.storageMode=MTLStorageModeShared;
    __block id<MTLTexture> texture=[device newTextureWithDescriptor:td];unsigned char white[4]={255,255,255,255};CHECK(texture);[texture replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:white bytesPerRow:4];
    MTLSamplerDescriptor *sd=[MTLSamplerDescriptor new];sd.supportArgumentBuffers=YES;__block id<MTLSamplerState> sampler=[device newSamplerStateWithDescriptor:sd];CHECK(sampler);
    td.width=2;td.usage=MTLTextureUsageRenderTarget|MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
    id<MTLTexture> target=[device newTextureWithDescriptor:td];CHECK(target);
    id<MTLTexture> aliasView=[target newTextureViewWithPixelFormat:target.pixelFormat];CHECK(aliasView&&aliasView!=target);
    FFDCCompatibleTarget compatibility=^BOOL(FFSTPipelineBinding *binding,id<MTLTexture> dst){return binding.pipeline==pipeline&&dst==target&&dst.pixelFormat==MTLPixelFormatRGBA8Unorm&&dst.sampleCount==1;};
    /* Test owns both separate allocations and verifies their exact identities. */
    FFDCTextureDisjoint disjoint=^BOOL(id<MTLTexture> dst,FFPRHandle h,id<MTLTexture> sampled){return dst==target&&h.object==20&&h.generation==1&&sampled==texture;};
    FFDCReceiver *receiver=[[FFDCReceiver alloc]initWithDevice:device pipelines:registry targetLookup:^id<MTLTexture>(uint64_t o,uint64_t g){return o==50&&g==1?target:nil;}
        textureLookup:^id<MTLTexture>(FFPRHandle h){return h.object==20&&h.generation==1?texture:nil;}
        samplerLookup:^id<MTLSamplerState>(FFPRHandle h){return h.object==30&&h.generation==1?sampler:nil;}
        targetCompatibility:compatibility textureDisjoint:disjoint];CHECK(receiver);
    id<MTLCommandQueue> q=[receiver valueForKey:@"queue"];id<MTLSharedEvent> gate=[device newSharedEvent];id<MTLCommandBuffer> barrier=[q commandBuffer];CHECK(gate&&barrier);[barrier encodeWaitForEvent:gate value:1];[barrier commit];
    /* Each malformed semantic packet gets a new fail-stop receiver. */
    for(unsigned failure=0;failure<12;++failure){
        __block NSUInteger aliasChecks=0;
        FFDCTextureDisjoint badDisjoint=failure==9?nil:^BOOL(id<MTLTexture> dst,FFPRHandle h,id<MTLTexture> sampled){
            ++aliasChecks;return disjoint(dst,h,sampled);};
        FFDCCompatibleTarget badCompatibility=failure==10?nil:failure==11?^BOOL(FFSTPipelineBinding *b,id<MTLTexture> t){(void)b;(void)t;return NO;}:compatibility;
        FFDCReceiver *bad=[[FFDCReceiver alloc]initWithDevice:device pipelines:registry targetLookup:^id<MTLTexture>(uint64_t o,uint64_t g){return o==50&&g==1?target:nil;}
            textureLookup:^id<MTLTexture>(FFPRHandle h){return h.object==20&&h.generation==1?(failure==7?target:failure==8?aliasView:texture):nil;}
            samplerLookup:^id<MTLSamplerState>(FFPRHandle h){return h.object==30&&h.generation==1?sampler:nil;}
            targetCompatibility:badCompatibility textureDisjoint:badDisjoint];
        unsigned char packet[2048];FFDCWriter writer;CHECK(ffdc_begin(&writer,packet,sizeof(packet),1,13,1,1,1));
        float tint[4]={1,1,1,1};uint16_t indices[3]={0,1,2};
        FFPSEvent c={.operation=FFPS_CREATE,.target={10,1},.length=sizeof(tint)},write={.operation=FFPS_WRITE,.target={10,1},.length=sizeof(tint),.bytes=tint};
        FFPSEvent ci={.operation=FFPS_CREATE,.target={12,1},.length=sizeof(indices)};
        CHECK(ffdc_emit(&writer,&c)&&ffdc_emit(&writer,&write)&&ffdc_emit(&writer,&ci));
        float clear[4]={0,0,0,1};CHECK(ffdc_begin_render(&writer,50,1,clear)&&ffdc_bind_pipeline(&writer,1,1));
        FFDCLogicalField f[3]={ {.offset=0,.kind=FFDC_FIELD_TEXTURE,.object=20,.generation=1}, {.offset=8,.kind=FFDC_FIELD_SAMPLER,.object=30,.generation=1}, {.offset=16,.kind=FFDC_FIELD_BUFFER,.buffer={.object=10,.generation=1,.length=16}} };
        if(failure==0)f[0].generation=2;if(failure==1)f[1].generation=2;if(failure==2)f[2].buffer.generation=2;if(failure==3)f[2].buffer.offset=16;
        CHECK(ffdc_logical_table(&writer,FFDC_ARGUMENT_TABLE,FFDC_FRAGMENT,f,3));
        if(failure==4){FFDCScissor invalid={1,0,2,1};CHECK(ffdc_render_command(&writer,FFDC_SET_SCISSOR,&invalid,sizeof(invalid)));}
        if(failure==6){FFDCBufferBinding binding={.object=10,.generation=1,.stage=FFDC_VERTEX,.index=0};
            CHECK(ffdc_render_command(&writer,FFDC_SET_BUFFER,&binding,sizeof(binding)));}
        if(failure==5){FFDCIndexedDraw indexed={.object=12,.generation=1,.count=4,.primitive=MTLPrimitiveTypeTriangle,.instances=1};CHECK(ffdc_render_command(&writer,FFDC_DRAW_INDEXED,&indexed,sizeof(indexed)));}
        else {FFDCDraw draw={.count=3,.primitive=MTLPrimitiveTypeTriangle,.instances=1};CHECK(ffdc_render_command(&writer,FFDC_DRAW,&draw,sizeof(draw)));}
        CHECK(ffdc_end_render(&writer)&&ffdc_seal(&writer));
        CHECK([bad submit:packet length:writer.length completion:^(uint64_t a,uint64_t b,BOOL ok){(void)a;(void)b;(void)ok;}] == FFDCSubmitFailed);
        if(failure==7||failure==8)CHECK(aliasChecks==1);
    }
    unsigned char bytes[8192];FFDCWriter w;CHECK(ffdc_begin(&w,bytes,sizeof(bytes),1,12,1,1,101));
    float green[4]={0,1,0,1},red[4]={1,0,0,1};uint16_t indices[3]={0,1,2};const void *data[]={green,red,indices};size_t lengths[]={sizeof(green),sizeof(red),sizeof(indices)};
    for(unsigned i=0;i<3;++i){FFPSEvent create={.operation=FFPS_CREATE,.target={10+i,1},.length=lengths[i]};FFPSEvent write={.operation=FFPS_WRITE,.target={10+i,1},.length=lengths[i],.bytes=data[i]};CHECK(ffdc_emit(&w,&create)&&ffdc_emit(&w,&write));}
    float clear[4]={0,0,1,1};CHECK(ffdc_begin_render(&w,50,1,clear));CHECK(ffdc_bind_pipeline(&w,1,1));
    FFDCLogicalField fields[3]={ {.offset=0,.kind=FFDC_FIELD_TEXTURE,.object=20,.generation=1}, {.offset=8,.kind=FFDC_FIELD_SAMPLER,.object=30,.generation=1}, {.offset=16,.kind=FFDC_FIELD_BUFFER,.buffer={.object=10,.generation=1,.length=16}} };
    CHECK(ffdc_logical_table(&w,FFDC_ARGUMENT_TABLE,FFDC_FRAGMENT,fields,3));
    FFDCViewport viewport={0,0,2,1,0,1};FFDCRaster raster={0};
    CHECK(ffdc_render_command(&w,FFDC_SET_VIEWPORT,&viewport,sizeof(viewport))&&ffdc_render_command(&w,FFDC_SET_RASTER,&raster,sizeof(raster)));
    FFDCScissor left={0,0,1,1};CHECK(ffdc_render_command(&w,FFDC_SET_SCISSOR,&left,sizeof(left)));
    FFDCDraw draw={.count=3,.primitive=MTLPrimitiveTypeTriangle,.instances=1};CHECK(ffdc_render_command(&w,FFDC_DRAW,&draw,sizeof(draw)));
    fields[2].buffer.object=11;CHECK(ffdc_logical_table(&w,FFDC_ARGUMENT_TABLE,FFDC_FRAGMENT,fields,3));
    FFDCScissor right={1,0,1,1};CHECK(ffdc_render_command(&w,FFDC_SET_SCISSOR,&right,sizeof(right)));
    FFDCIndexedDraw indexed={.object=12,.generation=1,.count=3,.primitive=MTLPrimitiveTypeTriangle,.instances=1};CHECK(ffdc_render_command(&w,FFDC_DRAW_INDEXED,&indexed,sizeof(indexed)));
    CHECK(ffdc_end_render(&w));for(unsigned i=0;i<3;++i){FFPSEvent destroy={.operation=FFPS_DESTROY,.target={10+i,1}};CHECK(ffdc_emit(&w,&destroy));}CHECK(ffdc_seal(&w));
    __weak id<MTLTexture> weakTexture=texture;__weak id<MTLSamplerState> weakSampler=sampler;
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL ok=NO;
    CHECK([receiver submit:bytes length:w.length completion:^(uint64_t s,uint64_t c,BOOL success){ok=success&&s==1&&c==101;dispatch_semaphore_signal(done);}] == FFDCSubmitAccepted);
    CHECK([registry destroyObject:1 generation:1]);pipeline=nil;texture=nil;sampler=nil;CHECK(weakTexture&&weakSampler);
    gate.signaledValue=1;CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0&&ok);
    unsigned char pixels[8]={0};[target getBytes:pixels bytesPerRow:8 fromRegion:MTLRegionMake2D(0,0,2,1) mipmapLevel:0];
    const unsigned char expected[8]={0,255,0,255,255,0,0,255};CHECK(!memcmp(pixels,expected,sizeof(expected)));
    return 0;
}
static int check_reject_unqualified_ia(id<MTLDevice> device) {
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct V { device const float2 *data; uint stride; uint length; };\n"
        "vertex float4 v(uint i [[vertex_id]], constant V &in [[buffer(16)]]) { return float4(in.data[i],0,1); }\n"
        "fragment float4 f() { return float4(1,1,1,1); }";
    NSError *error=nil;id<MTLLibrary> lib=[device newLibraryWithSource:source options:nil error:&error];CHECK(lib&&!error);
    MTLRenderPipelineDescriptor *pd=[MTLRenderPipelineDescriptor new];pd.vertexFunction=[lib newFunctionWithName:@"v"];pd.fragmentFunction=[lib newFunctionWithName:@"f"];pd.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;
    MTLRenderPipelineReflection *reflection=nil;id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&error];CHECK(pipeline&&reflection&&!error);
    FFSTPipelineRegistry *registry=[[FFSTPipelineRegistry alloc]initWithDevice:device maxObjects:1];CHECK([registry defineObject:1 generation:1 pipeline:pipeline reflection:reflection iaMask:1]);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];td.usage=MTLTextureUsageRenderTarget;id<MTLTexture> target=[device newTextureWithDescriptor:td];CHECK(target);
    FFDCReceiver *receiver=[[FFDCReceiver alloc]initWithDevice:device pipelines:registry targetLookup:^id<MTLTexture>(uint64_t o,uint64_t g){return o==50&&g==1?target:nil;} textureLookup:nil samplerLookup:nil
        targetCompatibility:^BOOL(FFSTPipelineBinding *binding,id<MTLTexture> dst){return binding.pipeline==pipeline&&dst==target&&dst.pixelFormat==MTLPixelFormatRGBA8Unorm&&dst.sampleCount==1;} textureDisjoint:nil];
    unsigned char bytes[1024];FFDCWriter w;CHECK(ffdc_begin(&w,bytes,sizeof(bytes),1,14,1,1,1));
    FFPSEvent create={.operation=FFPS_CREATE,.target={10,1},.length=24};float clear[4]={0};FFDCLogicalBuffer v={.object=10,.generation=1,.stride=8,.length=24};
    CHECK(ffdc_emit(&w,&create)&&ffdc_begin_render(&w,50,1,clear)&&ffdc_bind_pipeline(&w,1,1));
    CHECK(ffdc_logical_table(&w,FFDC_VERTEX_TABLE,FFDC_VERTEX,&v,1)&&ffdc_draw_triangles(&w,0,3,1)&&ffdc_end_render(&w)&&ffdc_seal(&w));
    CHECK([receiver submit:bytes length:w.length completion:^(uint64_t a,uint64_t b,BOOL ok){(void)a;(void)b;(void)ok;}] == FFDCSubmitFailed);return 0;
}
int main(void) { @autoreleasepool {
    unsigned char storage[4096], data[16];for(int i=0;i<16;i++)data[i]=(unsigned char)i;
    FFDCWriter writer;CHECK(ffdc_begin(&writer,storage,sizeof(storage),1,9,1,1,7));
    FFPSSource *source=ffps_create(ffdc_emit,&writer);CHECK(source);FFPSHandle a={1,1},b={2,1};
    CHECK(ffps_buffer_create(source,a,16));CHECK(ffps_buffer_create(source,b,16));
    CHECK(ffps_buffer_write(source,a,0,data,16));memset(data,255,sizeof(data));
    CHECK(ffps_buffer_copy(source,a,0,b,0,16));CHECK(ffps_buffer_destroy(source,a));
    float clear[4]={0,0,0,1};CHECK(ffdc_begin_render(&writer,50,1,clear));
    CHECK(ffdc_bind_pipeline(&writer,70,1));CHECK(!ffdc_draw_triangles(&writer,0,6,1));CHECK(ffdc_draw_triangles(&writer,0,3,1));CHECK(ffdc_end_render(&writer));
    CHECK(ffdc_seal(&writer));CHECK(!ffdc_emit(&writer,&(FFPSEvent){0}));ffps_free(source);
    CHECK(ffdc_validate(storage,writer.length));CHECK(!ffdc_validate(storage,writer.length-1));
    FFDCRecord saved;memcpy(&saved,storage+sizeof(FFDCHeader),sizeof(saved));
    FFDCRecord bad=saved;bad.operation=99;memcpy(storage+sizeof(FFDCHeader),&bad,sizeof(bad));CHECK(!ffdc_validate(storage,writer.length));
    memcpy(storage+sizeof(FFDCHeader),&saved,sizeof(saved));
    size_t second=sizeof(FFDCHeader)+sizeof(FFDCRecord);memcpy(&saved,storage+second,sizeof(saved));
    bad=saved;bad.operation=99;memcpy(storage+second,&bad,sizeof(bad));int visited=0;
    CHECK(!ffdc_visit(storage,writer.length,count_visit,&visited));CHECK(visited==0); /* validate entire batch first */
    memcpy(storage+second,&saved,sizeof(saved));
    int sockets[2];CHECK(!socketpair(AF_UNIX,SOCK_STREAM,0,sockets));pid_t child=fork();CHECK(child>=0);
    if(child==0){close(sockets[1]);int gpu=0;int ok=ffdc_send(sockets[0],storage,writer.length)&&ffdc_receive_receipt(sockets[0],1,7,&gpu)&&gpu;close(sockets[0]);_exit(ok?0:1);}
    close(sockets[0]);int receiptFd=sockets[1];void *wire=NULL;size_t n=0;CHECK(ffdc_receive(sockets[1],&wire,&n));
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();CHECK(device);
    CHECK(check_bound_draws(device)==0);CHECK(check_reject_unqualified_ia(device)==0);CHECK(check_failure_completion_order(device)==0);CHECK(check_multiflight(device,0)==0);CHECK(check_multiflight(device,1)==0);CHECK(check_multiflight(device,2)==0);
    NSError *error=nil;
    NSString *shader=@"#include <metal_stdlib>\nusing namespace metal;\nvertex float4 v(uint i [[vertex_id]]) { float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0,1); }\nfragment float4 f() { return float4(1,0,0,1); }";
    id<MTLLibrary> library=[device newLibraryWithSource:shader options:nil error:&error];CHECK(library&&!error);
    MTLRenderPipelineDescriptor *descriptor=[MTLRenderPipelineDescriptor new];descriptor.vertexFunction=[library newFunctionWithName:@"v"];descriptor.fragmentFunction=[library newFunctionWithName:@"f"];
    descriptor.colorAttachments[0].pixelFormat=MTLPixelFormatRGBA8Unorm;MTLRenderPipelineReflection *reflection=nil;
    id<MTLRenderPipelineState> pipeline=[device newRenderPipelineStateWithDescriptor:descriptor options:MTLPipelineOptionBindingInfo|MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&error];CHECK(pipeline&&reflection&&!error);
    FFSTPipelineRegistry *pipelines=[[FFSTPipelineRegistry alloc]initWithDevice:device maxObjects:8];CHECK([pipelines defineObject:70 generation:1 pipeline:pipeline reflection:reflection iaMask:0]);
    MTLTextureDescriptor *td=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];td.storageMode=MTLStorageModeShared;td.usage=MTLTextureUsageRenderTarget;
    id<MTLTexture> target=[device newTextureWithDescriptor:td];CHECK(target);
    FFDCReceiver *receiver=[[FFDCReceiver alloc]initWithDevice:device pipelines:pipelines targetLookup:^id<MTLTexture>(uint64_t object,uint64_t generation){return object==50&&generation==1?target:nil;} textureLookup:nil samplerLookup:nil
        targetCompatibility:^BOOL(FFSTPipelineBinding *binding,id<MTLTexture> dst){return binding.pipeline==pipeline&&dst==target&&dst.pixelFormat==MTLPixelFormatRGBA8Unorm&&dst.sampleCount==1;} textureDisjoint:nil];CHECK(receiver);
    dispatch_semaphore_t done=dispatch_semaphore_create(0);__block BOOL success=NO;__block uint64_t receipt=0;
    CHECK([receiver submit:wire length:n completion:^(uint64_t serial,uint64_t completion,BOOL ok){success=ok && serial==1 && ffdc_send_receipt(receiptFd,serial,completion,ok);receipt=completion;dispatch_semaphore_signal(done);}] == FFDCSubmitAccepted);
    free(wire);CHECK([pipelines destroyObject:70 generation:1]);pipeline=nil;
    CHECK(![pipelines bindingForObject:70 generation:1]);
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);CHECK(success&&receipt==7);
    close(sockets[1]);int childStatus=0;CHECK(waitpid(child,&childStatus,0)==child);CHECK(WIFEXITED(childStatus)&&WEXITSTATUS(childStatus)==0);
    unsigned char pixels[4*4*4];[target getBytes:pixels bytesPerRow:16 fromRegion:MTLRegionMake2D(0,0,4,4) mipmapLevel:0];
    unsigned char *center=pixels+(2*4+2)*4;CHECK(center[0]==255&&center[1]==0&&center[2]==0&&center[3]==255);
    id<MTLCommandQueue> queue=[device newCommandQueue];id<MTLCommandBuffer> cb=[queue commandBuffer];FFPRBatch *batch=[[FFPRBatch alloc]initWithCommandBuffer:cb];
    id<MTLBuffer> src=[receiver.registry buffer:(FFPRHandle){2,1} batch:batch];CHECK(src);
    id<MTLBuffer> readback=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];id<MTLBlitCommandEncoder> blit=[cb blitCommandEncoder];
    [blit copyFromBuffer:src sourceOffset:0 toBuffer:readback destinationOffset:0 size:16];[blit endEncoding];CHECK([batch finish]);[cb commit];[cb waitUntilCompleted];
    CHECK(cb.status==MTLCommandBufferStatusCompleted);for(int i=0;i<16;i++)CHECK(((unsigned char *)readback.contents)[i]==i);
    FFDCCompletion ignore=^(uint64_t s,uint64_t c,BOOL ok){(void)s;(void)c;(void)ok;};
    CHECK([receiver submit:storage length:writer.length completion:ignore] == FFDCSubmitInvalid); /* duplicate serial */
    CHECK(ffdc_begin(&writer,storage,sizeof(storage),2,9,1,2,8));
    FFPSEvent retire={.operation=FFPS_DESTROY,.target={2,1}};
    FFPSEvent create={.operation=FFPS_CREATE,.target={2,2},.length=16};
    CHECK(ffdc_emit(&writer,&retire));CHECK(ffdc_emit(&writer,&create));CHECK(ffdc_seal(&writer));
    success=NO;receipt=0;
    CHECK([receiver submit:storage length:writer.length completion:^(uint64_t s,uint64_t c,BOOL ok){success=ok && s==2;receipt=c;dispatch_semaphore_signal(done);}] == FFDCSubmitAccepted);
    CHECK(dispatch_semaphore_wait(done,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_SEC))==0);CHECK(success&&receipt==8);
    CHECK(ffdc_begin(&writer,storage,sizeof(storage),3,9,1,3,9));
    FFPSEvent stale={.operation=FFPS_DESTROY,.target={2,1}};
    CHECK(ffdc_emit(&writer,&stale));CHECK(ffdc_seal(&writer));
    CHECK([receiver submit:storage length:writer.length completion:ignore] == FFDCSubmitFailed); /* wrong generation poisons */
    CHECK(ffdc_begin(&writer,storage,sizeof(storage),3,9,1,3,9));
    FFPSEvent live={.operation=FFPS_DESTROY,.target={2,2}};
    CHECK(ffdc_emit(&writer,&live));CHECK(ffdc_seal(&writer));
    CHECK([receiver submit:storage length:writer.length completion:ignore] == FFDCSubmitFailed); /* no retry after partial mutation */
    FFDCReceiver *incomplete=[[FFDCReceiver alloc]initWithDevice:device pipelines:pipelines targetLookup:^id<MTLTexture>(uint64_t o,uint64_t g){return o==50&&g==1?target:nil;}];
    CHECK(ffdc_begin(&writer,storage,sizeof(storage),1,10,1,1,1));
    FFPSEvent precreate={.operation=FFPS_CREATE,.target={90,1},.length=16};CHECK(ffdc_emit(&writer,&precreate));
    CHECK(ffdc_begin_render(&writer,50,1,clear));CHECK(ffdc_seal(&writer));
    CHECK([incomplete submit:storage length:writer.length completion:ignore] == FFDCSubmitInvalid);
    id<MTLCommandBuffer> probeCommand=[[device newCommandQueue] commandBuffer];FFPRBatch *probe=[[FFPRBatch alloc]initWithCommandBuffer:probeCommand];
    CHECK((![incomplete.registry buffer:(FFPRHandle){90,1} batch:probe]));
    CHECK(([incomplete.registry createBuffer:(FFPRHandle){90,1} length:16])); /* no generation tombstone either */
    puts("direct command transport, Metal draw and buffer fixture passed");return 0;
} }
