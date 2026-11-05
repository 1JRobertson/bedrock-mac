#import "native_direct_commands.h"
#include "direct_commands.h"
#include <string.h>

typedef struct {
    __unsafe_unretained FFPRRegistry *registry;
    __unsafe_unretained FFPRBatch *batch;
    __unsafe_unretained id<MTLCommandBuffer> command;
    __unsafe_unretained FFSTPipelineRegistry *pipelines;
    __unsafe_unretained FFDCTargetLookup lookup;
    __unsafe_unretained FFDBTextureLookup textures;
    __unsafe_unretained FFDBSamplerLookup samplers;
    __unsafe_unretained FFDCCompatibleTarget compatible;
    __unsafe_unretained FFDCTextureDisjoint disjoint;
    __unsafe_unretained NSMutableArray *held;
    __unsafe_unretained id<MTLRenderCommandEncoder> encoder;
    __unsafe_unretained id<MTLTexture> targetTexture;
    __unsafe_unretained FFSTPipelineBinding *pipeline;
    __unsafe_unretained FFDBBindings *preparedBinding;
    NSUInteger preparedCount;
    FFDBBuffer vertices[32],constants[2][14]; FFDBField fields[2][128];
    size_t vertexCount,constantCount[2],fieldCount[2];
} FFDCApply;
static FFDBBuffer logicalBuffer(FFDCLogicalBuffer b) {
    return (FFDBBuffer){.handle={b.object,b.generation},.offset=b.offset,.stride=b.stride,.length=b.length};
}
static int drawBindings(FFDCApply *a,uint64_t first,uint64_t count,BOOL indexed) {
    if(!a->encoder||!a->pipeline)return 0;
    /* Reflection does not expose IA element widths or shader access bounds. */
    (void)first;(void)count;(void)indexed;
    if(a->pipeline.layout.ia_slot_mask)return 0;
    FFDBDescription d={.vertices=a->vertices,.vertexCount=a->vertexCount,
        .constants={a->constants[0],a->constants[1]},.constantCount={a->constantCount[0],a->constantCount[1]},
        .arguments={a->fields[0],a->fields[1]},.argumentCount={a->fieldCount[0],a->fieldCount[1]}};
    FFDBBindings *bindings=a->preparedBinding;
    if(!bindings){
        if(a->preparedCount>=1024)return 0;
        FFDBTextureLookup safeLookup=^id<MTLTexture>(FFPRHandle handle){
            id<MTLTexture> sampled=a->textures?a->textures(handle):nil;
            if(!sampled||!a->disjoint||!a->disjoint(a->targetTexture,handle,sampled))return nil;
            return sampled;
        };
        bindings=[FFDBBindings prepareWithDevice:a->command.device pipeline:a->pipeline buffers:a->registry batch:a->batch
            description:&d textureLookup:safeLookup samplerLookup:a->samplers];
        if(!bindings)return 0;[a->held addObject:bindings];a->preparedBinding=bindings;++a->preparedCount;
    }
    [bindings bindToEncoder:a->encoder];return 1;
}
static int apply(void *opaque,const FFDCRecord *r,const void *payload) {
    FFDCApply *a=opaque;FFPRHandle target={r->target,r->target_generation},source={r->source,r->source_generation};
    if(r->operation<=FFPS_DESTROY && a->encoder)return 0;
    switch(r->operation) {
    case FFPS_CREATE: return [a->registry createBuffer:target length:(NSUInteger)r->length];
    case FFPS_WRITE: return [a->registry writeBuffer:target offset:(NSUInteger)r->offset bytes:payload length:(NSUInteger)r->length batch:a->batch];
    case FFPS_COPY: return [a->registry copyBuffer:source sourceOffset:(NSUInteger)r->source_offset destination:target destinationOffset:(NSUInteger)r->offset length:(NSUInteger)r->length batch:a->batch];
    case FFPS_DESTROY: return [a->registry destroyBuffer:target];
    case FFDC_BEGIN_RENDER: {
        if(a->encoder||!a->lookup)return 0;
        id<MTLTexture> texture=a->lookup(r->target,r->target_generation);
        if(!texture||texture.device!=a->command.device||texture.textureType!=MTLTextureType2D||texture.sampleCount!=1||!(texture.usage&MTLTextureUsageRenderTarget))return 0;
        float c[4];memcpy(c,payload,sizeof(c));MTLRenderPassDescriptor *pass=[MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture=texture;pass.colorAttachments[0].loadAction=MTLLoadActionClear;
        pass.colorAttachments[0].storeAction=MTLStoreActionStore;pass.colorAttachments[0].clearColor=MTLClearColorMake(c[0],c[1],c[2],c[3]);
        id<MTLRenderCommandEncoder> encoder=[a->command renderCommandEncoderWithDescriptor:pass];if(!encoder)return 0;
        [a->held addObject:encoder];[a->held addObject:texture];a->encoder=encoder;a->targetTexture=texture;a->pipeline=nil;a->preparedBinding=nil;
        a->vertexCount=0;memset(a->constantCount,0,sizeof(a->constantCount));memset(a->fieldCount,0,sizeof(a->fieldCount));return 1;
    }
    case FFDC_BIND_PIPELINE: {
        if(!a->encoder||!a->pipelines)return 0;
        FFSTPipelineBinding *binding=[a->pipelines bindingForObject:r->target generation:r->target_generation];
        if(!binding||!a->compatible||!a->compatible(binding,a->targetTexture))return 0;
        [a->encoder setRenderPipelineState:binding.pipeline];[a->held addObject:binding];a->pipeline=binding;a->preparedBinding=nil;return 1;
    }
    case FFDC_VERTEX_TABLE:case FFDC_CONSTANT_TABLE:case FFDC_ARGUMENT_TABLE: {
        unsigned stage=(unsigned)r->target;const uint8_t *p=payload;a->preparedBinding=nil;
        if(r->operation==FFDC_ARGUMENT_TABLE){a->fieldCount[stage]=r->length;
            for(size_t i=0;i<r->length;++i){FFDCLogicalField f;memcpy(&f,p+i*sizeof(f),sizeof(f));
                a->fields[stage][i]=(FFDBField){.offset=f.offset,.kind=f.kind,.value=f.value,.buffer=logicalBuffer(f.buffer),.handle={f.object,f.generation}};}}
        else {FFDBBuffer *dst=r->operation==FFDC_VERTEX_TABLE?a->vertices:a->constants[stage];
            if(r->operation==FFDC_VERTEX_TABLE)a->vertexCount=r->length;else a->constantCount[stage]=r->length;
            for(size_t i=0;i<r->length;++i){FFDCLogicalBuffer b;memcpy(&b,p+i*sizeof(b),sizeof(b));dst[i]=logicalBuffer(b);}}
        return 1;
    }
    case FFDC_SET_VIEWPORT: {FFDCViewport v;memcpy(&v,payload,sizeof(v));if(v.znear<0||v.znear>1||v.zfar<0||v.zfar>1)return 0;
        [a->encoder setViewport:(MTLViewport){v.x,v.y,v.width,v.height,v.znear,v.zfar}];return 1;}
    case FFDC_SET_SCISSOR: {FFDCScissor v;memcpy(&v,payload,sizeof(v));
        if(v.x>a->targetTexture.width||v.y>a->targetTexture.height||v.width>a->targetTexture.width-v.x||v.height>a->targetTexture.height-v.y)return 0;
        [a->encoder setScissorRect:(MTLScissorRect){(NSUInteger)v.x,(NSUInteger)v.y,(NSUInteger)v.width,(NSUInteger)v.height}];return 1;}
    case FFDC_SET_RASTER: {FFDCRaster v;memcpy(&v,payload,sizeof(v));
        [a->encoder setTriangleFillMode:v.fill];[a->encoder setCullMode:v.cull];[a->encoder setDepthClipMode:v.depth_clip];[a->encoder setFrontFacingWinding:v.winding];
        [a->encoder setDepthBias:v.depth_bias slopeScale:v.slope_scale clamp:v.depth_bias_clamp];return 1;}
    /* Current pipeline reflection cannot qualify ordinary resource slots. */
    case FFDC_SET_BUFFER:case FFDC_SET_BUFFER_OFFSET:case FFDC_SET_FRAGMENT_BYTES:case FFDC_SET_FRAGMENT_TEXTURE:return 0;
    case FFDC_DRAW_TRIANGLES: if(!drawBindings(a,0,3,NO))return 0;[a->encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];return 1;
    case FFDC_DRAW: {FFDCDraw d;memcpy(&d,payload,sizeof(d));if((d.instances&&d.base_instance>UINT32_MAX-(d.instances-1))||!drawBindings(a,d.first,d.count,NO))return 0;
        [a->encoder drawPrimitives:d.primitive vertexStart:(NSUInteger)d.first vertexCount:(NSUInteger)d.count instanceCount:d.instances baseInstance:d.base_instance];return 1;}
    case FFDC_DRAW_INDEXED: {FFDCIndexedDraw d;memcpy(&d,payload,sizeof(d));id<MTLBuffer> index=[a->registry buffer:(FFPRHandle){d.object,d.generation} batch:a->batch];
        uint64_t stride=d.index_type?4:2;if(!index||d.offset>index.length||d.count>(index.length-d.offset)/stride||
           (d.instances&&d.base_instance>UINT32_MAX-(d.instances-1))||!drawBindings(a,0,0,YES))return 0;
        [a->held addObject:index];[a->encoder drawIndexedPrimitives:d.primitive indexCount:(NSUInteger)d.count indexType:d.index_type?MTLIndexTypeUInt32:MTLIndexTypeUInt16
            indexBuffer:index indexBufferOffset:(NSUInteger)d.offset instanceCount:d.instances baseVertex:d.base_vertex baseInstance:d.base_instance];return 1;}
    case FFDC_END_RENDER: if(!a->encoder)return 0;[a->encoder endEncoding];a->encoder=nil;a->targetTexture=nil;a->pipeline=nil;a->preparedBinding=nil;return 1;
    default: return 0;
    }
}
@interface FFDCPending : NSObject
@property(nonatomic) uint64_t serial, completionID;
@property(nonatomic) NSUInteger bytes;
@property(nonatomic) BOOL terminal, succeeded;
@property(nonatomic,copy) FFDCCompletion completion;
@property(nonatomic,strong) NSArray *held;
@end
@implementation FFDCPending
@end

@implementation FFDCReceiver {
    id<MTLCommandQueue> _queue;
    NSLock *_lock;
    dispatch_queue_t _receipts;
    FFSTPipelineRegistry *_pipelines;
    FFDCTargetLookup _lookup;
    FFDBTextureLookup _textures; FFDBSamplerLookup _samplers;
    FFDCCompatibleTarget _compatible; FFDCTextureDisjoint _disjoint;
    NSMutableArray<FFDCPending *> *_pending;
    NSUInteger _active, _activeBytes;
    BOOL _failed, _closed, _closeDelivered;
    void (^_closeCompletion)(void);
    uint64_t _stream,_nextSerial,_firstFailedSerial;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    return [self initWithDevice:device pipelines:nil targetLookup:nil];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines targetLookup:(FFDCTargetLookup)lookup {
    return [self initWithDevice:device pipelines:pipelines targetLookup:lookup textureLookup:nil samplerLookup:nil];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines targetLookup:(FFDCTargetLookup)lookup textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers {
    return [self initWithDevice:device pipelines:pipelines targetLookup:lookup textureLookup:textures samplerLookup:samplers targetCompatibility:nil textureDisjoint:nil];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device pipelines:(FFSTPipelineRegistry *)pipelines targetLookup:(FFDCTargetLookup)lookup textureLookup:(FFDBTextureLookup)textures samplerLookup:(FFDBSamplerLookup)samplers targetCompatibility:(FFDCCompatibleTarget)compatible textureDisjoint:(FFDCTextureDisjoint)disjoint {
    if(!device)return nil;
    if((self=[super init])) { _queue=[device newCommandQueue];_registry=[[FFPRRegistry alloc]initWithDevice:device];_lock=[NSLock new];_pipelines=pipelines;_lookup=[lookup copy];_textures=[textures copy];_samplers=[samplers copy];_compatible=[compatible copy];_disjoint=[disjoint copy];_receipts=dispatch_queue_create("bedrock.direct.receipts",DISPATCH_QUEUE_SERIAL);_pending=[NSMutableArray array];_nextSerial=1;
        if(!_queue||!_registry||!_receipts)return nil; }
    return self;
}
- (FFDCSubmitResult)submit:(const void *)bytes length:(size_t)length completion:(FFDCCompletion)completion {
    if(!completion||!ffdc_validate_complete(bytes,length))return FFDCSubmitInvalid;
    FFDCHeader h;memcpy(&h,bytes,sizeof(h));
    [_lock lock];
    if(_failed||_closed) { [_lock unlock];return FFDCSubmitFailed; }
    if(_active>=4 || length>64u*1024u*1024u-_activeBytes) { [_lock unlock];return FFDCSubmitBusy; }
    if(h.serial!=_nextSerial||(_stream&&_stream!=h.stream)) { [_lock unlock];return FFDCSubmitInvalid; }
    _stream=h.stream;
    id<MTLCommandBuffer> command=[_queue commandBuffer];FFPRBatch *batch=[[FFPRBatch alloc]initWithCommandBuffer:command];
    NSMutableArray *held=[NSMutableArray array];
    FFDCApply ctx={.registry=_registry,.batch=batch,.command=command,.pipelines=_pipelines,.lookup=_lookup,.textures=_textures,.samplers=_samplers,.compatible=_compatible,.disjoint=_disjoint,.held=held};
    BOOL applied=command&&batch&&ffdc_visit(bytes,length,apply,&ctx);
    if(!applied||ctx.encoder||![batch finish]) {
        if(ctx.encoder)[ctx.encoder endEncoding];_failed=YES;[_lock unlock];return FFDCSubmitFailed;
    }
    FFDCPending *pending=[FFDCPending new];pending.serial=h.serial;pending.completionID=h.completion;
    pending.bytes=length;pending.completion=completion;pending.held=[held copy];
    [_pending addObject:pending];++_active;_activeBytes+=length;_nextSerial++;
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        [self recordGPUCompletion:pending success:done.status==MTLCommandBufferStatusCompleted];
    }];
    [command commit];[_lock unlock];return FFDCSubmitAccepted;
}
/* Called by Metal's terminal callback. The focused fixture also drives this
 * seam with synthetic terminal outcomes to test out-of-order delivery. */
- (void)recordGPUCompletion:(FFDCPending *)pending success:(BOOL)ok {
    [_lock lock];pending.terminal=YES;pending.succeeded=ok;
    if(!ok){_failed=YES;if(!_firstFailedSerial||pending.serial<_firstFailedSerial)_firstFailedSerial=pending.serial;}
    [_lock unlock];dispatch_async(_receipts, ^{ [self drainReceipts]; });
}
/* One receipt queue owns delivery; lock only protects state, never user code. */
- (void)drainReceipts {
    for(;;) {
        [_lock lock];FFDCPending *pending=_pending.firstObject;
        if(!pending||!pending.terminal) {
            void (^closed)(void)=nil;
            if(_closed&&!_active&&!_closeDelivered){_closeDelivered=YES;closed=_closeCompletion;_closeCompletion=nil;}
            [_lock unlock];if(closed)closed();return;
        }
        BOOL success=pending.succeeded&&(!_firstFailedSerial||pending.serial<_firstFailedSerial);
        [_pending removeObjectAtIndex:0];[_lock unlock];
        @try {pending.completion(pending.serial,pending.completionID,success);}
        @catch(__unused NSException *exception) {
            /* A missing receipt makes the stream unusable. Earlier accepted
             * GPU work must still retire, and subsequent receipts fail. */
            [_lock lock];_failed=YES;
            if(!_firstFailedSerial||pending.serial<_firstFailedSerial)_firstFailedSerial=pending.serial;
            [_lock unlock];
        }
        [_lock lock];--_active;_activeBytes-=pending.bytes;[_lock unlock];
        pending.held=nil;
    }
}
- (BOOL)closeWithCompletion:(void (^)(void))completion {
    if(!completion)return NO;
    [_lock lock];if(_closed){[_lock unlock];return NO;}
    _closed=YES;_closeCompletion=[completion copy];[_lock unlock];
    dispatch_async(_receipts, ^{ [self drainReceipts]; });return YES;
}

@end
