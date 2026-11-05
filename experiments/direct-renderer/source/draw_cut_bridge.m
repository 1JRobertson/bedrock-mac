#include "small_snapshot_batch.h"
#include "direct_pass_journal.h"
#include <stdatomic.h>
/* Paired DXMT resource cut. Default builds never read the private ABI. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#import <CommonCrypto/CommonDigest.h>
#include "draw_resource_cut.h"
#include "native_buffer_ref.h"
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Native buffer marker requires little endian
#endif
#include "shared_texture_attachment.h"
#include "shared_texture_pass_capture.h"
#include "draw_cut_blobs.h"
#define FFMD_ENCODER_API __attribute__((weak_import))
#include "metadata_wire_encode.h"
#include "metadata_wire_v1.h"
#include "native_value_validation.h"
#include <objc/runtime.h>
#include <pthread.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdlib.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <limits.h>
#include <time.h>
#ifdef BEDROCK_NATIVE_DRAW_CUT
#define FFSC_PRODUCER_API __attribute__((weak_import))
#include "chunk_stream_producer.h"
static pthread_once_t success_trace_once=PTHREAD_ONCE_INIT;
static int success_trace;
static void initialize_success_trace(void){
    const char *option=getenv("BEDROCK_NATIVE_SOURCE_TIMELINE");success_trace=option&&!strcmp(option,"1");
}
static int log_cut_success(void *context,int output_directory){
    intptr_t token=(intptr_t)context;
    if(output_directory>=0||token>=-1||token<INT_MIN)return 1;
    pthread_once(&success_trace_once,initialize_success_trace);return success_trace;
}
static uint64_t draw_profile_now(void){
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;
    return (uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
}
static void draw_profile_json(void *context,uint64_t started,NSData *data){
    intptr_t token=(intptr_t)context;
    /* Only the continuous writer uses a sign-extended negative token as its
     * opaque sink context. Ordinary object/pointer contexts stay untouched. */
    if(token < -1&&token>=INT_MIN&&fullframe_chunk_profile_token){
        uint64_t end=draw_profile_now();fullframe_chunk_profile_token((int)token,FFSC_PROFILE_JSON,end>=started?end-started:0,data.length,1);
    }
}
static void draw_profile_stage(void *context,uint32_t stage,uint64_t nanoseconds){
    intptr_t token=(intptr_t)context;
    if(token < -1&&token>=INT_MIN&&fullframe_chunk_profile_token)
        fullframe_chunk_profile_token((int)token,stage,nanoseconds,0,1);
}
extern int fullframe_replay_cut_layout(id<MTLRenderPipelineState>,ff_draw_layout *);
extern int fullframe_replay_pass_eligible(const struct WMTRenderPassInfo *);
extern int fullframe_replay_draw_eligible(id<MTLRenderPipelineState>,const struct wmtcmd_base *);
extern void fullframe_replay_cut_ready(id<MTLCommandBuffer>,const struct wmtcmd_base *,NSString *);
extern int fullframe_replay_capture_armed(void);
extern FFSTPassRecord *fullframe_replay_pass_record(id<MTLCommandBuffer>,const struct WMTRenderPassInfo *,
    const struct wmtcmd_base *,const struct ff_draw_cut *);
