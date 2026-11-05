#import "draw_resource_cut.h"
#include "direct_pass_journal.h"
extern void *fullframe_direct_journal_copy(uint64_t,uint64_t,uint64_t,uint64_t,size_t,size_t *);
#ifdef BEDROCK_BOUNDARY_UPLOADS
#include "native_boundary_upload.h"
#endif
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <pthread.h>
#include <stdio.h>
#include <stdarg.h>
static void cut_failure(const char *format, ...) {
    uint64_t thread=0;(void)pthread_threadid_np(NULL,&thread);
    flockfile(stderr);fprintf(stderr,"[full-frame-resource-cut-failed] thread=%llu ",(unsigned long long)thread);
    va_list args;va_start(args,format);vfprintf(stderr,format,args);va_end(args);funlockfile(stderr);
}
static _Atomic uint64_t next_capture=1;
static _Atomic uint64_t rejected_counts[6];
static int rejected(unsigned reason){
    static const char *names[]={"buffer-identity","buffer-provenance","logical-slice","texture-profile","sampler-identity","table-range"};
    uint64_t count=atomic_fetch_add(&rejected_counts[reason],1)+1;
    if(count&&!(count&(count-1)))fprintf(stderr,"[full-frame-resource-cut-reject] reason=%s count=%llu\n",names[reason],(unsigned long long)count);
    return 0;
}
struct vertex_entry {uint64_t address;uint32_t stride,length;};
_Static_assert(sizeof(struct vertex_entry)==16,"DXMT vertex table ABI");
struct sampler_entry {id<MTLSamplerState> object;ff_sampler_snapshot data;};
static struct sampler_entry sampler_registry[128];
static unsigned sampler_cursor;
static pthread_mutex_t sampler_lock=PTHREAD_MUTEX_INITIALIZER;
void fullframe_resource_sampler(id<MTLSamplerState> sampler,MTLSamplerDescriptor *d){
    if(!sampler||!d||!d.supportArgumentBuffers||!sampler.gpuResourceID._impl)return;
    ff_sampler_snapshot s={.address={d.sAddressMode,d.tAddressMode,d.rAddressMode},.min_filter=d.minFilter,.mag_filter=d.magFilter,
        .mip_filter=d.mipFilter,.compare=d.compareFunction,.border=d.borderColor,.max_anisotropy=(uint32_t)d.maxAnisotropy,
        .lod_min=d.lodMinClamp,.lod_max=d.lodMaxClamp,.normalized=d.normalizedCoordinates,.lod_average=d.lodAverage};
    pthread_mutex_lock(&sampler_lock);unsigned i=sampler_cursor++%128;
    [sampler_registry[i].object release];sampler_registry[i]=(struct sampler_entry){[sampler retain],s};pthread_mutex_unlock(&sampler_lock);
}
static int sampler_lookup(uint64_t handle,ff_sampler_snapshot *s){
    int found=0;pthread_mutex_lock(&sampler_lock);
    for(unsigned i=0;i<128;i++)if(sampler_registry[i].object.gpuResourceID._impl==handle){*s=sampler_registry[i].data;found=1;break;}
    pthread_mutex_unlock(&sampler_lock);return found?1:rejected(4);
}
id<MTLSamplerState> fullframe_boundary_copy_sampler(uint64_t handle){
    static NSMutableDictionary *copies;ff_sampler_snapshot v;
    if(!sampler_lookup(handle,&v))return nil;
    pthread_mutex_lock(&sampler_lock);if(!copies)copies=[[NSMutableDictionary alloc]init];
    id<MTLSamplerState> result=copies[@(handle)];
    if(!result&&copies.count<128){
        MTLSamplerDescriptor *d=[[MTLSamplerDescriptor alloc]init];
        d.sAddressMode=v.address[0];d.tAddressMode=v.address[1];d.rAddressMode=v.address[2];
        d.minFilter=v.min_filter;d.magFilter=v.mag_filter;d.mipFilter=v.mip_filter;
        d.compareFunction=v.compare;d.borderColor=v.border;d.maxAnisotropy=v.max_anisotropy;
        d.lodMinClamp=v.lod_min;d.lodMaxClamp=v.lod_max;d.normalizedCoordinates=v.normalized;d.lodAverage=v.lod_average;d.supportArgumentBuffers=YES;
        id<MTLDevice> device=nil;for(unsigned i=0;i<128;i++)if(sampler_registry[i].object.gpuResourceID._impl==handle){device=sampler_registry[i].object.device;break;}
        result=[device newSamplerStateWithDescriptor:d];if(result)copies[@(handle)]=result;[result release];[d release];
    }
    pthread_mutex_unlock(&sampler_lock);return result;
}

/* Bounded persistent staging. Exact device/length free lists and a pointer
 * lease index avoid scanning every active buffer. Source cuts and every
 * no-copy packet owner retain their original explicit leases. */
#include <limits.h>
extern int fullframe_direct_upload_mode(void);
extern int fullframe_direct_upload_copy(uint64_t,uint64_t,uint64_t,uint64_t,void *,size_t);
#define STAGE_POOL_COUNT 4096
#define STAGE_POOL_BUCKETS 8192
static struct {id<MTLBuffer> buffer;id<MTLDevice> device;NSUInteger length,cost;unsigned refs;int good,bad;uint16_t idle_next,pointer_next;} stage_pool[STAGE_POOL_COUNT];
static uint16_t stage_pool_idle[STAGE_POOL_BUCKETS],stage_pool_pointers[STAGE_POOL_BUCKETS],stage_pool_free[STAGE_POOL_COUNT];
static size_t stage_pool_used,stage_pool_free_count;
static pthread_mutex_t stage_pool_lock=PTHREAD_MUTEX_INITIALIZER;
static uint64_t stage_pool_bytes,stage_pool_hits,stage_pool_misses;
static size_t stage_hash(uint64_t x){x^=x>>33;x*=UINT64_C(0xff51afd7ed558ccd);x^=x>>33;return (size_t)x&(STAGE_POOL_BUCKETS-1);}
static size_t stage_size_bucket(id<MTLDevice> device,NSUInteger length){return stage_hash((uintptr_t)device^(length*UINT64_C(0x9e3779b97f4a7c15)));}
static size_t stage_pointer_bucket(id<MTLBuffer> buffer){return stage_hash((uintptr_t)buffer);}
static uint16_t stage_find(id<MTLBuffer> buffer){for(uint16_t n=stage_pool_pointers[stage_pointer_bucket(buffer)];n;n=stage_pool[n-1].pointer_next)if(stage_pool[n-1].buffer==buffer)return n;return 0;}
static int stage_pool_enabled(void){static int initialized,enabled;
 if(!initialized){const char *p=getenv("BEDROCK_SOURCE_STAGING_POOL");enabled=p&&!strcmp(p,"1");initialized=1;}return enabled;}
static id<MTLBuffer> stage_buffer(id<MTLDevice> device,NSUInteger length){
 pthread_mutex_lock(&stage_pool_lock);int enabled=stage_pool_enabled()&&length&&length<=65536;
 if(!enabled){pthread_mutex_unlock(&stage_pool_lock);return [device newBufferWithLength:length options:MTLResourceStorageModeShared];}
 uint16_t *link=&stage_pool_idle[stage_size_bucket(device,length)];
 while(*link){size_t i=*link-1;
  if(!stage_pool[i].refs&&stage_pool[i].good&&!stage_pool[i].bad&&stage_pool[i].device==device&&stage_pool[i].length==length){
   *link=stage_pool[i].idle_next;stage_pool[i].idle_next=0;stage_pool[i].refs=1;stage_pool[i].good=stage_pool[i].bad=0;stage_pool_hits++;
   if(stage_pool_hits<=2||!(stage_pool_hits%4096))fprintf(stderr,"[source-staging-pool] hits=%llu misses=%llu bytes=%llu\n",(unsigned long long)stage_pool_hits,(unsigned long long)stage_pool_misses,(unsigned long long)stage_pool_bytes);
   id<MTLBuffer> b=[stage_pool[i].buffer retain];pthread_mutex_unlock(&stage_pool_lock);return b;}
  link=&stage_pool[i].idle_next;
 }
 uint16_t slot=stage_pool_free_count?stage_pool_free[--stage_pool_free_count]:stage_pool_used<STAGE_POOL_COUNT?(uint16_t)(++stage_pool_used):0;
 stage_pool_misses++;pthread_mutex_unlock(&stage_pool_lock);
 id<MTLBuffer> b=[device newBufferWithLength:length options:MTLResourceStorageModeShared];
 pthread_mutex_lock(&stage_pool_lock);NSUInteger cost=b?MAX(b.allocatedSize,b.length):0;
 if(slot&&b&&cost&&cost<=16u*1024u*1024u-stage_pool_bytes){size_t i=slot-1;
  stage_pool[i].buffer=[b retain];stage_pool[i].device=device;stage_pool[i].length=length;stage_pool[i].cost=cost;stage_pool[i].refs=1;
  size_t bucket=stage_pointer_bucket(b);stage_pool[i].pointer_next=stage_pool_pointers[bucket];stage_pool_pointers[bucket]=slot;stage_pool_bytes+=cost;
 }else if(slot)stage_pool_free[stage_pool_free_count++]=slot;
 pthread_mutex_unlock(&stage_pool_lock);return b;
}
void fullframe_stage_pool_retain(id<MTLBuffer> buffer){
 if(!buffer)return;pthread_mutex_lock(&stage_pool_lock);uint16_t n=stage_find(buffer);
 if(n){size_t i=n-1;if(stage_pool[i].refs&&stage_pool[i].refs<UINT_MAX)stage_pool[i].refs++;else stage_pool[i].bad=1;}
 pthread_mutex_unlock(&stage_pool_lock);
}
void fullframe_stage_pool_release(id<MTLBuffer> buffer,unsigned completion){
 if(!buffer)return;id<MTLBuffer> discarded=nil;pthread_mutex_lock(&stage_pool_lock);uint16_t n=stage_find(buffer);
 if(n){size_t i=n-1;
  if(completion==2)stage_pool[i].good=1;else if(!completion)stage_pool[i].bad=1;
  if(stage_pool[i].refs)stage_pool[i].refs--;else stage_pool[i].bad=1;
  if(!stage_pool[i].refs){
   size_t bucket=stage_size_bucket(stage_pool[i].device,stage_pool[i].length);
   if(stage_pool[i].good&&!stage_pool[i].bad){stage_pool[i].idle_next=stage_pool_idle[bucket];stage_pool_idle[bucket]=n;}
   else {
    uint16_t *link=&stage_pool_pointers[stage_pointer_bucket(buffer)];while(*link&&*link!=n)link=&stage_pool[*link-1].pointer_next;if(*link)*link=stage_pool[i].pointer_next;
    link=&stage_pool_idle[bucket];while(*link&&*link!=n)link=&stage_pool[*link-1].idle_next;if(*link)*link=stage_pool[i].idle_next;
    discarded=stage_pool[i].buffer;stage_pool_bytes-=stage_pool[i].cost;memset(&stage_pool[i],0,sizeof(stage_pool[i]));stage_pool_free[stage_pool_free_count++]=n;
   }
  }
 }
 pthread_mutex_unlock(&stage_pool_lock);[discarded release];
}

void ff_draw_cut_destroy(struct ff_draw_cut *c){
    if(!c)return;
    for(size_t i=0;i<c->snapshot_count;i++){free(c->direct_shadow[i]);fullframe_stage_pool_release(c->snapshots[i],(c->staging_gpu_completed||c->direct_cpu_ready)?2:0);[c->snapshots[i] release];}
    for(size_t i=0;i<c->texture_count;i++)[c->texture_buffers[i] release];
    [c->texture_reuse release];[c->direct_journal release];[c->ready_fence release];free(c->draws);free(c);
}
static int compact_use(const struct ff_draw_cut *c,const ff_vertex_binding *b,uint64_t length,uint64_t *needed,int allow_reference){
    if(!b->id)return !b->generation&&!b->offset&&!b->stride&&!b->length;
    if(b->id>c->snapshot_count||b->generation!=1||length>b->length)return 0;
    size_t i=b->id-1;uint64_t size=c->source_length[i];
    if(c->reference_input_version[i]){if(!allow_reference||c->snapshots[i])return 0;}
    else if(size>c->snapshots[i].length)return 0;
    if(b->offset>size||b->length>size-b->offset)return 0;
    needed[i]=MAX(needed[i],b->offset+length);return 1;
}
static int compact_vertex_max(const struct ff_draw_cut *c,const ff_draw_plan *d,uint64_t *maximum){
    if(!d->vertex_count||!d->instance_count)return 0;
    if(!d->indexed){
        if(d->vertex_start>UINT32_MAX||d->vertex_count-1>UINT32_MAX-d->vertex_start)return 0;
        *maximum=d->vertex_start+d->vertex_count-1;return 1;
    }
    const ff_vertex_binding *b=&d->index_binding;uint64_t width=d->index_type?4:2;
    if(d->index_type>1||!b->id||b->id>c->snapshot_count||b->generation!=1||
       d->vertex_count>UINT64_MAX/width||d->vertex_count*width>b->length)return 0;
    id<MTLBuffer> snapshot=c->snapshots[b->id-1];
    uint64_t size=c->source_length[b->id-1];
    if(!snapshot.contents||size>snapshot.length||b->offset>size||d->vertex_count*width>size-b->offset)return 0;
    const unsigned char *bytes=(const unsigned char *)snapshot.contents+b->offset;
    uint32_t restart=d->index_type?UINT32_MAX:UINT16_MAX;uint64_t max=0;int found=0;
    int strips=d->primitive==WMTPrimitiveTypeLineStrip||d->primitive==WMTPrimitiveTypeTriangleStrip;
    for(uint64_t i=0;i<d->vertex_count;i++){
        uint32_t index=0;if(d->index_type)memcpy(&index,bytes+i*4,4);else{uint16_t v;memcpy(&v,bytes+i*2,2);index=v;}
        if(strips&&index==restart)continue;
        int64_t adjusted=(int64_t)index+d->base_vertex;
        /* Wrapping 32-bit vertex/stride arithmetic keeps the original bytes. */
        if(adjusted<0||adjusted>UINT32_MAX)return 0;
        max=MAX(max,(uint64_t)adjusted);found=1;
    }
    if(found)*maximum=max;return found;
}
int ff_draw_cut_compact(struct ff_draw_cut *c){
    if(!c||!c->draws||!c->draw_count||c->draw_count>FF_DRAW_PASS_LIMIT||
       c->snapshot_count>FF_DRAW_RESOURCE_LIMIT)return 0;
    if(c->compacted)return 1;
    uint64_t needed[FF_DRAW_RESOURCE_LIMIT]={0};
    uint32_t (*lengths)[FF_VERTEX_RESOURCE_LIMIT]=calloc(c->draw_count,sizeof(*lengths));if(!lengths)return 0;
    int ok=1;
    for(size_t n=0;ok&&n<c->draw_count;n++){
        const ff_draw_plan *d=&c->draws[n];uint64_t vertex_max=0;
        int vertex_known=compact_vertex_max(c,d,&vertex_max);
        if(d->binding_count>FF_VERTEX_RESOURCE_LIMIT||d->binding_count!=(size_t)__builtin_popcount(d->layout.ia_slot_mask)){ok=0;break;}
        size_t packed=0;
        for(unsigned slot=0;ok&&slot<32;slot++)if(d->layout.ia_slot_mask&(UINT32_C(1)<<slot)){
            const ff_vertex_binding *b=&d->bindings[packed];uint64_t length=b->length;
            if(b->id&&(b->id>c->snapshot_count||!c->reference_input_version[b->id-1])&&
               (d->ia_fetch.known_mask&(UINT32_C(1)<<slot))){
                struct ff_ia_slot_extent extent=d->ia_fetch.slots[slot];uint64_t index=vertex_max;
                int known=vertex_known;
                if(extent.step_function==1){
                    index=(uint64_t)d->base_instance+(extent.step_rate?(d->instance_count-1)/extent.step_rate:0);known=index<=UINT32_MAX;
                }else if(extent.step_function!=0)known=0;
                if(known&&extent.byte_end&&index<=UINT32_MAX&&
                   (!b->stride||index<=(UINT32_MAX-extent.byte_end)/b->stride)){
                    uint64_t end=index*b->stride+extent.byte_end;
                    if(end<=length)length=end;
                }
            }
            lengths[n][packed]=(uint32_t)length;
            ok=compact_use(c,b,length,needed,1);packed++;
        }
        if(ok)ok=compact_use(c,&d->index_binding,d->index_binding.length,needed,0);
        for(unsigned st=0;ok&&st<2;st++){
            if(d->layout.constant_count[st]>FF_CONSTANT_RESOURCE_LIMIT||d->layout.arguments[st].field_count>FF_SHADER_FIELD_LIMIT){ok=0;break;}
            for(size_t i=0;ok&&i<d->layout.constant_count[st];i++)ok=compact_use(c,&d->constants[st][i],d->constants[st][i].length,needed,0);
            for(size_t i=0;ok&&i<d->layout.arguments[st].field_count;i++)if(d->arguments[st][i].kind==FF_FIELD_BUFFER)
                ok=compact_use(c,&d->arguments[st][i].buffer,d->arguments[st][i].buffer.length,needed,0);
        }
    }
    size_t total=0;
    for(size_t i=0;ok&&i<c->snapshot_count;i++){
        uint64_t size=c->source_length[i];
        if(!size||size>SIZE_MAX-total){ok=0;break;}
        if(c->reference_input_version[i]){if(c->snapshots[i]){ok=0;break;}}
        else if(size>c->snapshots[i].length||!c->snapshots[i].contents){ok=0;break;}
        /* References retain their complete original logical extent. */
        uint64_t length=c->reference_input_version[i]?size:(needed[i]?:size);
        if(length>size){ok=0;break;}
        /* Alignment padding must stay inside the captured preimage. */
        length+=MIN((UINT64_C(4)-(length&3))&3,size-length);
        needed[i]=length;total+=(size_t)length;
    }
    if(ok){
        for(size_t n=0;n<c->draw_count;n++)for(size_t i=0;i<c->draws[n].binding_count;i++)c->draws[n].bindings[i].length=lengths[n][i];
        memcpy(c->bindings,c->draws[0].bindings,sizeof(c->bindings));
        for(size_t i=0;i<c->snapshot_count;i++)c->serialized_length[i]=needed[i];
        c->serialized_bytes=total;c->compacted=1;
    }
    free(lengths);return ok;
}
int ff_draw_cut_compact_for_wire(struct ff_draw_cut *cut,int gpu_completed){
    return gpu_completed&&ff_draw_cut_compact(cut)&&(cut->direct_pass||cut->serialized_bytes<=FF_VERTEX_BYTES_LIMIT);
}
/* Metal declares gpuAddress and length readonly. Cache them for the lifetime
 * of this retained command-stream buffer; logical DXMT identity remains per
 * candidate and is still checked separately for every binding. */