extern int fullframe_replay_pass_claim(FFSTPassRecord *);
static int directory=-1;
static _Atomic int claimed;
static dispatch_queue_t writer;
static FFSTAttachmentCapture attachment_capture;
static uint64_t attachment_device;
static pthread_mutex_t attachment_lock=PTHREAD_MUTEX_INITIALIZER;
static char load_fence_key;
static char pass_record_key;
void fullframe_draw_cut_add_load_fence(id<MTLFence> resource,id<MTLFence> load){
    if(resource&&load)objc_setAssociatedObject(resource,&load_fence_key,load,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static int pass_mode;
static FFSTAttachmentCapture attachment_state(id<MTLDevice> device){
    pthread_mutex_lock(&attachment_lock);
    if(!attachment_capture){
        const char *service=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_SERVICE"),*token=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_TOKEN");
        const char *registry=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_DEVICE");char *end=NULL;errno=0;
        uint64_t expected=registry?strtoull(registry,&end,10):0;
        if(service&&*service&&token&&*token&&registry&&end&&!*end&&!errno&&expected==device.registryID){
            FFSTProducer producer=ffst_producer_create([NSString stringWithUTF8String:service],[NSString stringWithUTF8String:token],device,
                1,UINT64_C(256)*1024*1024,0);
            if(producer){
                attachment_capture=ffst_attachment_capture_create(producer,device,1,UINT64_C(256)*1024*1024);
                if(!attachment_capture)ffst_producer_destroy(producer);else attachment_device=device.registryID;
            }
        }
    }
    FFSTAttachmentCapture result=attachment_device==device.registryID?attachment_capture:NULL;
    pthread_mutex_unlock(&attachment_lock);return result;
}
static int copy_load_attachments(id<MTLCommandBuffer> command,const struct WMTRenderPassInfo *info,
    struct ff_draw_cut *cut,const id<MTLFence> *fences,size_t fence_count){
    FFSTAttachmentSource sources[3]={0};size_t count=0;
    if(info->colors[0].load_action==WMTLoadActionLoad)sources[count++]=(FFSTAttachmentSource){
        .texture=(id<MTLTexture>)info->colors[0].texture,.level=info->colors[0].level,.slice=info->colors[0].slice,.role=FFST_COLOR};
    if(info->depth.texture&&info->depth.load_action==WMTLoadActionLoad)sources[count++]=(FFSTAttachmentSource){
        .texture=(id<MTLTexture>)info->depth.texture,.level=info->depth.level,.slice=info->depth.slice,.role=FFST_DEPTH};
    if(info->stencil.texture&&info->stencil.load_action==WMTLoadActionLoad)sources[count++]=(FFSTAttachmentSource){
        .texture=(id<MTLTexture>)info->stencil.texture,.level=info->stencil.level,.slice=info->stencil.slice,.role=FFST_STENCIL};
    if(!count)return 1;
    FFSTAttachmentCapture capture=attachment_state(command.device);if(!capture)return 0;
    /* These IDs name immutable versions owned by this capture, not logical D3D
     * allocations. Pointer equality is used only to preserve same-cut aliasing;
     * no producer pointer or GPU address crosses the process boundary. */
    uint64_t next_id=1;
    for(size_t i=0;i<count;i++){
        for(size_t j=0;j<i;j++)if(sources[j].texture==sources[i].texture){sources[i].source_id=sources[j].source_id;break;}
        if(!sources[i].source_id)sources[i].source_id=next_id++;
        sources[i].source_generation=cut->capture_id;
    }
    id<MTLFence> ready=nil;
    if(!ffst_attachment_capture_schedule(capture,command,cut->capture_id,sources,count,fences,fence_count,&ready,
        ^(uint64_t cut_id,FFSTResult result){fprintf(stderr,"[full-frame-load-cut] cut=%llu result=%u\n",(unsigned long long)cut_id,(unsigned)result);}))return 0;
    objc_setAssociatedObject(cut->ready_fence,&load_fence_key,ready,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return 1;
}
__attribute__((constructor))static void initialize(void){
    const char *mode=getenv("BEDROCK_FULLFRAME_DRAW_PASS");pass_mode=mode&&!strcmp(mode,"1");
    const char *path=getenv("BEDROCK_FULLFRAME_DRAW_CUT_DIR");if(!path||path[0]!='/')return;
    int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat st;if(fd<0)return;
    if(fstat(fd,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&077)){close(fd);return;}
    writer=dispatch_queue_create("bedrock.full-frame.draw-cut",DISPATCH_QUEUE_SERIAL);if(!writer){close(fd);return;}directory=fd;
}
static int write_file(int directory,const char *name,const void *bytes,size_t length){
    char temporary[80];if(snprintf(temporary,sizeof(temporary),".%s.tmp",name)>=(int)sizeof(temporary))return 0;
    int fd=openat(directory,temporary,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 0;
    const unsigned char *p=bytes;
    while(length){ssize_t n=write(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;length-=(size_t)n;}
    int ok=!length&&fsync(fd)==0;if(close(fd))ok=0;if(ok)ok=linkat(directory,temporary,directory,name,0)==0;
    unlinkat(directory,temporary,0);return ok;
}
static NSDictionary *binding(ff_vertex_binding b){
    return @{ @"id":@(b.id),@"generation":@(b.generation),@"offset":@(b.offset),@"stride":@(b.stride),@"length":@(b.length) };
}
static NSDictionary *plan_binding_record(const ff_draw_plan *d){
    NSMutableArray *vertices=[NSMutableArray array],*constants[2]={[NSMutableArray array],[NSMutableArray array]},
        *args[2]={[NSMutableArray array],[NSMutableArray array]};
    for(size_t i=0;i<d->binding_count;i++)[vertices addObject:binding(d->bindings[i])];
    for(unsigned st=0;st<2;st++){
        for(size_t i=0;i<d->layout.constant_count[st];i++)[constants[st] addObject:binding(d->constants[st][i])];
        for(size_t i=0;i<d->layout.arguments[st].field_count;i++){
            ff_argument_binding a=d->arguments[st][i];
            NSMutableDictionary *field=[@{@"offset":@(a.offset),@"kind":@(a.kind),@"value":@(a.value)} mutableCopy];
            if(a.kind==FF_FIELD_BUFFER)field[@"buffer"]=binding(a.buffer);[args[st] addObject:field];[field release];
        }
    }
    NSMutableDictionary *record=[@{@"draw":@[@(d->primitive),@(d->vertex_start),@(d->vertex_count),@(d->instance_count),@(d->base_instance)],
        @"ia_slot_mask":@(d->layout.ia_slot_mask),@"bindings":vertices,@"vertex_constants":constants[0],@"fragment_constants":constants[1],
        @"arguments":@[args[0],args[1]],@"argument_bytes":@[@(d->layout.arguments[0].byte_length),@(d->layout.arguments[1].byte_length)]} mutableCopy];
    if(d->indexed){record[@"index_binding"]=binding(d->index_binding);record[@"indexed"]=@{@"index_type":@(d->index_type),@"base_vertex":@(d->base_vertex),@"index_count":@(d->vertex_count),@"index_offset":@(d->index_offset)};}
    return [record autorelease];
}
/* Encode the same FFMD1 rows directly from the already planned immutable cut.
 * If any value is outside the generic encoder's bounds, return NO and let the
 * existing dictionary encoder decide whether to accept the cut. */
static NSData *fast_emit(uint16_t kind,const uint64_t *identity,const uint8_t *digest,
    const uint16_t *types,const uint32_t *strides,NSArray *bodies){
    NSUInteger n=bodies.count;uint64_t length=sizeof(ffmd_header)+n*sizeof(ffmd_section);
    if(!n||n>FFMD_MAX_SECTIONS)return nil;
    for(NSUInteger i=0;i<n;i++){
        NSData *body=bodies[i];if(!strides[i]||body.length%strides[i]||body.length>UINT32_MAX||body.length/strides[i]>UINT32_MAX)return nil;
        length+=body.length;
    }
    if(length>FFMD_MAX_BYTES)return nil;
    ffmd_header h={.magic=FFMD_MAGIC,.version=FFMD_VERSION,.kind=kind,.total_bytes=(uint32_t)length,
        .section_count=(uint32_t)n,.flags=kind==FFMD_PLAN?0:FFMD_COMPLETE_PASS};
    if(identity){h.stream=identity[0];h.frame=identity[1];h.chunk=identity[2];h.payload_id=identity[3];h.cut_id=identity[4];}
    if(digest)memcpy(h.plan_sha256,digest,32);
    NSMutableData *out=[NSMutableData dataWithCapacity:(NSUInteger)length];[out appendBytes:&h length:sizeof(h)];
    uint32_t offset=(uint32_t)(sizeof(h)+n*sizeof(ffmd_section));
    for(NSUInteger i=0;i<n;i++){
        NSData *body=bodies[i];ffmd_section section={.type=types[i],.version=1,.stride=strides[i],
            .count=(uint32_t)(body.length/strides[i]),.offset=offset,.bytes=(uint32_t)body.length};
        [out appendBytes:&section length:sizeof(section)];offset+=section.bytes;
    }
    for(NSData *body in bodies)[out appendData:body];return [[out copy] autorelease];
}
static ffmd_graph_binding fast_binding(ff_vertex_binding b){
    return (ffmd_graph_binding){.id=b.id,.generation=b.generation,.offset=b.offset,.stride=b.stride,.length=b.length};
}
static BOOL fast_typed_graph(const struct ff_draw_cut *cut,NSDictionary *sidecar,NSData **plan,NSData **dynamic){
    if(plan)*plan=nil;if(dynamic)*dynamic=nil;
    if(!cut||!cut->capture_id||!cut->complete_pass||!cut->compacted||!cut->draws||!cut->draw_count||
       cut->draw_count>FF_DRAW_PASS_LIMIT||cut->snapshot_count>FF_DRAW_RESOURCE_LIMIT||
       cut->texture_count>FF_TEXTURE_RESOURCE_LIMIT||cut->sampler_count>FF_SAMPLER_RESOURCE_LIMIT||
       ![sidecar isKindOfClass:[NSDictionary class]]||![sidecar[@"format"] isEqual:@"bedrock-native-frame-pass"]||
       ![sidecar[@"version"] isEqual:@1])return NO;
    uint64_t identity[5]={0};NSArray *keys=@[@"stream",@"frame",@"chunk",@"payload_id"];
    for(unsigned i=0;i<4;i++)if(!ffst_value_u64(sidecar[keys[i]],UINT64_MAX,&identity[i]))return NO;
    identity[4]=cut->capture_id;
    NSMutableData *pd=[NSMutableData data],*slots=[NSMutableData data],*snaps=[NSMutableData data],*draws=[NSMutableData data];
    NSMutableData *bindings=[NSMutableData data],*args=[NSMutableData data],*argBindings=[NSMutableData data];
    NSMutableData *textures=[NSMutableData data],*planes=[NSMutableData data],*samplers=[NSMutableData data];
    for(size_t i=0;i<cut->snapshot_count;i++){
        ffmd_graph_snapshot s={.generation=1,.has_provenance=1,.length=cut->serialized_length[i],
            .source_incarnation=cut->source_incarnation[i],.source_generation=cut->source_generation[i],.source_offset=cut->source_offset[i]};
        [snaps appendBytes:&s length:sizeof(s)];
    }
    uint32_t bc=0,ac=0,sc=0,abc=0;
    for(size_t i=0;i<cut->draw_count;i++){
        const ff_draw_plan *d=&cut->draws[i];
        if(d->binding_count>FF_VERTEX_RESOURCE_LIMIT||d->layout.constant_count[0]>FF_CONSTANT_RESOURCE_LIMIT||
           d->layout.constant_count[1]>FF_CONSTANT_RESOURCE_LIMIT||d->layout.arguments[0].field_count>FF_SHADER_FIELD_LIMIT||
           d->layout.arguments[1].field_count>FF_SHADER_FIELD_LIMIT||d->vertex_start>UINT32_MAX||d->vertex_count>UINT32_MAX||
           (d->indexed&&d->index_type>UINT8_MAX))return NO;
        uint32_t va=d->layout.arguments[0].field_count,fa=d->layout.arguments[1].field_count;
        ffmd_plan_draw pdrow={.ia_slot_mask=d->layout.ia_slot_mask,.primitive=d->primitive,.vertex_count=(uint16_t)d->binding_count,
            .constant_count={(uint16_t)d->layout.constant_count[0],(uint16_t)d->layout.constant_count[1]},
            .argument_count={(uint16_t)va,(uint16_t)fa},.indexed=d->indexed?1:0,.index_type=d->indexed?(uint8_t)d->index_type:0,
            .argument_slot_first={sc,sc+va}};
        [pd appendBytes:&pdrow length:sizeof(pdrow)];uint32_t firstBinding=bc,firstArgument=ac;
        for(size_t j=0;j<d->binding_count;j++){ffmd_graph_binding b=fast_binding(d->bindings[j]);[bindings appendBytes:&b length:sizeof(b)];bc++;}
        for(unsigned st=0;st<2;st++)for(size_t j=0;j<d->layout.constant_count[st];j++){
            ffmd_graph_binding b=fast_binding(d->constants[st][j]);[bindings appendBytes:&b length:sizeof(b)];bc++;}
        uint32_t index=FFMD_NO_BINDING;
        if(d->indexed){index=bc++;ffmd_graph_binding b=fast_binding(d->index_binding);[bindings appendBytes:&b length:sizeof(b)];}
        for(unsigned st=0;st<2;st++)for(size_t j=0;j<d->layout.arguments[st].field_count;j++){
            ff_argument_binding field=d->arguments[st][j];ffmd_plan_argument_slot slot={.offset=field.offset,.kind=field.kind};
            [slots appendBytes:&slot length:sizeof(slot)];sc++;
            ffmd_graph_argument_value a={.value=field.value,.buffer_binding=FFMD_NO_BINDING};
            if(field.kind==FF_FIELD_BUFFER){a.buffer_binding=abc++;ffmd_graph_binding b=fast_binding(field.buffer);[argBindings appendBytes:&b length:sizeof(b)];}
            [args appendBytes:&a length:sizeof(a)];ac++;
        }
        ffmd_graph_draw dr={.start=(uint32_t)d->vertex_start,.count=(uint32_t)d->vertex_count,.instances=d->instance_count,
            .base_instance=d->base_instance,.base_vertex=d->indexed?d->base_vertex:0,.binding_first=firstBinding,
            .argument_first=firstArgument,.index_binding=index,.index_count=d->indexed?d->vertex_count:0,.index_offset=d->indexed?d->index_offset:0};
        [draws appendBytes:&dr length:sizeof(dr)];
    }
    ffmd_graph_argument_value *argRows=args.mutableBytes;
    for(uint32_t i=0;i<ac;i++)if(argRows[i].buffer_binding!=FFMD_NO_BINDING)argRows[i].buffer_binding+=bc;
    [bindings appendData:argBindings];
    uint32_t planeCount=0;
    for(size_t i=0;i<cut->texture_count;i++){
        const ff_texture_snapshot *t=&cut->textures[i];if(t->id!=i+1||t->plane_count>FF_TEXTURE_PLANE_LIMIT)return NO;
        ffmd_graph_texture row={.format=t->format,.texture_type=t->texture_type,.width=t->width,.height=t->height,
            .mip_count=t->mip_count,.array_length=t->array_length,.has_swizzle=1,
            .swizzle={t->swizzle[0],t->swizzle[1],t->swizzle[2],t->swizzle[3]},.plane_first=planeCount,.plane_count=t->plane_count,.length=t->length};
        [textures appendBytes:&row length:sizeof(row)];
        for(size_t j=0;j<t->plane_count;j++){ff_texture_plane x=t->planes[j];ffmd_graph_texture_plane p={.mip=x.mip,.slice=x.slice,.offset=x.offset,.row_bytes=x.row_bytes,.length=x.length};
            [planes appendBytes:&p length:sizeof(p)];planeCount++;}
    }
    for(size_t i=0;i<cut->sampler_count;i++){
        const ff_sampler_snapshot *s=&cut->samplers[i];if(s->id!=i+1||!isfinite(s->lod_min)||!isfinite(s->lod_max))return NO;
        ffmd_graph_sampler row={.address={s->address[0],s->address[1],s->address[2]},.min_filter=s->min_filter,.mag_filter=s->mag_filter,
            .mip_filter=s->mip_filter,.compare=s->compare,.border=s->border,.max_anisotropy=s->max_anisotropy,.normalized=s->normalized,.lod_average=s->lod_average};
        memcpy(&row.lod_min_bits,&s->lod_min,4);memcpy(&row.lod_max_bits,&s->lod_max,4);[samplers appendBytes:&row length:sizeof(row)];
    }
    uint16_t pt[]={FFMD_PLAN_DRAW,FFMD_PLAN_ARGUMENT_SLOT};uint32_t ps[]={sizeof(ffmd_plan_draw),sizeof(ffmd_plan_argument_slot)};
    NSData *p=fast_emit(FFMD_PLAN,NULL,NULL,pt,ps,@[pd,slots]);if(!p)return NO;
    uint8_t sha[32];CC_SHA256(p.bytes,(CC_LONG)p.length,sha);
    uint16_t gt[]={FFMD_GRAPH_SNAPSHOT,FFMD_GRAPH_DRAW,FFMD_GRAPH_BINDING,FFMD_GRAPH_ARGUMENT_VALUE,FFMD_GRAPH_TEXTURE,FFMD_GRAPH_TEXTURE_PLANE,FFMD_GRAPH_SAMPLER};
    uint32_t gs[]={sizeof(ffmd_graph_snapshot),sizeof(ffmd_graph_draw),sizeof(ffmd_graph_binding),sizeof(ffmd_graph_argument_value),sizeof(ffmd_graph_texture),sizeof(ffmd_graph_texture_plane),sizeof(ffmd_graph_sampler)};
    NSData *g=fast_emit(FFMD_GRAPH,identity,sha,gt,gs,@[snaps,draws,bindings,args,textures,planes,samplers]);if(!g)return NO;
    if(plan)*plan=p;if(dynamic)*dynamic=g;return YES;
}

static id<MTLTexture> root_texture(id<MTLTexture> texture){
    for(unsigned i=0;texture&&i<16;i++){
        id<MTLTexture> parent=texture.parentTexture;if(!parent)return texture;texture=parent;
    }
    return nil;
}
static int attachment_alias(const struct wmtcmd_base *head,const struct wmtcmd_base *stop,const struct WMTRenderPassInfo *info){
    id<MTLTexture> targets[3]={root_texture((id<MTLTexture>)info->colors[0].texture),
        root_texture((id<MTLTexture>)info->depth.texture),root_texture((id<MTLTexture>)info->stencil.texture)};
    unsigned seen=0;
    for(const struct wmtcmd_base *entry=head;entry&&entry!=stop&&seen++<65536;entry=entry->next.ptr){
        if(entry->type!=WMTRenderCommandUseResource)continue;
        id<MTLResource> resource=(id<MTLResource>)((const struct wmtcmd_render_useresource *)entry)->resource;
        if(![resource conformsToProtocol:@protocol(MTLTexture)])continue;
        id<MTLTexture> root=root_texture((id<MTLTexture>)resource);if(!root)return 1;
        for(unsigned i=0;i<3;i++)if(root==targets[i])return 1;
    }
    return seen>=65536;
}
/* Immutable full-v2 templates for bounded pass shapes. The source sends their
 * bytes in the same payload as every v3 replay, so cache eviction cannot make
 * a delta depend on an older packet. */
#define SOURCE_REPLAY_TEMPLATE_BYTES (8u*1024u*1024u)
#define SOURCE_REPLAY_TEMPLATE_SLOTS 32u
#define SOURCE_REPLAY_TEMPLATE_ITEM (16u*1024u)
static pthread_mutex_t replay_template_lock=PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray *replay_templates;
static NSUInteger replay_template_bytes;
static NSString *replay_digest(NSData *data){
    unsigned char sha[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,sha);
    static const char digits[]="0123456789abcdef";char hex[65];
    for(unsigned i=0;i<32;i++){hex[i*2]=digits[sha[i]>>4];hex[i*2+1]=digits[sha[i]&15];}hex[64]=0;return @(hex);
}
static int replay_same_shape(NSDictionary *base,NSDictionary *next){
    if(base.count!=next.count||![base[@"format"] isEqual:@"bedrock-native-pass-replay"]||
       ![base[@"version"] isEqual:@2]||![next[@"version"] isEqual:@2]||
       (base[@"shared_attachment_cut"]!=nil)!=(next[@"shared_attachment_cut"]!=nil))return 0;
    for(NSString *key in base)if(![key isEqual:@"draws"]&&![key isEqual:@"cut_id"]&&
       ![key isEqual:@"resource_cut_id"]&&![key isEqual:@"shared_attachment_cut"]&&
       ![base[key] isEqual:next[key]])return 0;
    NSArray *old=base[@"draws"],*fresh=next[@"draws"];
    if(![old isKindOfClass:[NSArray class]]||![fresh isKindOfClass:[NSArray class]]||old.count!=fresh.count)return 0;
    for(NSUInteger i=0;i<old.count;i++){
        NSDictionary *a=old[i],*b=fresh[i];
        if(![a isKindOfClass:[NSDictionary class]]||![b isKindOfClass:[NSDictionary class]]||
           a.count!=b.count||!a[@"indexed"]||!b[@"indexed"])return 0;
        for(NSString *key in a)if(![key isEqual:@"indexed"]&&![a[key] isEqual:b[key]])return 0;
    }return 1;
}
#include "packed_replay.h"
static _Atomic uint64_t packed_used,packed_fallback,packed_matched,packed_mismatch;
static void packed_report(int result){
    _Atomic uint64_t *counter=result==1?&packed_used:result==2?&packed_matched:result==3?&packed_mismatch:&packed_fallback;
    uint64_t n=atomic_fetch_add_explicit(counter,1,memory_order_relaxed)+1;
    if(n<=2||!(n%256))fprintf(stderr,"[packed-replay] used=%llu fallback=%llu matched=%llu mismatch=%llu\n",
        (unsigned long long)atomic_load(&packed_used),(unsigned long long)atomic_load(&packed_fallback),
        (unsigned long long)atomic_load(&packed_matched),(unsigned long long)atomic_load(&packed_mismatch));
}
static NSData *source_replay_bytes(NSDictionary *manifest,NSData **template_bytes){
    *template_bytes=nil;NSNumber *cut=manifest[@"cut_id"];
    if(![cut isKindOfClass:[NSNumber class]]||[cut compare:@0]!=NSOrderedDescending||
       ![manifest[@"resource_cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu",cut.unsignedLongLongValue]]||
       (manifest[@"shared_attachment_cut"]&&![manifest[@"shared_attachment_cut"] isEqual:cut])||
       ![manifest[@"complete_pass"] boolValue])
        return [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    NSArray *draws=manifest[@"draws"],*pipelines=manifest[@"pipelines"];
    if(![draws isKindOfClass:[NSArray class]]||![pipelines isKindOfClass:[NSArray class]])
        return [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    NSString *shape=[NSString stringWithFormat:@"%lu:%lu",(unsigned long)draws.count,(unsigned long)pipelines.count];
    pthread_mutex_lock(&replay_template_lock);NSArray *candidates=[replay_templates copy];pthread_mutex_unlock(&replay_template_lock);
    NSDictionary *base=nil;
    for(NSDictionary *candidate in [candidates reverseObjectEnumerator])
        if([candidate[@"shape"] isEqual:shape]&&replay_same_shape(candidate[@"manifest"],manifest)){
            base=candidate;break;}
    if(base){
        NSMutableArray *overrides=[NSMutableArray array];
        for(NSDictionary *draw in draws)[overrides addObject:draw[@"indexed"]];
        NSDictionary *delta=@{@"format":@"bedrock-native-pass-replay",@"version":@3,@"complete_pass":@YES,
            @"template_sha256":base[@"sha"],@"indexed_overrides":overrides,@"cut_id":cut,
            @"resource_cut_id":manifest[@"resource_cut_id"],
            @"shared_attachment_cut":manifest[@"shared_attachment_cut"]?:[NSNull null]};
        NSData *encoded=[NSJSONSerialization dataWithJSONObject:delta options:0 error:nil];
        if(encoded&&encoded.length<[(NSData *)base[@"data"] length]){
            *template_bytes=[[base[@"data"] retain] autorelease];
            [candidates release];return encoded;
        }
    }
    [candidates release];NSData *full=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    if(!full||full.length>SOURCE_REPLAY_TEMPLATE_ITEM)return full;
    id immutable=[NSJSONSerialization JSONObjectWithData:full options:0 error:nil];if(!immutable)return full;
    NSDictionary *entry=@{@"manifest":immutable,@"data":full,@"sha":replay_digest(full),@"shape":shape};
    pthread_mutex_lock(&replay_template_lock);
    if(!replay_templates)replay_templates=[[NSMutableArray alloc]init];
    while(replay_templates.count&&(replay_templates.count>=SOURCE_REPLAY_TEMPLATE_SLOTS||
          full.length>SOURCE_REPLAY_TEMPLATE_BYTES-replay_template_bytes)){
        NSDictionary *prior=replay_templates[0];replay_template_bytes-=[(NSData *)prior[@"data"] length];
        [replay_templates removeObjectAtIndex:0];
    }
    [replay_templates addObject:entry];replay_template_bytes+=full.length;
    pthread_mutex_unlock(&replay_template_lock);return full;
}
static int write_pass_to_sink(FFSTPassRecord *pass,
    int (*sink)(void *,const char *,const void *,size_t),void *context){
    for(NSString *name in [[pass.libraries allKeys] sortedArrayUsingSelector:@selector(compare:)]){
        NSData *data=pass.libraries[name];
        if(sink(context,name.UTF8String,data.bytes,data.length)!=1)return 0;
    }
    uint64_t started=draw_profile_now();NSData *template=nil;
    if([pass respondsToSelector:@selector(privatePackedReplayBytes)]){
        NSData *packed=[pass privatePackedReplayBytes];NSUInteger mode=[pass privatePackedReplayMode];
        if(mode==1&&packed){
            NSData *old=[NSJSONSerialization dataWithJSONObject:pass.manifest options:0 error:nil];
            NSDictionary *oracle=old?[NSJSONSerialization JSONObjectWithData:old options:0 error:nil]:nil;
            NSDictionary *decoded=packed?packed_replay_decode(packed):nil;
            packed_report(decoded&&oracle&&[decoded isEqual:oracle]?2:3);
        }else if(mode==2&&packed){
            packed_report(1);draw_profile_json(context,started,packed);
            return packed.length<=4u*1024u*1024u&&sink(context,"replay.json",packed.bytes,packed.length)==1;
        }else packed_report(0);
    }
    intptr_t token=(intptr_t)context;
    NSData *data=token< -1&&token>=INT_MIN&&fullframe_chunk_stream_enabled&&fullframe_chunk_stream_enabled()?
        source_replay_bytes(pass.manifest,&template):[NSJSONSerialization dataWithJSONObject:pass.manifest options:0 error:nil];
    draw_profile_json(context,started,data);
    if(template&&sink(context,"replay-template.json",template.bytes,template.length)!=1)return 0;
    return data&&data.length<=4u*1024u*1024u&&sink(context,"replay.json",data.bytes,data.length)==1;
}
static int write_resource_cut(struct ff_draw_cut *c,FFSTPassRecord *pass,NSDictionary *sidecar,NSData **plan_data,int gpu_completed,
    int (*sink)(void *,const char *,const void *,size_t),
    int (*snapshot_sink)(void *,const char *,id<MTLBuffer>,size_t,const ffsa_extent_desc *),void *context,int output_directory){
if(plan_data)*plan_data=nil;if(!c||!sink)return 0;
int ok=gpu_completed&&ff_draw_cut_compact(c);size_t written=0,texture_written=0;
uint64_t graph_started=draw_profile_now(),buffer_sink_ns=0,texture_sink_ns=0;
NSData *fastPlan=nil,*fastWire=nil;
#ifdef BEDROCK_TEST_FAST_GRAPH
extern int fullframe_test_force_dictionary_graph(void);
int allowFast=!fullframe_test_force_dictionary_graph();
#else
int allowFast=1;
#endif
BOOL fast=allowFast&&ok&&pass&&sidecar&&output_directory<0&&plan_data&&ffmd_encode_graph&&
    fast_typed_graph(c,sidecar,&fastPlan,&fastWire);
int hasReference=0;for(size_t i=0;i<c->snapshot_count;i++)if(c->reference_input_version[i])hasReference=1;
if((hasReference||c->direct_pass)&&!fast)return 0; /* no dictionary or filesystem fallback */
NSMutableArray *snapshots=[NSMutableArray array],*vertices=[NSMutableArray array],*constants[2]={[NSMutableArray array],[NSMutableArray array]};
NSMutableArray *args[2]={[NSMutableArray array],[NSMutableArray array]},*textures=[NSMutableArray array],*samplers=[NSMutableArray array];


if(ok&&c->direct_pass){
 uint64_t total=sizeof(ffjp_batch)+c->snapshot_count*sizeof(ffjp_entry);
 for(size_t i=0;i<c->snapshot_count;i++){NSData *event=c->direct_journal[@(i)];if(!event||event.length>64u*1024u*1024u-total)return 0;total+=event.length;}
 NSMutableData *journal=[NSMutableData dataWithLength:(NSUInteger)total];if(!journal)return 0;
 ffjp_batch h={.magic=FFJP_BATCH_MAGIC,.version=1,.count=(uint32_t)c->snapshot_count,.bytes=total};memcpy(journal.mutableBytes,&h,sizeof(h));
 uint32_t offset=(uint32_t)(sizeof(h)+c->snapshot_count*sizeof(ffjp_entry));
 for(size_t i=0;i<c->snapshot_count;i++){NSData *event=c->direct_journal[@(i)];ffjp_entry e={offset,(uint32_t)event.length};
  memcpy((uint8_t*)journal.mutableBytes+sizeof(h)+i*sizeof(e),&e,sizeof(e));memcpy((uint8_t*)journal.mutableBytes+offset,event.bytes,event.length);offset+=(uint32_t)event.length;}
 if(sink(context,"direct-journal.bin",journal.bytes,journal.length)!=1)return 0;
}
BOOL batched[FF_DRAW_RESOURCE_LIMIT]={0};uint32_t batchCount=0;uint64_t batchData=0;
const char *batchMode=getenv("BEDROCK_NATIVE_SNAPSHOT_BATCH");
if(!c->direct_pass&&ok&&fast&&snapshot_sink&&output_directory<0&&batchMode&&!strcmp(batchMode,"1")){
 for(size_t i=0;i<c->snapshot_count;i++){
  uint64_t length=c->serialized_length[i];
  if(c->reference_input_version[i]||c->shared_snapshot_extents[i].lease.generation||!length||length>65536)continue;
  if(!c->snapshots[i].contents||length>c->snapshots[i].length)return 0;
  uint64_t rounded=(length+7)&~UINT64_C(7);
  if(sizeof(ffsb_header)+(batchCount+1)*sizeof(ffsb_entry)+batchData+rounded>FFSB_MAX_BYTES)continue;
  batched[i]=YES;batchCount++;batchData+=rounded;
 }
 if(batchCount){
  uint64_t started=draw_profile_now(),cursor=sizeof(ffsb_header)+(uint64_t)batchCount*sizeof(ffsb_entry),total=cursor+batchData;
  NSMutableData *batch=[NSMutableData dataWithLength:(NSUInteger)total];if(!batch)return 0;
  uint8_t *bytes=batch.mutableBytes;ffsb_header h={.magic=FFSB_MAGIC,.version=1,.count=batchCount,.bytes=total};memcpy(bytes,&h,sizeof(h));uint32_t row=0;
  for(size_t i=0;i<c->snapshot_count;i++)if(batched[i]){
   uint64_t length=c->serialized_length[i];ffsb_entry e={.id=i+1,.offset=cursor,.length=length};memcpy(bytes+sizeof(h)+row++*sizeof(e),&e,sizeof(e));
   memcpy(bytes+cursor,c->snapshots[i].contents,(size_t)length);cursor+=(length+7)&~UINT64_C(7);
  }
  if(!ffsb_validate(bytes,(size_t)total,NULL)||sink(context,FFSB_NAME,bytes,(size_t)total)!=1)return 0;
  buffer_sink_ns+=draw_profile_now()-started;
  static _Atomic uint64_t batches,leaves,logical;uint64_t batchNumber=atomic_fetch_add_explicit(&batches,1,memory_order_relaxed)+1;atomic_fetch_add_explicit(&leaves,batchCount,memory_order_relaxed);atomic_fetch_add_explicit(&logical,batchData,memory_order_relaxed);
  if(batchNumber<=2||!(batchNumber%256))fprintf(stderr,"[snapshot-batch] batches=%llu leaves=%llu bytes=%llu\n",(unsigned long long)batchNumber,(unsigned long long)atomic_load_explicit(&leaves,memory_order_relaxed),(unsigned long long)atomic_load_explicit(&logical,memory_order_relaxed));
 }
}

for(size_t i=0;ok&&i<c->snapshot_count;i++){
    if(c->direct_pass){++written;continue;}
    if(batched[i]){++written;continue;}
    char name[32];snprintf(name,sizeof(name),"cut-buffer-%02zu.bin",i+1);id<MTLBuffer> b=c->snapshots[i];
    uint64_t length=c->serialized_length[i];
    if(c->reference_input_version[i]){
        if(!fast||b||!length||length!=c->source_length[i]||!c->reference_stream||!c->reference_frame||
           !c->reference_chunk||!c->reference_payload||!c->source_incarnation[i]||!c->source_generation[i]||
           c->source_offset[i]>UINT64_MAX-length){ok=0;break;}
        ff_native_buffer_ref ref={.magic=FF_NATIVE_BUFFER_REF_MAGIC,.version=FF_NATIVE_BUFFER_REF_VERSION,
            .stream=c->reference_stream,.frame=c->reference_frame,.chunk=c->reference_chunk,
            .payload=c->reference_payload,.snapshot_id=i+1,.root=c->source_incarnation[i],
            .generation=c->source_generation[i],.input_version=c->reference_input_version[i],
            .offset=c->source_offset[i],.length=length};
        snprintf(name,sizeof(name),"cut-buffer-%02zu.nref",i+1);
        if(sink(context,name,&ref,sizeof(ref))!=1){ok=0;break;}++written;continue;
    }
    if(c->shared_snapshot_extents[i].lease.generation&&b.contents&&length<=b.length){
        /* Native wraps only the compacted logical length rounded to 16 KiB.
         * Clear that visible padding, not the unused source capture tail. */
        uint64_t physical=(length+FFSA_ALIGNMENT-1)&~((uint64_t)FFSA_ALIGNMENT-1);
        if(physical>b.length)physical=b.length;
        memset((unsigned char *)b.contents+length,0,(size_t)(physical-length));
    }
    if(!b.contents||!length||length>b.length){ok=0;break;}
    uint64_t sink_started=draw_profile_now();int accepted=snapshot_sink?
        snapshot_sink(context,name,b,(size_t)length,&c->shared_snapshot_extents[i]):
        sink(context,name,b.contents,(size_t)length);
    uint64_t sink_ended=draw_profile_now();if(sink_ended>=sink_started)buffer_sink_ns+=sink_ended-sink_started;
    if(accepted!=1){ok=0;break;}++written;
    if(!fast)[snapshots addObject:@{ @"id":@(i+1),@"generation":@1,@"file":@(name),@"length":@(length),
        @"source_incarnation":@(c->source_incarnation[i]),@"source_generation":@(c->source_generation[i]),@"source_offset":@(c->source_offset[i]) }];
}
if(!fast)for(size_t i=0;i<c->binding_count;i++)[vertices addObject:binding(c->bindings[i])];
if(!fast)for(unsigned st=0;st<2;st++){
    for(size_t i=0;i<c->layout.constant_count[st];i++)[constants[st] addObject:binding(c->constants[st][i])];
    for(size_t i=0;i<c->layout.arguments[st].field_count;i++){
        ff_argument_binding a=c->arguments[st][i];
        NSMutableDictionary *d=[@{@"offset":@(a.offset),@"kind":@(a.kind),@"value":@(a.value)} mutableCopy];
        if(a.kind==FF_FIELD_BUFFER)d[@"buffer"]=binding(a.buffer);[args[st] addObject:d];[d release];
    }
}
for(size_t i=0;ok&&i<c->texture_count;i++){
    ff_texture_snapshot t=c->textures[i];
    if(c->direct_pass&&c->direct_texture_versions[i]){char refname[40];snprintf(refname,sizeof(refname),"journal-texture-%02zu.bin",i+1);
      uint64_t version=c->direct_texture_versions[i];if(sink(context,refname,&version,sizeof(version))!=1){ok=0;break;}++texture_written;continue;}char name[32];snprintf(name,sizeof(name),"cut-texture-%02zu.bin",i+1);
    if(!t.bytes){ok=0;break;}
    uint64_t sink_started=draw_profile_now();int accepted=sink(context,name,t.bytes,t.length);
    uint64_t sink_ended=draw_profile_now();if(sink_ended>=sink_started)texture_sink_ns+=sink_ended-sink_started;
    if(accepted!=1){ok=0;break;}++texture_written;
    if(!fast){NSMutableArray *planes=[NSMutableArray array];
        for(size_t j=0;j<t.plane_count;j++){ff_texture_plane p=t.planes[j];[planes addObject:@{@"mip":@(p.mip),@"slice":@(p.slice),@"offset":@(p.offset),@"row_bytes":@(p.row_bytes),@"length":@(p.length)}];}
        [textures addObject:@{@"id":@(t.id),@"file":@(name),@"length":@(t.length),@"format":@(t.format),@"texture_type":@(t.texture_type),
            @"width":@(t.width),@"height":@(t.height),@"mip_count":@(t.mip_count),@"array_length":@(t.array_length),
            @"swizzle":@[@(t.swizzle[0]),@(t.swizzle[1]),@(t.swizzle[2]),@(t.swizzle[3])],@"planes":planes}];}
}
if(!fast)for(size_t i=0;i<c->sampler_count;i++){
    ff_sampler_snapshot s=c->samplers[i];[samplers addObject:@{@"id":@(s.id),@"address":@[@(s.address[0]),@(s.address[1]),@(s.address[2])],
        @"min_filter":@(s.min_filter),@"mag_filter":@(s.mag_filter),@"mip_filter":@(s.mip_filter),@"compare":@(s.compare),@"border":@(s.border),
        @"max_anisotropy":@(s.max_anisotropy),@"lod_min":@(s.lod_min),@"lod_max":@(s.lod_max),@"normalized":@(s.normalized),@"lod_average":@(s.lod_average)}];
}
if(ok){
    if(fast){
        NSDictionary *envelope=@{@"format":@"bedrock-draw-resource-cut",@"version":@3,
            @"cut_id":[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)c->capture_id],@"complete_pass":@YES,
            @"direct_pass":(c->direct_pass?@YES:@NO),@"wire_blob":@"draw-resource-cut.bin",@"wire_sha256":replay_digest(fastWire),
            @"plan_blob":@"draw-plan.bin",@"plan_sha256":replay_digest(fastPlan)};
        uint64_t started=draw_profile_now();NSData *data=[NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
        draw_profile_json(context,started,data);
        ok=data&&data.length<=8u*1024u*1024u&&sink(context,"draw-plan.bin",fastPlan.bytes,fastPlan.length)==1&&
            sink(context,"draw-resource-cut.bin",fastWire.bytes,fastWire.length)==1&&sink(context,"draw-resource-cut.json",data.bytes,data.length)==1;
        if(ok)*plan_data=[[fastPlan retain] autorelease];
    }else{
    NSMutableDictionary *record=[@{@"format":@"bedrock-draw-resource-cut",@"version":@1,
        @"scope":@"exact first ordinary draw logical resources at pre-pass cut",
        @"cut_id":[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)c->capture_id],@"ia_slot_mask":@(c->ia_slot_mask),
        @"primitive":@(c->primitive),@"vertex_start":@(c->vertex_start),@"vertex_count":@(c->vertex_count),
        @"instance_count":@(c->instance_count),@"base_instance":@(c->base_instance),@"snapshots":snapshots,@"bindings":vertices,
        @"vertex_constants":constants[0],@"fragment_constants":constants[1],@"arguments":@[args[0],args[1]],
        @"argument_bytes":@[@(c->layout.arguments[0].byte_length),@(c->layout.arguments[1].byte_length)],@"textures":textures,@"samplers":samplers} mutableCopy];
    if(c->indexed){record[@"index_binding"]=binding(c->index_binding);record[@"indexed"]=@{@"index_type":@(c->index_type),@"base_vertex":@(c->base_vertex),@"index_count":@(c->vertex_count),@"index_offset":@(c->index_offset)};}
    if(pass){
        NSMutableArray *draws=[NSMutableArray array];for(size_t i=0;i<c->draw_count;i++)[draws addObject:plan_binding_record(&c->draws[i])];
        record[@"version"]=@2;record[@"draws"]=draws;record[@"draw_count"]=@(c->draw_count);
        record[@"complete_pass"]=@(c->complete_pass);record[@"stop_reason"]=@(c->stop_reason);
        record[@"stop_command_type"]=@(c->stop_command_type);record[@"resource_detail"]=@(c->resource_detail);
        record[@"scope"]=@"ordered ordinary draw prefix with one immutable resource graph";
    }
    NSData *plan=nil,*wire=nil;BOOL typed=sidecar&&output_directory<0&&plan_data&&ffmd_encode_graph&&
        ffmd_encode_graph(record,sidecar,&plan,&wire);
    if(typed){
        NSDictionary *envelope=@{@"format":@"bedrock-draw-resource-cut",@"version":@3,
            @"cut_id":record[@"cut_id"],@"complete_pass":@YES,
            @"wire_blob":@"draw-resource-cut.bin",@"wire_sha256":replay_digest(wire),
            @"plan_blob":@"draw-plan.bin",@"plan_sha256":replay_digest(plan)};
        uint64_t started=draw_profile_now();NSData *data=[NSJSONSerialization dataWithJSONObject:envelope options:0 error:nil];
        draw_profile_json(context,started,data);
        ok=data&&data.length<=8u*1024u*1024u&&
            sink(context,"draw-plan.bin",plan.bytes,plan.length)==1&&
            sink(context,"draw-resource-cut.bin",wire.bytes,wire.length)==1&&
            sink(context,"draw-resource-cut.json",data.bytes,data.length)==1;
        if(ok)*plan_data=[[plan retain] autorelease];
    }else{
        uint64_t started=draw_profile_now();NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
        draw_profile_json(context,started,data);
        ok=data&&data.length<=8u*1024u*1024u&&sink(context,"draw-resource-cut.json",data.bytes,data.length)==1;
    }
    [record release];}
    uint64_t graph_ended=draw_profile_now(),graph_ns=graph_ended>=graph_started?graph_ended-graph_started:0;
    draw_profile_stage(context,FFSC_PROFILE_BUFFER_SINK,buffer_sink_ns);
    draw_profile_stage(context,FFSC_PROFILE_TEXTURE_SINK,texture_sink_ns);
    draw_profile_stage(context,FFSC_PROFILE_GRAPH,graph_ns>=buffer_sink_ns+texture_sink_ns?
        graph_ns-buffer_sink_ns-texture_sink_ns:0);
    uint64_t replay_started=draw_profile_now();
    if(ok&&pass)ok=output_directory>=0?ffst_pass_capture_write(output_directory,pass,"replay.json"):write_pass_to_sink(pass,sink,context);
    uint64_t replay_ended=draw_profile_now();draw_profile_stage(context,FFSC_PROFILE_REPLAY,
        replay_ended>=replay_started?replay_ended-replay_started:0);
}
if(!ok&&output_directory>=0){
    for(size_t i=0;i<written;i++){char name[32];snprintf(name,sizeof(name),"cut-buffer-%02zu.bin",i+1);unlinkat(output_directory,name,0);}
    for(size_t i=0;i<texture_written;i++){char name[32];snprintf(name,sizeof(name),"cut-texture-%02zu.bin",i+1);unlinkat(output_directory,name,0);}
}
if(!ok||log_cut_success(context,output_directory))fprintf(stderr,"[full-frame-draw-cut] %s buffers=%zu textures=%zu samplers=%zu indexed=%u draws=%zu pass_complete=%d stop=%u detail=%u captured_buffer_bytes=%zu serialized_buffer_bytes=%zu\n",ok?"complete":"failed",c->snapshot_count,c->texture_count,c->sampler_count,c->indexed,c->draw_count,c->complete_pass,c->stop_reason,c->resource_detail,c->snapshot_bytes,c->serialized_bytes);
    return ok;
}
int fullframe_write_resource_cut_to_sink(struct ff_draw_cut *c,FFSTPassRecord *pass,int gpu_completed,
    int (*sink)(void *,const char *,const void *,size_t),void *context){
    return write_resource_cut(c,pass,nil,nil,gpu_completed,sink,NULL,context,-1);
}
int fullframe_write_resource_cut_typed_to_sink(struct ff_draw_cut *c,FFSTPassRecord *pass,
    NSDictionary *sidecar,NSData **plan_data,int gpu_completed,
    int (*sink)(void *,const char *,const void *,size_t),void *context){
    return write_resource_cut(c,pass,sidecar,plan_data,gpu_completed,sink,NULL,context,-1);
}
int fullframe_write_resource_cut_to_owned_sink(struct ff_draw_cut *c,FFSTPassRecord *pass,
    NSDictionary *sidecar,NSData **plan_data,int gpu_completed,
    int (*sink)(void *,const char *,const void *,size_t),
    int (*snapshot_sink)(void *,const char *,id<MTLBuffer>,size_t,const ffsa_extent_desc *),void *context){
    if(!snapshot_sink)return 0;
    return write_resource_cut(c,pass,sidecar,plan_data,gpu_completed,sink,snapshot_sink,context,-1);
}
static int directory_sink(void *context,const char *name,const void *bytes,size_t length){
    return write_file(*(int *)context,name,bytes,length);
}
int fullframe_write_resource_cut(int directory,struct ff_draw_cut *c,FFSTPassRecord *pass,int gpu_completed){
    if(directory<0)return 0;
    return write_resource_cut(c,pass,nil,nil,gpu_completed,directory_sink,NULL,&directory,directory);
}
static void complete(struct ff_draw_cut *c,int gpu_completed,void *unused){
    if(c->discarded){ff_draw_cut_destroy(c);return;}
    (void)unused;dispatch_async(writer,^{@autoreleasepool{
        FFSTPassRecord *pass=objc_getAssociatedObject(c->ready_fence,&pass_record_key);
        (void)fullframe_write_resource_cut(directory,c,pass,gpu_completed);
        ff_draw_cut_destroy(c);
    }});
}
static int material_geometry(const ff_draw_plan *d){
    if(d->vertex_count<=6||!d->layout.ia_slot_mask||!d->layout.constant_count[0])return 0;
    for(unsigned st=0;st<2;st++)for(size_t i=0;i<d->layout.arguments[st].field_count;i++)
        if(d->arguments[st][i].kind==FF_FIELD_TEXTURE&&d->arguments[st][i].value)return 1;
    return 0;
}
struct pass_filter_context {id<MTLCommandBuffer> command;const struct WMTRenderPassInfo *info;const struct wmtcmd_base *head;FFSTPassRecord *record;};
static int pass_filter(const struct ff_draw_cut *c,void *opaque){
    static _Atomic uint64_t rejections;
    struct pass_filter_context *ctx=opaque;int material=0;
    for(size_t i=0;i<c->draw_count;i++)if(material_geometry(&c->draws[i]))material=1;
    FFSTPassRecord *record=nil;
    if(c->draw_count>=2&&material&&!attachment_alias(ctx->head,c->stop_command,ctx->info))
        record=fullframe_replay_pass_record(ctx->command,ctx->info,ctx->head,c);
    NSUInteger emitted=[record.manifest[@"draws"] count];material=0;
    for(size_t i=0;i<emitted&&i<c->draw_count;i++)if(material_geometry(&c->draws[i]))material=1;
    if(!record||emitted<2||emitted>c->draw_count||!material){
        uint64_t count=atomic_fetch_add(&rejections,1)+1;
        if(!(count&(count-1)))fprintf(stderr,"[full-frame-pass-reject] count=%llu draws=%zu emitted=%lu stop=%u command=%u detail=%u complete=%d\n",
            (unsigned long long)count,c->draw_count,(unsigned long)emitted,c->stop_reason,c->stop_command_type,c->resource_detail,c->complete_pass);
        return 0;
    }
    ctx->record=[record retain];return 1;
}
static int pass_layout(id<MTLRenderPipelineState> pipeline,const struct wmtcmd_base *draw,ff_draw_layout *layout,void *context){
    (void)draw;(void)context;return fullframe_replay_cut_layout(pipeline,layout);
}
static void capture_pass(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info){
    int expected=0;if(!atomic_compare_exchange_strong(&claimed,&expected,1))return;
    id<MTLFence> fences[FF_DRAW_FENCE_LIMIT];for(size_t i=0;i<info->bedrock_cut_fence_count;i++)fences[i]=(id<MTLFence>)info->bedrock_cut_fences[i];
    struct pass_filter_context ctx={.command=command,.info=info,.head=info->bedrock_cut_commands.ptr};struct ff_draw_cut *cut=NULL;
    if(!ff_draw_pass_cut_schedule_checked(command,ctx.head,(id<MTLBuffer>)info->bedrock_cut_argbuffer,pass_layout,NULL,
        fences,info->bedrock_cut_fence_count,FF_DRAW_PASS_LIMIT,pass_filter,&ctx,complete,NULL,&cut)){
        [ctx.record release];atomic_store(&claimed,0);return;
    }
    info->bedrock_cut_ready_fence=(obj_handle_t)cut->ready_fence;
    if(!copy_load_attachments(command,info,cut,fences,info->bedrock_cut_fence_count)||!fullframe_replay_pass_claim(ctx.record)){
        cut->discarded=1;[ctx.record release];atomic_store(&claimed,0);return;
    }
    objc_setAssociatedObject(cut->ready_fence,&pass_record_key,ctx.record,OBJC_ASSOCIATION_RETAIN_NONATOMIC);[ctx.record release];
    fprintf(stderr,"[full-frame-pass] scheduled draws=%zu complete=%d stop=%u command=%u detail=%u\n",
        cut->draw_count,cut->complete_pass,cut->stop_reason,cut->stop_command_type,cut->resource_detail);
}
void fullframe_draw_cut_bridge(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info){
    const char *frame=getenv("DXMT_FRAME_STREAM");if(frame&&!strcmp(frame,"1"))return;
    if(directory<0||atomic_load(&claimed)||!command||!info||info->bedrock_cut_magic!=UINT64_C(0x4244464355543033)||
       !info->bedrock_cut_ordinary||info->bedrock_cut_fence_count>FF_DRAW_FENCE_LIMIT||!info->bedrock_cut_commands.ptr||
       !info->bedrock_cut_argbuffer)return;
    if(pass_mode&&!fullframe_replay_capture_armed())return;
    if(!fullframe_replay_pass_eligible(info))return;
    if(pass_mode){capture_pass(command,info);return;}
    const struct wmtcmd_base *head=info->bedrock_cut_commands.ptr,*next=head;id<MTLRenderPipelineState> pipeline=nil;
    struct WMTViewport viewport={0};struct WMTScissorRect scissor={0};struct wmtcmd_render_setrasterizerstate raster={0};unsigned state=0;
    for(unsigned seen=0;next&&seen<4096;seen++,next=next->next.ptr){
        enum WMTRenderCommandType t=(enum WMTRenderCommandType)next->type;
        if(t==WMTRenderCommandSetPSO)pipeline=(id<MTLRenderPipelineState>)((const struct wmtcmd_render_setpso *)next)->pso;
        if(t==WMTRenderCommandSetViewport){viewport=((const struct wmtcmd_render_setviewport *)next)->viewport;state|=1;}
        else if(t==WMTRenderCommandSetViewports){const struct wmtcmd_render_setviewports *v=(const void *)next;if(v->viewport_count!=1||!v->viewports.ptr)return;viewport=*(const struct WMTViewport *)v->viewports.ptr;state|=1;}
        else if(t==WMTRenderCommandSetScissorRect){scissor=((const struct wmtcmd_render_setscissorrect *)next)->scissor_rect;state|=2;}
        else if(t==WMTRenderCommandSetScissorRects){const struct wmtcmd_render_setscissorrects *s=(const void *)next;if(s->rect_count!=1||!s->scissor_rects.ptr)return;scissor=*(const struct WMTScissorRect *)s->scissor_rects.ptr;state|=2;}
        else if(t==WMTRenderCommandSetRasterizerState){raster=*(const struct wmtcmd_render_setrasterizerstate *)next;state|=4;}
        if(t==WMTRenderCommandDraw||t==WMTRenderCommandDrawIndexed)break;
        if(t==WMTRenderCommandDrawIndirect||t==WMTRenderCommandDrawIndexedIndirect||t==WMTRenderCommandDrawMeshThreadgroups||t==WMTRenderCommandDrawMeshThreadgroupsIndirect||t==WMTRenderCommandDispatchThreadsPerTile)return;
    }
    ff_draw_layout layout={0};if(!next||!pipeline||state!=7||!fullframe_replay_cut_layout(pipeline,&layout)||
        !fullframe_replay_draw_eligible(pipeline,next))return;
    /* An attachment clear happens after our prepass. Sampling an alias would
     * therefore consume different bytes; conservatively reject all such views. */
    if(attachment_alias(head,next,info))return;
    uint64_t count,instances,start;
    if(next->type==WMTRenderCommandDraw){const struct wmtcmd_render_draw *d=(const void *)next;count=d->vertex_count;instances=d->instance_count;start=d->vertex_start;
        if(!layout.ia_slot_mask&&!layout.constant_count[0]&&!layout.constant_count[1]&&!layout.arguments[0].byte_length&&!layout.arguments[1].byte_length)return;
    }else if(next->type==WMTRenderCommandDrawIndexed){const struct wmtcmd_render_draw_indexed *d=(const void *)next;count=d->index_count;instances=d->instance_count;start=0;}else return;
    id<MTLTexture> target=(id<MTLTexture>)info->colors[0].texture;const double *v=(const double *)&viewport;
    for(unsigned i=0;i<6;i++)if(!isfinite(v[i]))return;
    if(!count||!instances||start>UINT32_MAX||instances>1000000||count>10000000/instances||
       scissor.x>target.width||scissor.y>target.height||!scissor.width||!scissor.height||
       scissor.width>target.width-scissor.x||scissor.height>target.height-scissor.y||viewport.width<=0||viewport.height<=0||
       viewport.znear<0||viewport.zfar>1||viewport.znear>viewport.zfar||raster.fill_mode>1||raster.cull_mode>2||raster.depth_clip_mode>1||raster.winding>1||
       !isfinite(raster.depth_bias)||!isfinite(raster.scole_scale)||!isfinite(raster.depth_bias_clamp))return;
    int expected=0;if(!atomic_compare_exchange_strong(&claimed,&expected,1))return;
    id<MTLFence> fences[FF_DRAW_FENCE_LIMIT];for(size_t i=0;i<info->bedrock_cut_fence_count;i++)fences[i]=(id<MTLFence>)info->bedrock_cut_fences[i];
    struct ff_draw_cut *cut=NULL;
    if(!ff_draw_cut_schedule(command,head,(id<MTLBuffer>)info->bedrock_cut_argbuffer,&layout,fences,info->bedrock_cut_fence_count,complete,NULL,&cut)){atomic_store(&claimed,0);return;}
    info->bedrock_cut_ready_fence=(obj_handle_t)cut->ready_fence;
    if(!copy_load_attachments(command,info,cut,fences,info->bedrock_cut_fence_count)){
        /* Resource copies are already encoded: keep their wait for the original
         * renderer, but leave the arm untouched and publish no partial cut. */
        cut->discarded=1;atomic_store(&claimed,0);return;
    }
    fullframe_replay_cut_ready(command,cut->draw_command,[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)cut->capture_id]);
}
void fullframe_draw_cut_begin(id<MTLRenderCommandEncoder> encoder,const struct WMTRenderPassInfo *info){
    if(encoder&&info&&info->bedrock_cut_magic==UINT64_C(0x4244464355543033)&&info->bedrock_cut_ready_fence){
        id<MTLFence> resource=(id<MTLFence>)info->bedrock_cut_ready_fence;
        [encoder waitForFence:resource beforeStages:MTLRenderStageVertex|MTLRenderStageFragment];
        id<MTLFence> load=objc_getAssociatedObject(resource,&load_fence_key);
        if(load)[encoder waitForFence:load beforeStages:MTLRenderStageVertex|MTLRenderStageFragment];
    }
}
#else
void fullframe_draw_cut_bridge(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info){(void)command;(void)info;}
void fullframe_draw_cut_begin(id<MTLRenderCommandEncoder> encoder,const struct WMTRenderPassInfo *info){(void)encoder;(void)info;}
#endif