struct candidate {id<MTLBuffer> buffer;uint64_t address,physical_length;uint64_t incarnation,generation,suballocation,length;uint32_t flags,tag;};
#define FF_DRAW_SNAPSHOT_BUCKETS 2048u
/* A single draw can add at most one index, 32 IA, 28 constants and 256
 * shader buffers. Aliased slots survive only until that draw commits. */
#define FF_DRAW_VIRTUAL_SNAPSHOTS (FF_DRAW_RESOURCE_LIMIT+1+FF_VERTEX_RESOURCE_LIMIT+2*FF_CONSTANT_RESOURCE_LIMIT+2*FF_SHADER_FIELD_LIMIT)
_Static_assert(FF_DRAW_VIRTUAL_SNAPSHOTS<UINT16_MAX && (FF_DRAW_SNAPSHOT_BUCKETS&(FF_DRAW_SNAPSHOT_BUCKETS-1))==0,
    "snapshot index must hold each bounded resource");
struct planning {
    struct ff_draw_cut *cut;
    struct candidate candidates[FF_DRAW_CANDIDATE_LIMIT];size_t candidate_count;
    id<MTLBuffer> sources[FF_DRAW_VIRTUAL_SNAPSHOTS];NSUInteger offsets[FF_DRAW_VIRTUAL_SNAPSHOTS],lengths[FF_DRAW_VIRTUAL_SNAPSHOTS];
    NSUInteger logical_offsets[FF_DRAW_VIRTUAL_SNAPSHOTS],logical_lengths[FF_DRAW_VIRTUAL_SNAPSHOTS];
    uint64_t incarnations[FF_DRAW_VIRTUAL_SNAPSHOTS],generations[FF_DRAW_VIRTUAL_SNAPSHOTS];
    uint16_t snapshot_heads[FF_DRAW_SNAPSHOT_BUCKETS],snapshot_next[FF_DRAW_VIRTUAL_SNAPSHOTS],alias[FF_DRAW_VIRTUAL_SNAPSHOTS];
    size_t virtual_count,active_snapshots;int merged;
    ff_draw_range_witness witness;void *witness_context;
    id<MTLTexture> textures[FF_TEXTURE_CANDIDATE_LIMIT],texture_sources[FF_TEXTURE_RESOURCE_LIMIT];size_t texture_count;
    uint64_t sampler_handles[FF_SAMPLER_RESOURCE_LIMIT];
    size_t buffer_bytes,texture_bytes,buffer_limit;id<MTLDevice> device;uint32_t failure_reason;int diagnostics;
};
/* Per-cut index only: the linked entries refer to stable snapshot IDs. Hash
 * collisions are checked by full object/offset identity below. */
static size_t snapshot_bucket(id<MTLBuffer> buffer,NSUInteger offset){
    uint64_t v=((uint64_t)(uintptr_t)buffer>>4)^(uint64_t)offset;
    v^=v>>30;v*=UINT64_C(0xbf58476d1ce4e5b9);v^=v>>27;v*=UINT64_C(0x94d049bb133111eb);v^=v>>31;
    return (size_t)(v&(FF_DRAW_SNAPSHOT_BUCKETS-1));
}
static void snapshot_index_add(struct planning *p,size_t i){
    size_t bucket=snapshot_bucket(p->sources[i],p->logical_offsets[i]);
    p->snapshot_next[i]=p->snapshot_heads[bucket];p->snapshot_heads[bucket]=(uint16_t)(i+1);
}
static void snapshot_index_rebuild(struct planning *p){
    memset(p->snapshot_heads,0,sizeof(p->snapshot_heads));
    for(size_t i=0;i<p->virtual_count;i++)if(p->alias[i]==i)snapshot_index_add(p,i);
}
static int buffer_binding(struct planning *p,uint64_t address,uint32_t stride,uint32_t length,ff_vertex_binding *out,const char *kind,uint32_t pre_copy_bound){
    uint32_t declared=length;
    if(!address){if(stride||length)return 0;*out=(ff_vertex_binding){0};return 1;}
    struct candidate *match=NULL;uint64_t relative=0;
    for(size_t i=0;i<p->candidate_count;i++){
        struct candidate *v=&p->candidates[i];uint64_t base=v->address;
        uint64_t start=0,extent=v->physical_length;
        if(v->tag==0x46464231&&v->incarnation&&v->generation&&v->length){
            if(v->suballocation>extent||v->length>extent-v->suballocation)return 0;
            start=v->suballocation;extent=v->length;
        }
        if(base&&address>=base&&address-base>=start&&address-base-start<extent&&length<=extent-(address-base-start)){
            if(match)return (p->failure_reason=1,rejected(0));match=v;relative=address-base;}
    }
    if(!match||match->buffer.device!=p->device)return (p->failure_reason=1,rejected(0));
    NSUInteger offset=0,logical=match->physical_length;MTLStorageMode mode=match->buffer.storageMode;
    if(match->tag==0x46464231&&match->incarnation&&match->generation&&match->length){
        if(match->suballocation>logical||match->length>logical-match->suballocation)return 0;
        offset=match->suballocation;logical=match->length;
        /* Managed updates and dynamic renames use DXMT's retained allocation
         * and D3D11 NO_OVERWRITE read lifetime. Only the selected logical slice
         * is captured; unrelated suballocations are never read by this copy. */
        if(mode!=MTLStorageModePrivate&&mode!=MTLStorageModeManaged&&
           !(mode==MTLStorageModeShared&&(match->flags&(1u<<5))))return (p->failure_reason=2,rejected(1));
    }else if(mode!=MTLStorageModePrivate)return (p->failure_reason=2,rejected(1));
    if(relative<offset||relative-offset>logical||length>logical-(relative-offset))return (p->failure_reason=3,rejected(2));
    uint64_t remaining=logical-(relative-offset);
    if(!length){if(remaining>UINT32_MAX)return 0;length=(uint32_t)remaining;}
    /* The bound is computed only from the exact pipeline's proven IA layout.
     * If it exceeds the original accessible range, preserve that range. */
    if(pre_copy_bound&&pre_copy_bound<=length)length=pre_copy_bound;
    NSUInteger start=relative&~(NSUInteger)3,end=relative+length;
    if(!logical||(offset&3)||end<relative||end>match->physical_length)return 0;
    /* Keep aligned origins without reading past this logical allocation. */
    end+=MIN(((NSUInteger)4-(end&3))&3,offset+logical-end);
    /* Check all identities before changing any range. IDs may alias only
     * within this draw's transaction; accepted plans are remapped on commit.
     * The ordinary no-overlap/single-window case needs just this first scan. */
    size_t count=p->virtual_count,bucket=snapshot_bucket(match->buffer,offset);
    NSUInteger requested_start=start,requested_end=end,prior=0,old_start=0,old_end=0;
    uint16_t selected[FF_DRAW_VIRTUAL_SNAPSHOTS];
    size_t selected_count=0,representative=count;int skipped=0;
    for(uint16_t entry=p->snapshot_heads[bucket];entry;entry=p->snapshot_next[entry-1]){
        size_t j=entry-1;if(j>=count||p->alias[j]!=j||p->sources[j]!=match->buffer||p->logical_offsets[j]!=offset)continue;
        if(p->logical_lengths[j]!=logical||p->incarnations[j]!=match->incarnation||p->generations[j]!=match->generation)
            return (p->failure_reason=FF_DRAW_DETAIL_BUFFER_VERSION,0);
        NSUInteger lo=p->offsets[j],hi=lo+p->lengths[j];if(start>hi||lo>end){skipped=1;continue;}
        selected[selected_count++]=(uint16_t)j;prior+=p->lengths[j];
        if(j<representative){representative=j;old_start=lo;old_end=hi;}
        start=MIN(start,lo);end=MAX(end,hi);
    }
    /* A skipped interval can become connected by a later expansion. */
    int changed=selected_count&&skipped;
    uint64_t seen[(FF_DRAW_VIRTUAL_SNAPSHOTS+63)/64];
    if(changed){memset(seen,0,sizeof(seen));for(size_t k=0;k<selected_count;k++)seen[selected[k]/64]|=UINT64_C(1)<<(selected[k]%64);}
    while(changed){changed=0;
        for(uint16_t entry=p->snapshot_heads[bucket];entry;entry=p->snapshot_next[entry-1]){
            size_t j=entry-1;if(j>=count||p->alias[j]!=j||p->sources[j]!=match->buffer||p->logical_offsets[j]!=offset)continue;
            if(seen[j/64]&(UINT64_C(1)<<(j%64)))continue;
            NSUInteger lo=p->offsets[j],hi=lo+p->lengths[j];if(start>hi||lo>end)continue;
            selected[selected_count++]=(uint16_t)j;seen[j/64]|=UINT64_C(1)<<(j%64);prior+=p->lengths[j];
            if(j<representative){representative=j;old_start=lo;old_end=hi;}
            start=MIN(start,lo);end=MAX(end,hi);changed=1;
        }
    }
    /* If the producer cannot witness the whole union, retain the original
     * planner's least-expansion overlapping window and other snapshots. */
    int union_witness=0;
    if(selected_count>1&&p->witness){
        struct ff_draw_source_interval parts[FF_DRAW_VIRTUAL_SNAPSHOTS+1];
        for(size_t k=0;k<selected_count;k++){size_t j=selected[k];parts[k]=(struct ff_draw_source_interval){p->offsets[j],p->lengths[j]};}
        parts[selected_count]=(struct ff_draw_source_interval){requested_start,requested_end-requested_start};
        union_witness=p->witness(match->incarnation,match->generation,start,end-start,parts,selected_count+1,p->witness_context);
    }
    size_t witness_windows=selected_count,safe_reclaim=0;
    if(p->diagnostics&&selected_count>1&&union_witness){
        NSUInteger best=NSUIntegerMax;
        for(size_t k=0;k<selected_count;k++){size_t j=selected[k];NSUInteger lo=p->offsets[j],hi=lo+p->lengths[j];
            if(requested_start>hi||lo>requested_end)continue;
            NSUInteger expansion=MAX(requested_end,hi)-MIN(requested_start,lo)-p->lengths[j];
            best=MIN(best,expansion);
        }
        if(best!=NSUIntegerMax&&prior+best>=end-start)safe_reclaim=prior+best-(end-start);
    }
    if(selected_count>1&&!union_witness){
        size_t chosen=count;NSUInteger best=NSUIntegerMax;
        for(size_t k=0;k<selected_count;k++){size_t j=selected[k];NSUInteger lo=MIN(requested_start,p->offsets[j]);
            NSUInteger hi=MAX(requested_end,p->offsets[j]+p->lengths[j]);
            if(requested_start>p->offsets[j]+p->lengths[j]||p->offsets[j]>requested_end)continue;
            NSUInteger expansion=hi-lo-p->lengths[j];
            if(expansion<best||(expansion==best&&j<chosen)){chosen=j;best=expansion;}
        }
        selected_count=0;start=requested_start;end=requested_end;prior=old_start=old_end=0;representative=count;
        if(chosen<count){selected[selected_count++]=(uint16_t)chosen;representative=chosen;prior=p->lengths[chosen];
            old_start=p->offsets[chosen];old_end=old_start+prior;start=MIN(start,old_start);end=MAX(end,old_end);}
    }
    NSUInteger copy=end-start;size_t base=p->buffer_bytes-prior,available=p->buffer_limit-base;
    size_t increment=copy>prior?copy-prior:0;
    int new_snapshot=!selected_count;
    if(copy>available||(new_snapshot&&(p->active_snapshots==FF_DRAW_RESOURCE_LIMIT||count==FF_DRAW_VIRTUAL_SNAPSHOTS))){
        NSUInteger gap=0;if(old_end&&requested_start>old_end)gap=requested_start-old_end;
        else if(old_end&&old_start>requested_end)gap=old_start-requested_end;
        if(p->diagnostics)cut_failure("stage=buffer-range reason=%s kind=%s capture=%llu snapshot=%zu existing=%d declared=%u inferred=%d resolved=%u requested=%llu:%llu old=%llu:%llu merged=%llu:%llu gap=%llu increment=%zu used=%zu limit=%u remaining=%zu union_windows=%zu union_witness=%d safe_reclaim=%zu\n",
            copy>available?"bytes":"snapshots",kind,(unsigned long long)p->cut->capture_id,representative,!new_snapshot,declared,declared==0,length,
            (unsigned long long)(requested_start-offset),(unsigned long long)(requested_end-offset),
            (unsigned long long)(old_end?old_start-offset:0),(unsigned long long)(old_end?old_end-offset:0),
            (unsigned long long)(start-offset),(unsigned long long)(end-offset),
            (unsigned long long)gap,increment,p->buffer_bytes,(unsigned)p->buffer_limit,(size_t)(p->buffer_limit-p->buffer_bytes),witness_windows,union_witness,safe_reclaim);
        p->failure_reason=copy>available?FF_DRAW_DETAIL_BUFFER_BYTES:FF_DRAW_DETAIL_BUFFER_SNAPSHOTS;return 0;
    }
    size_t i=representative;
    if(new_snapshot){
        i=count;p->sources[i]=match->buffer;p->logical_offsets[i]=offset;p->logical_lengths[i]=logical;
        p->incarnations[i]=match->incarnation;p->generations[i]=match->generation;p->alias[i]=(uint16_t)i;
        ++p->virtual_count;++p->active_snapshots;snapshot_index_add(p,i);
    }else for(size_t k=0;k<selected_count;k++)if(selected[k]!=i){
        p->alias[selected[k]]=(uint16_t)i;--p->active_snapshots;p->merged=1;
    }
    p->offsets[i]=start;p->lengths[i]=copy;p->buffer_bytes=base+copy;

    /* Keep physical offsets while planning. Final rebasing happens once, after
     * rejected draws have rolled back every expanded snapshot range. */
    *out=(ff_vertex_binding){i+1,1,relative,stride,length};return 1;
}
static int texture_profile_rejected(struct planning *p,id<MTLTexture> texture,uint32_t reason){
    static _Atomic uint64_t failures;uint64_t count=atomic_fetch_add(&failures,1)+1;
    MTLTextureSwizzleChannels swizzle=texture.swizzle;
    if(!(count&(count-1)))fprintf(stderr,"[full-frame-texture-profile] count=%llu detail=%u snapshots=%zu/%u bytes=%zu/%u swizzle=%u,%u,%u,%u format=%lu type=%lu size=%lux%lu mips=%lu slices=%lu samples=%lu storage=%lu\n",
        (unsigned long long)count,reason,p->cut->texture_count,FF_TEXTURE_RESOURCE_LIMIT,p->texture_bytes,FF_TEXTURE_BYTES_LIMIT,
        swizzle.red,swizzle.green,swizzle.blue,swizzle.alpha,
        (unsigned long)texture.pixelFormat,(unsigned long)texture.textureType,
        (unsigned long)texture.width,(unsigned long)texture.height,(unsigned long)texture.mipmapLevelCount,
        (unsigned long)texture.arrayLength,(unsigned long)texture.sampleCount,(unsigned long)texture.storageMode);
    p->failure_reason=reason;return rejected(3);
}
static int texture_binding(struct planning *p,uint64_t handle,uint64_t *out){
    if(!handle){*out=0;return 1;}id<MTLTexture> texture=nil;
    for(size_t i=0;i<p->texture_count;i++)if(p->textures[i].gpuResourceID._impl==handle){if(texture&&texture!=p->textures[i])return 0;texture=p->textures[i];}
    if(!texture||texture.device!=p->device)return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_PROFILE);
    for(size_t i=0;i<p->cut->texture_count;i++)if(p->texture_sources[i]==texture){*out=i+1;return 1;}
    MTLTextureSwizzleChannels swizzle=texture.swizzle;
    if(swizzle.red>MTLTextureSwizzleAlpha||swizzle.green>MTLTextureSwizzleAlpha||swizzle.blue>MTLTextureSwizzleAlpha||swizzle.alpha>MTLTextureSwizzleAlpha)
        return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_SWIZZLE);
    unsigned bpp=ff_texture_pixel_size(texture.pixelFormat);size_t index=p->cut->texture_count;
    NSUInteger slices=texture.textureType==MTLTextureTypeCube?6:texture.arrayLength;
    if(index==FF_TEXTURE_RESOURCE_LIMIT)return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_SNAPSHOTS);
    if(!bpp||texture.sampleCount!=1||texture.storageMode==MTLStorageModeMemoryless||
       (texture.textureType!=MTLTextureType2D&&texture.textureType!=MTLTextureType2DArray&&texture.textureType!=MTLTextureTypeCube)||!texture.width||!texture.height||
       (texture.textureType==MTLTextureTypeCube&&(texture.arrayLength!=1||texture.width!=texture.height))||
       texture.width>4096||texture.height>4096||!texture.mipmapLevelCount||texture.mipmapLevelCount>13||
       !texture.arrayLength||texture.arrayLength>8||texture.mipmapLevelCount*slices>FF_TEXTURE_PLANE_LIMIT)return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_PROFILE);
    ff_texture_snapshot *s=&p->cut->textures[index];
    *s=(ff_texture_snapshot){.id=index+1,.format=texture.pixelFormat,.texture_type=texture.textureType,
        .width=(uint32_t)texture.width,.height=(uint32_t)texture.height,.mip_count=(uint32_t)texture.mipmapLevelCount,
        .array_length=(uint32_t)texture.arrayLength,.has_swizzle=1,
        .swizzle={swizzle.red,swizzle.green,swizzle.blue,swizzle.alpha}};
    for(uint32_t slice=0;slice<slices;slice++)for(uint32_t mip=0;mip<s->mip_count;mip++){
        size_t w=MAX((size_t)1,s->width>>mip),h=MAX((size_t)1,s->height>>mip),row=(w*bpp+255)&~(size_t)255,length=row*h;
        if(length>FF_TEXTURE_BYTES_LIMIT-p->texture_bytes||length>FF_TEXTURE_BYTES_LIMIT-s->length)
            return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_BYTES);
        s->planes[s->plane_count++]=(ff_texture_plane){mip,slice,s->length,row,length};s->length+=length;
    }
    if(s->length>FF_TEXTURE_BYTES_LIMIT-p->texture_bytes)return texture_profile_rejected(p,texture,FF_DRAW_DETAIL_TEXTURE_BYTES);
    p->texture_sources[index]=texture;
    p->cut->source_texture_ids[index]=texture.gpuResourceID._impl;
    p->texture_bytes+=s->length;++p->cut->texture_count;*out=index+1;return 1;
}
static int read_table(id<MTLBuffer> b,NSUInteger offset,void *dest,size_t length){
    if(!length)return 1;
    if(!b||b.storageMode!=MTLStorageModeShared||!b.contents||offset>b.length||length>b.length-offset)return rejected(5);
    memcpy(dest,(const char *)b.contents+offset,length);return 1;
}
static int plan_draw(struct planning *p,const struct wmtcmd_base *draw,const ff_draw_layout *layout,const struct ff_ia_fetch_layout *fetch,
    id<MTLBuffer> tables[2][31],NSUInteger offsets[2][31]){
    struct ff_draw_cut *c=p->cut;
    if(!layout)return 0;
    for(unsigned st=0;st<2;st++)if(layout->constant_count[st]>FF_CONSTANT_RESOURCE_LIMIT||
        layout->arguments[st].byte_length>FF_SHADER_TABLE_BYTES_LIMIT||layout->arguments[st].field_count>FF_SHADER_FIELD_LIMIT||
        layout->arguments[st].byte_length!=layout->arguments[st].field_count*8)return 0;
    c->draw_command=draw;c->layout=*layout;c->ia_slot_mask=layout->ia_slot_mask;
    c->indexed=c->index_type=c->base_instance=c->instance_count=0;c->base_vertex=0;
    c->vertex_start=c->vertex_count=c->index_offset=0;
    memset(c->bindings,0,sizeof(c->bindings));memset(c->constants,0,sizeof(c->constants));
    memset(c->arguments,0,sizeof(c->arguments));memset(&c->index_binding,0,sizeof(c->index_binding));
    if(c->draw_command->type==WMTRenderCommandDraw){const struct wmtcmd_render_draw *d=(const void *)c->draw_command;
        c->primitive=d->primitive_type;c->vertex_start=d->vertex_start;c->vertex_count=d->vertex_count;c->instance_count=d->instance_count;c->base_instance=d->base_instance;
    }else{const struct wmtcmd_render_draw_indexed *d=(const void *)c->draw_command;
        if(d->index_type>1||d->index_count>UINT32_MAX/(d->index_type?4:2))return 0;
        c->indexed=1;c->index_type=d->index_type;c->base_vertex=d->base_vertex;c->index_offset=d->index_buffer_offset;
        c->primitive=d->primitive_type;c->vertex_count=d->index_count;c->instance_count=d->instance_count;c->base_instance=d->base_instance;
        id<MTLBuffer> index=(id<MTLBuffer>)d->index_buffer;uint64_t length=d->index_count*(d->index_type?4:2);
        if(!index||(d->index_buffer_offset&((d->index_type?4:2)-1)))return 0;
        size_t i;for(i=0;i<p->candidate_count;i++)if(p->candidates[i].buffer==index)break;
        if(i==p->candidate_count){if(i==FF_DRAW_CANDIDATE_LIMIT)return (p->failure_reason=FF_DRAW_DETAIL_BUFFER_CANDIDATES,0);
            p->candidates[p->candidate_count++]=(struct candidate){.buffer=index,.address=index.gpuAddress,.physical_length=index.length};}
        const struct candidate *index_candidate=&p->candidates[i];
        if(d->index_buffer_offset>index_candidate->physical_length||length>index_candidate->physical_length-d->index_buffer_offset)return 0;
        if(!buffer_binding(p,index_candidate->address+d->index_buffer_offset,0,(uint32_t)length,&c->index_binding,"index",0))return 0;
    }
    if(!c->vertex_count||!c->instance_count||c->instance_count>1000000||c->vertex_count>10000000/c->instance_count||c->vertex_start>UINT32_MAX||c->primitive>WMTPrimitiveTypeTriangleStrip)return 0;
    c->binding_count=__builtin_popcount(c->ia_slot_mask);struct vertex_entry entries[FF_VERTEX_RESOURCE_LIMIT];
    if(!read_table(tables[0][16],offsets[0][16],entries,c->binding_count*sizeof(entries[0]))){p->failure_reason=6;return 0;}
    struct ff_ia_pre_copy_draw pre_copy={.vertex_start=c->vertex_start,.vertex_count=c->vertex_count,
        .instance_count=c->instance_count,.base_instance=c->base_instance,.indexed=c->indexed,
        .index_type=c->index_type,.base_vertex=c->base_vertex};
    size_t packed=0;
    for(unsigned slot=0;slot<32;slot++)if(c->ia_slot_mask&(UINT32_C(1)<<slot)){
        uint32_t bound=0;(void)ff_ia_pre_copy_bound(fetch,slot,&pre_copy,entries[packed].stride,UINT32_MAX,&bound);
        if(!buffer_binding(p,entries[packed].address,entries[packed].stride,entries[packed].length,&c->bindings[packed],"ia",bound))return 0;
        packed++;
    }
    for(unsigned st=0;st<2;st++){
        uint64_t values[FF_CONSTANT_RESOURCE_LIMIT];
        if(!read_table(tables[st][29],offsets[st][29],values,layout->constant_count[st]*8)){p->failure_reason=6;return 0;}
        for(size_t i=0;i<layout->constant_count[st];i++)if(!buffer_binding(p,values[i],0,0,&c->constants[st][i],"constant",0))return 0;
        uint64_t args[FF_SHADER_TABLE_BYTES_LIMIT/8];ff_shader_table_layout a=layout->arguments[st];
        if(!read_table(tables[st][30],offsets[st][30],args,a.byte_length)){p->failure_reason=6;return 0;}
        for(size_t i=0;i<a.field_count;i++){
            ff_shader_field f=a.fields[i];if((f.offset&7)||f.offset>=a.byte_length||f.kind<FF_FIELD_BUFFER||f.kind>FF_FIELD_VALUE)return 0;
            for(size_t j=0;j<i;j++)if(a.fields[j].offset==f.offset)return 0;
            ff_argument_binding *v=&c->arguments[st][i];v->offset=f.offset;v->kind=f.kind;v->value=args[f.offset/8];
            if(f.kind==FF_FIELD_BUFFER){if(!buffer_binding(p,v->value,0,0,&v->buffer,"argument",0))return 0;v->value=0;}
            else if(f.kind==FF_FIELD_TEXTURE){if(!texture_binding(p,v->value,&v->value))return 0;}
            else if(f.kind==FF_FIELD_SAMPLER&&v->value){
                size_t j;for(j=0;j<c->sampler_count;j++)if(p->sampler_handles[j]==v->value)break;
                if(j==c->sampler_count){if(j==FF_SAMPLER_RESOURCE_LIMIT||!sampler_lookup(v->value,&c->samplers[j])){p->failure_reason=5;return 0;}
                    p->sampler_handles[j]=v->value;c->samplers[j].id=j+1;++c->sampler_count;}v->value=j+1;
            }
        }
    }
    return 1;
}
static void store_plan(struct ff_draw_cut *c,ff_draw_plan *d){
    *d=(ff_draw_plan){.command=c->draw_command,.layout=c->layout,.primitive=c->primitive,.instance_count=c->instance_count,
        .base_instance=c->base_instance,.indexed=c->indexed,.index_type=c->index_type,.base_vertex=c->base_vertex,
        .vertex_start=c->vertex_start,.vertex_count=c->vertex_count,.index_offset=c->index_offset,
        .binding_count=c->binding_count,.index_binding=c->index_binding};
    memcpy(d->bindings,c->bindings,sizeof(d->bindings));memcpy(d->constants,c->constants,sizeof(d->constants));
    memcpy(d->arguments,c->arguments,sizeof(d->arguments));
}
static void restore_plan(struct ff_draw_cut *c,const ff_draw_plan *d){
    c->draw_command=d->command;c->layout=d->layout;c->ia_slot_mask=d->layout.ia_slot_mask;
    c->primitive=d->primitive;c->instance_count=d->instance_count;c->base_instance=d->base_instance;c->indexed=d->indexed;
    c->index_type=d->index_type;c->base_vertex=d->base_vertex;c->vertex_start=d->vertex_start;c->vertex_count=d->vertex_count;
    c->index_offset=d->index_offset;c->binding_count=d->binding_count;c->index_binding=d->index_binding;
    memcpy(c->bindings,d->bindings,sizeof(c->bindings));memcpy(c->constants,d->constants,sizeof(c->constants));
    memcpy(c->arguments,d->arguments,sizeof(c->arguments));
}
static void remap_binding(ff_vertex_binding *binding,const uint16_t *map){
    if(binding->id)binding->id=map[binding->id-1]+1;
}
static void remap_plan(ff_draw_plan *d,const uint16_t *map){
    remap_binding(&d->index_binding,map);
    for(size_t i=0;i<d->binding_count;i++)remap_binding(&d->bindings[i],map);
    for(unsigned st=0;st<2;st++){
        for(size_t i=0;i<d->layout.constant_count[st];i++)remap_binding(&d->constants[st][i],map);
        for(size_t i=0;i<d->layout.arguments[st].field_count;i++)
            if(d->arguments[st][i].kind==FF_FIELD_BUFFER)remap_binding(&d->arguments[st][i].buffer,map);
    }
}
/* Only after accepting a draw: preserve all old references until rollback is
 * no longer possible, then pack representatives in their original order. */
static void compact_snapshots(struct planning *p){
    uint16_t map[FF_DRAW_VIRTUAL_SNAPSHOTS];size_t next=0;
    for(size_t i=0;i<p->virtual_count;i++)if(p->alias[i]==i)map[i]=(uint16_t)next++;
    for(size_t i=0;i<p->virtual_count;i++)if(p->alias[i]!=i){
        size_t root=i;while(p->alias[root]!=root)root=p->alias[root];map[i]=map[root];
    }
    for(size_t i=0;i<p->cut->draw_count;i++)remap_plan(&p->cut->draws[i],map);
    for(size_t i=0;i<p->virtual_count;i++)if(p->alias[i]==i){size_t j=map[i];
        p->sources[j]=p->sources[i];p->offsets[j]=p->offsets[i];p->lengths[j]=p->lengths[i];
        p->logical_offsets[j]=p->logical_offsets[i];p->logical_lengths[j]=p->logical_lengths[i];
        p->incarnations[j]=p->incarnations[i];p->generations[j]=p->generations[i];
    }
    p->virtual_count=p->active_snapshots=next;for(size_t i=0;i<next;i++)p->alias[i]=(uint16_t)i;
    p->cut->snapshot_count=next;p->merged=0;snapshot_index_rebuild(p);
}
static void rebase_binding(const struct planning *p,ff_vertex_binding *binding){
    if(binding->id)binding->offset-=p->offsets[binding->id-1];
}
static void rebase_plan(const struct planning *p,ff_draw_plan *d){
    rebase_binding(p,&d->index_binding);
    for(size_t i=0;i<d->binding_count;i++)rebase_binding(p,&d->bindings[i]);
    for(unsigned st=0;st<2;st++){
        for(size_t i=0;i<d->layout.constant_count[st];i++)rebase_binding(p,&d->constants[st][i]);
        for(size_t i=0;i<d->layout.arguments[st].field_count;i++)
            if(d->arguments[st][i].kind==FF_FIELD_BUFFER)rebase_binding(p,&d->arguments[st][i].buffer);
    }
}
static int schedule_cut(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled,int diagnostics,size_t buffer_limit,ff_draw_range_witness witness,void *witness_context){
    if(scheduled)*scheduled=NULL;
    if(!command||!head||!initial||!resolver||!completion||!scheduled||!draw_limit||draw_limit>FF_DRAW_PASS_LIMIT||
        fence_count>FF_DRAW_FENCE_LIMIT||(fence_count&&!fences)){
        if(diagnostics)cut_failure("stage=arguments draw_limit=%zu fences=%zu\n",draw_limit,fence_count);return 0;}
    for(size_t i=0;i<fence_count;i++)if(!fences[i]){if(diagnostics)cut_failure("stage=null-fence index=%zu\n",i);return 0;}
    struct ff_draw_cut *c=calloc(1,sizeof(*c));if(!c){if(diagnostics)cut_failure("stage=cut-allocation\n");return 0;}
    c->draws=calloc(draw_limit,sizeof(*c->draws));if(!c->draws){if(diagnostics)cut_failure("stage=draw-allocation\n");free(c);return 0;}
    struct planning *p=calloc(1,sizeof(*p));if(!p){if(diagnostics)cut_failure("stage=planning-allocation\n");ff_draw_cut_destroy(c);return 0;}
    const char *failure_stage="capture-id";size_t failure_index=0;unsigned command_position=0;
    p->cut=c;p->buffer_limit=buffer_limit;p->device=command.device;p->diagnostics=diagnostics;p->witness=witness;p->witness_context=witness_context;c->capture_id=atomic_fetch_add(&next_capture,1);if(!c->capture_id)goto rejected;
    id<MTLBuffer> tables[2][31]={{nil}};NSUInteger offsets[2][31]={{0}};
    tables[0][16]=tables[0][29]=tables[0][30]=tables[1][29]=tables[1][30]=initial;
    const struct wmtcmd_base *next=head;id<MTLRenderPipelineState> pipeline=nil;uint64_t invocations=0;
    unsigned seen=0;
    for(;next&&seen<65536;seen++,next=next->next.ptr){
        command_position=seen;
        enum WMTRenderCommandType type=(enum WMTRenderCommandType)next->type;c->stop_reason=FF_DRAW_STOP_COMMAND;
        switch(type){
        case WMTRenderCommandSetPSO:pipeline=(id<MTLRenderPipelineState>)((const struct wmtcmd_render_setpso *)next)->pso;break;
        case WMTRenderCommandNop:case WMTRenderCommandSetRasterizerState:
        case WMTRenderCommandSetViewport:
        case WMTRenderCommandSetScissorRect:case WMTRenderCommandSetDSSO:case WMTRenderCommandSetBlendFactorAndStencilRef:
        case WMTRenderCommandSetFragmentTexture:break;
        case WMTRenderCommandSetViewports:{
            const struct wmtcmd_render_setviewports *v=(const void *)next;
            if(v->viewport_count!=1||!v->viewports.ptr)goto stopped;break;}
        case WMTRenderCommandSetScissorRects:{
            const struct wmtcmd_render_setscissorrects *v=(const void *)next;
            if(v->rect_count!=1||!v->scissor_rects.ptr)goto stopped;break;}
        case WMTRenderCommandSetFragmentBytes:{
            const struct wmtcmd_render_setbytes *v=(const void *)next;
            if(v->index==29||v->index==30){tables[1][v->index]=nil;offsets[1][v->index]=0;}break;}
        case WMTRenderCommandSetVisibilityMode:if(((const struct wmtcmd_render_setvisibilitymode *)next)->mode)goto stopped;break;
        case WMTRenderCommandUseResource:{
            const struct wmtcmd_render_useresource *v=(const void *)next;id<MTLResource> resource=(id<MTLResource>)v->resource;
            c->resource_detail=0;
            if(!resource){c->stop_reason=FF_DRAW_STOP_RESOURCE;goto stopped;}
            if(v->usage&WMTResourceUsageWrite){c->stop_reason=FF_DRAW_STOP_WRITE;goto stopped;}
            c->stop_reason=FF_DRAW_STOP_RESOURCE;
            if([resource conformsToProtocol:@protocol(MTLBuffer)]){
                struct candidate candidate={.buffer=(id)resource};
#ifdef BEDROCK_NATIVE_DRAW_CUT
                if(v->bedrock_source_tag==0x46464231){
                    candidate.incarnation=v->bedrock_incarnation;candidate.generation=v->bedrock_generation;candidate.suballocation=v->bedrock_suballocation;
                    candidate.length=v->bedrock_length;candidate.flags=v->bedrock_flags;candidate.tag=v->bedrock_source_tag;}
#endif
                size_t i;int cached_object=0;for(i=0;i<p->candidate_count;i++)if(p->candidates[i].buffer==(id)resource){
                    cached_object=1;struct candidate *old=&p->candidates[i];
                    candidate.address=old->address;candidate.physical_length=old->physical_length;
                    if(!candidate.tag)break;
                    if(!old->tag){*old=candidate;break;}
                    if(old->incarnation==candidate.incarnation&&old->generation==candidate.generation&&old->suballocation==candidate.suballocation&&
                        old->length==candidate.length&&old->flags==candidate.flags)break;
                }
                if(i==p->candidate_count){if(i==FF_DRAW_CANDIDATE_LIMIT){c->resource_detail=FF_DRAW_DETAIL_BUFFER_CANDIDATES;goto stopped;}
                    if(!cached_object){candidate.address=candidate.buffer.gpuAddress;candidate.physical_length=candidate.buffer.length;}
                    p->candidates[p->candidate_count++]=candidate;}
            }else if([resource conformsToProtocol:@protocol(MTLTexture)]){
                size_t i;for(i=0;i<p->texture_count;i++)if(p->textures[i]==(id)resource)break;
                if(i==p->texture_count){if(i==FF_TEXTURE_CANDIDATE_LIMIT){c->resource_detail=FF_DRAW_DETAIL_TEXTURE_CANDIDATES;goto stopped;}p->textures[p->texture_count++]=(id)resource;}
            }else goto stopped;break;}
        case WMTRenderCommandSetVertexBuffer:case WMTRenderCommandSetFragmentBuffer:{
            const struct wmtcmd_render_setbuffer *v=(const void *)next;unsigned st=type==WMTRenderCommandSetFragmentBuffer;
            if(v->index>=31)goto stopped;tables[st][v->index]=(id<MTLBuffer>)v->buffer;offsets[st][v->index]=v->offset;break;}
        case WMTRenderCommandSetVertexBufferOffset:case WMTRenderCommandSetFragmentBufferOffset:{
            const struct wmtcmd_render_setbufferoffset *v=(const void *)next;unsigned st=type==WMTRenderCommandSetFragmentBufferOffset;
            if(v->index>=31)goto stopped;offsets[st][v->index]=v->offset;break;}
        case WMTRenderCommandDraw:case WMTRenderCommandDrawIndexed:{
            ff_draw_layout layout={0};
            if(!resolver(pipeline,next,&layout,resolver_context)){c->stop_reason=FF_DRAW_STOP_SHADER;goto stopped;}
            size_t buffers=c->snapshot_count,textures=c->texture_count,samplers=c->sampler_count;
            size_t buffer_bytes=p->buffer_bytes,texture_bytes=p->texture_bytes;
            NSUInteger prior_offsets[FF_DRAW_RESOURCE_LIMIT],prior_lengths[FF_DRAW_RESOURCE_LIMIT];
            memcpy(prior_offsets,p->offsets,buffers*sizeof(*prior_offsets));memcpy(prior_lengths,p->lengths,buffers*sizeof(*prior_lengths));
            struct ff_ia_fetch_layout fetch={0};if(!ff_ia_pipeline_fetch(pipeline,&fetch))fetch=(struct ff_ia_fetch_layout){0};
            p->failure_reason=0;int planned=plan_draw(p,next,&layout,&fetch,tables,offsets);
            if(!planned||c->vertex_count*c->instance_count>10000000-invocations){
                c->stop_reason=planned?FF_DRAW_STOP_INVOCATIONS:FF_DRAW_STOP_RESOURCE;c->resource_detail=p->failure_reason;
                c->snapshot_count=buffers;c->texture_count=textures;c->sampler_count=samplers;
                memcpy(p->offsets,prior_offsets,buffers*sizeof(*prior_offsets));memcpy(p->lengths,prior_lengths,buffers*sizeof(*prior_lengths));
                p->buffer_bytes=buffer_bytes;p->texture_bytes=texture_bytes;p->virtual_count=p->active_snapshots=buffers;p->merged=0;
                for(size_t i=0;i<buffers;i++)p->alias[i]=(uint16_t)i;snapshot_index_rebuild(p);goto stopped;
            }
            invocations+=c->vertex_count*c->instance_count;store_plan(c,&c->draws[c->draw_count]);
            c->draws[c->draw_count].ia_fetch=fetch;
            c->draw_count++;
            if(p->merged)compact_snapshots(p);else c->snapshot_count=p->virtual_count;
            if(c->draw_count==draw_limit){c->stop_command=next->next.ptr;command_position=seen+1;c->complete_pass=!c->stop_command;c->stop_reason=c->complete_pass?FF_DRAW_STOP_END:FF_DRAW_STOP_DRAW_LIMIT;goto finalized;}
            break;}

        default:goto stopped;
        }
    }
    command_position=seen;c->stop_command=next;c->complete_pass=!next;c->stop_reason=next?FF_DRAW_STOP_COMMAND_LIMIT:FF_DRAW_STOP_END;goto finalized;
stopped:c->stop_command=next;c->complete_pass=0;
finalized:
    c->stop_command_type=c->stop_command?c->stop_command->type:UINT32_MAX;
    if(!c->draw_count){failure_stage="no-draw";goto rejected;}
    for(size_t i=0;i<c->snapshot_count;i++){c->source_offset[i]=p->offsets[i];c->source_length[i]=p->lengths[i];c->source_incarnation[i]=p->incarnations[i];c->source_generation[i]=p->generations[i];}
    for(size_t i=0;i<c->draw_count;i++)rebase_plan(p,&c->draws[i]);
    restore_plan(c,&c->draws[0]);
    c->snapshot_bytes=p->buffer_bytes;
    c->texture_reuse=[[NSMutableDictionary alloc]init];
    c->direct_pass=ffjp_enabled();if(c->direct_pass)c->direct_journal=[[NSMutableDictionary alloc]init];
    if(filter&&!filter(c,filter_context)){failure_stage="filter";goto rejected;}
    /* Validate the complete resource graph before allocating any GPU staging;
     * unsupported draws must not churn allocations while the game continues. */
    int extended=buffer_limit>FF_VERTEX_BYTES_LIMIT&&c->snapshot_bytes>FF_VERTEX_BYTES_LIMIT;
    for(size_t i=0;i<c->snapshot_count;i++){
        if(c->reference_input_version[i]){
            id<MTLBuffer> source=p->sources[i];
            if(!source||source!=(id<MTLBuffer>)(uintptr_t)c->reference_source_handle[i]||
               source.device!=command.device||source.storageMode!=MTLStorageModeShared||
               source.heap||[source isAliasable])c->reference_input_version[i]=0;
            c->reference_source_handle[i]=0; /* producer-local borrowed handle */
        }
        if(c->direct_pass){
            void *owned=NULL;size_t total=0;
            if(c->reference_input_version[i]){
                ffjp_record r={.magic=FFJP_MAGIC,.root=c->source_incarnation[i],.generation=c->source_generation[i],
                    .epoch=c->reference_input_version[i],.offset=p->offsets[i],.length=p->lengths[i],.flags=FFJP_NATIVE};
                total=sizeof(r);owned=malloc(total);if(owned)memcpy(owned,&r,total);
            }else if(c->direct_eligible[i])owned=fullframe_direct_journal_copy(c->source_incarnation[i],c->source_generation[i],p->offsets[i],(uint64_t)(uintptr_t)p->sources[i],p->lengths[i],&total);
            if(!owned){failure_stage="direct-journal-missing-writer";failure_index=i;goto rejected;}
            NSData *event=[[NSData alloc]initWithBytesNoCopy:owned length:total freeWhenDone:YES];
            c->direct_journal[@(i)]=event;[event release];c->serialized_length[i]=p->lengths[i];continue;
        }
        if(c->reference_input_version[i])continue;
        if(allocator)c->snapshots[i]=allocator(p->device,p->lengths[i],&c->shared_snapshot_extents[i],allocator_context);
        if(!c->snapshots[i]&&!extended)c->snapshots[i]=stage_buffer(p->device,p->lengths[i]);
        if(!c->snapshots[i]){failure_stage="buffer-allocation";failure_index=i;goto rejected;}
    }
    for(size_t i=0;i<c->texture_count;i++){
        if(c->direct_pass&&c->direct_texture_versions[i])continue;
        id owner=c->texture_reuse[@(i)];
        if(owner&&[owner length]==c->textures[i].length&&[owner bytes]){c->textures[i].bytes=[owner bytes];continue;}
        c->texture_buffers[i]=extended?(allocator?allocator(p->device,c->textures[i].length,NULL,allocator_context):nil):
            [p->device newBufferWithLength:c->textures[i].length options:MTLResourceStorageModeShared];
        if(!c->texture_buffers[i]){failure_stage="texture-allocation";failure_index=i;goto rejected;}
        c->textures[i].bytes=c->texture_buffers[i].contents;
    }
    unsigned directMode=fullframe_direct_upload_mode();size_t directCount=0,gpuCount=0;
    for(size_t i=0;i<c->snapshot_count;i++)if(!c->direct_pass&&!c->reference_input_version[i]){
        id<MTLBuffer> source=p->sources[i];
        if(directMode&&c->direct_eligible[i]&&(source.storageMode==MTLStorageModeShared||source.storageMode==MTLStorageModeManaged)&&!source.heap&&![source isAliasable]&&
           fullframe_direct_upload_copy(c->source_incarnation[i],c->source_generation[i],p->offsets[i],(uint64_t)(uintptr_t)source,c->snapshots[i].contents,p->lengths[i])){
            c->direct_copied[i]=1;++directCount;
            if(directMode==1){c->direct_shadow[i]=malloc(p->lengths[i]);if(!c->direct_shadow[i]){failure_stage="direct-shadow-allocation";goto rejected;}
                memcpy(c->direct_shadow[i],c->snapshots[i].contents,p->lengths[i]);}
        }else ++gpuCount;
    }
    for(size_t i=0;i<c->texture_count;i++)if(c->texture_buffers[i])++gpuCount;
    /* Early CPU serialization is enabled only for the continuous native path;
     * no offline reference capture borrows the cut after prepare returns. */
    (void)gpuCount;c->direct_cpu_ready=0; /* direct journal publication remains ordered with chunk completion */
    if(c->direct_pass){c->compacted=1;c->serialized_bytes=0;for(size_t j=0;j<c->snapshot_count;j++)c->serialized_bytes+=c->serialized_length[j];}
    if(directCount){static _Atomic uint64_t passes,early,uploads;uint64_t sample=atomic_fetch_add(&passes,1)+1;
      atomic_fetch_add(&uploads,directCount);if(c->direct_cpu_ready)atomic_fetch_add(&early,1);
      if(sample<=2||!(sample%256))fprintf(stderr,"[direct-upload-pass] mode=%u passes=%llu early=%llu uploads=%llu\n",directMode,(unsigned long long)sample,(unsigned long long)atomic_load(&early),(unsigned long long)atomic_load(&uploads));}
    c->ready_fence=[command.device newFence];if(!c->ready_fence){failure_stage="fence-allocation";goto rejected;}
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];if(!blit){failure_stage="blit-encoder";goto rejected;}
    for(size_t i=0;i<fence_count;i++)[blit waitForFence:fences[i]];
    for(size_t i=0;i<c->snapshot_count;i++){
        if(c->direct_pass||c->reference_input_version[i]||(directMode==2&&c->direct_copied[i]))continue;
#ifdef BEDROCK_BOUNDARY_UPLOADS
        int owned=fullframe_boundary_upload_copy(c->source_incarnation[i],c->source_generation[i],
            p->offsets[i],c->snapshots[i].contents,p->lengths[i]);
        if(owned<0){[blit endEncoding];failure_stage="immutable-upload";failure_index=i;goto rejected;}
        if(owned)continue;
#endif
        [blit copyFromBuffer:p->sources[i] sourceOffset:p->offsets[i] toBuffer:c->snapshots[i] destinationOffset:0 size:p->lengths[i]];
    }
    for(size_t i=0;i<c->texture_count;i++)if(c->texture_buffers[i])for(size_t j=0;j<c->textures[i].plane_count;j++){
        ff_texture_snapshot *s=&c->textures[i];ff_texture_plane plane=s->planes[j];
        [blit copyFromTexture:p->texture_sources[i] sourceSlice:plane.slice sourceLevel:plane.mip sourceOrigin:MTLOriginMake(0,0,0)
            sourceSize:MTLSizeMake(MAX(1,s->width>>plane.mip),MAX(1,s->height>>plane.mip),1) toBuffer:c->texture_buffers[i]
            destinationOffset:plane.offset destinationBytesPerRow:plane.row_bytes destinationBytesPerImage:plane.length];}
    [blit updateFence:c->ready_fence];[blit endEncoding];
    if(!c->direct_cpu_ready)[command addCompletedHandler:^(id<MTLCommandBuffer> finished){
      c->staging_gpu_completed=finished.status==MTLCommandBufferStatusCompleted;
      if(c->staging_gpu_completed)for(size_t i=0;i<c->snapshot_count;i++)if(c->direct_shadow[i]&&memcmp(c->direct_shadow[i],c->snapshots[i].contents,c->source_length[i])){
        fprintf(stderr,"[direct-upload-shadow] mismatch=1\n");c->staging_gpu_completed=0;break;}
      completion(c,c->staging_gpu_completed,context);
    }];
    free(p);*scheduled=c;return 1;
rejected:
    if(diagnostics)cut_failure("stage=%s index=%zu capture=%llu draws=%zu complete=%d stop=%u command=%u command_index=%u detail=%u buffer_candidates=%zu texture_candidates=%zu buffers=%zu textures=%zu buffer_bytes=%zu texture_bytes=%zu\n",
        failure_stage,failure_index,(unsigned long long)c->capture_id,c->draw_count,c->complete_pass,c->stop_reason,c->stop_command_type,command_position,c->resource_detail,
        p->candidate_count,p->texture_count,c->snapshot_count,c->texture_count,p->buffer_bytes,p->texture_bytes);
    free(p);ff_draw_cut_destroy(c);return 0;
}

int ff_draw_pass_cut_schedule_checked_with_allocator(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    return schedule_cut(command,head,initial,resolver,resolver_context,fences,fence_count,draw_limit,filter,filter_context,
        allocator,allocator_context,completion,context,scheduled,1,FF_VERTEX_BYTES_LIMIT,NULL,NULL);
}

int ff_draw_pass_cut_schedule_checked_with_allocator_witness(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_range_witness witness,void *witness_context,ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    return schedule_cut(command,head,initial,resolver,resolver_context,fences,fence_count,draw_limit,filter,filter_context,
        allocator,allocator_context,completion,context,scheduled,1,FF_VERTEX_BYTES_LIMIT,witness,witness_context);
}

int ff_draw_pass_cut_schedule_bounded_staging(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    if(!filter)return 0; /* The filter must reserve all staging before allocation. */
    return schedule_cut(command,head,initial,resolver,resolver_context,fences,fence_count,draw_limit,filter,filter_context,
        allocator,allocator_context,completion,context,scheduled,1,FF_DRAW_STAGING_BYTES_LIMIT,NULL,NULL);
}

int ff_draw_pass_cut_schedule_bounded_staging_witness(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_snapshot_allocator allocator,void *allocator_context,
    ff_draw_range_witness witness,void *witness_context,ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    if(!filter)return 0;
    return schedule_cut(command,head,initial,resolver,resolver_context,fences,fence_count,draw_limit,filter,filter_context,
        allocator,allocator_context,completion,context,scheduled,1,FF_DRAW_STAGING_BYTES_LIMIT,witness,witness_context);
}

int ff_draw_pass_cut_schedule_checked(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_filter filter,void *filter_context,ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    return schedule_cut(command,head,initial,resolver,resolver_context,fences,fence_count,
        draw_limit,filter,filter_context,NULL,NULL,completion,context,scheduled,0,FF_VERTEX_BYTES_LIMIT,NULL,NULL);
}

int ff_draw_pass_cut_schedule(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    ff_draw_layout_resolver resolver,void *resolver_context,const id<MTLFence> *fences,size_t fence_count,size_t draw_limit,
    ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    return ff_draw_pass_cut_schedule_checked(command,head,initial,resolver,resolver_context,fences,fence_count,draw_limit,
        NULL,NULL,completion,context,scheduled);
}

static int single_layout(id<MTLRenderPipelineState> pipeline,const struct wmtcmd_base *draw,ff_draw_layout *out,void *context){
    (void)pipeline;const ff_draw_layout *layout=context;if(!layout)return 0;
    if(draw->type==WMTRenderCommandDraw&&!layout->ia_slot_mask&&!layout->constant_count[0]&&!layout->constant_count[1]&&
        !layout->arguments[0].byte_length&&!layout->arguments[1].byte_length)return 0;
    *out=*layout;return 1;
}
int ff_draw_cut_schedule(id<MTLCommandBuffer> command,const struct wmtcmd_base *head,id<MTLBuffer> initial,
    const ff_draw_layout *layout,const id<MTLFence> *fences,size_t fence_count,ff_draw_cut_completion completion,void *context,struct ff_draw_cut **scheduled){
    return ff_draw_pass_cut_schedule(command,head,initial,single_layout,(void *)layout,fences,fence_count,1,completion,context,scheduled);
}

int fullframe_live_sampler(uint64_t handle,ff_sampler_snapshot *s){return sampler_lookup(handle,s);}
