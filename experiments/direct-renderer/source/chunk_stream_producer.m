extern void fullframe_stage_pool_retain(id buffer);
extern void fullframe_stage_pool_release(id buffer,unsigned completion);
/* Continuous source bridge. MRC. Original work remains enabled. */
#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#import "chunk_stream_producer.h"
#import "source_frame_samples.h"
#include <fcntl.h>
#include <pthread.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <dlfcn.h>
#include <dispatch/dispatch.h>
#include <stdatomic.h>
#ifdef BEDROCK_TEST_SOURCE_COMPLETION
__attribute__((weak)) void fullframe_test_before_publish(uint64_t serial){(void)serial;}
#endif

@class FFSCSourceChunk;
typedef struct {
    uint64_t prepare_ns,serialize_ns,io_wait_ns,json_ns,json_bytes;
    uint64_t buffer_bytes,texture_bytes,snapshot_copies,clone_ns,clone_bytes;
    uint64_t hash_ns,hash_bytes,packet_ns,publish_ns,wire_bytes,inline_bytes,cached_bytes,logical_bytes,record_ns;
    uint64_t compare_ns,compare_bytes,digest_reused_bytes,interned_bytes;
    uint64_t segmented_bytes,segment_pages;
    uint64_t cache_hits,cache_misses,cache_evictions;
    uint64_t stable_identity_bytes;
    uint64_t staging_wait_ns;
    uint64_t private_texture_hits,private_texture_misses,private_texture_reused_bytes;
    uint64_t staging_count_ns,staging_budget_ns,staging_cuts_ns;
    uint64_t packet_lock_ns,retirement_commit_ns;
    uint64_t shared_alloc_bytes,shared_alloc_count,shared_slot_full_bytes,shared_slot_full_count;
    uint64_t compact_ns,buffer_sink_ns,texture_sink_ns,graph_ns,replay_ns,sidecar_ns;
} FFSCSourceProfile;
@interface FFSCSourceBlob:NSObject {
@public NSData *data;id<MTLBuffer> snapshot_owner;id memo_owner;NSString *hash;unsigned char sha[32];uint64_t length,shared_offset;
    unsigned memo_refs,memo_pins;int receiver_digest,shared_snapshot;
}
@end
@implementation FFSCSourceBlob
- (void)dealloc {[data release];fullframe_stage_pool_release(snapshot_owner,1);[snapshot_owner release];[memo_owner release];[hash release];[super dealloc];}
@end
@interface FFSCSourceCacheEntry:NSObject {
@public NSString *hash;uint64_t serial,length;NSUInteger writer_pins;
    FFSCSourceCacheEntry *previous,*next;
}
@end
@implementation FFSCSourceCacheEntry
- (void)dealloc {[hash release];[super dealloc];}
@end
@interface FFSCSourceIdentity:NSObject {
@public uint64_t kind,root,view,offset,length;
    NSString *private_key,*private_digest;int private_accepted;
}
@end
@implementation FFSCSourceIdentity
- (void)dealloc {[private_key release];[private_digest release];[super dealloc];}
@end
static void memo_unpin(FFSCSourceBlob *sample);
@interface FFSCPrivateTexture:NSObject {
@public FFSCSourceBlob *sample;
}
- (const void *)bytes;
- (NSUInteger)length;
@end
@implementation FFSCPrivateTexture
- (const void *)bytes {return sample->data.bytes;}
- (NSUInteger)length {return sample->data.length;}
- (void)dealloc {memo_unpin(sample);[sample release];[super dealloc];}
@end
@interface FFSCMemoHint:NSObject {
@public NSString *key,*hash;FFSCMemoHint *previous,*next;
}
@end
@implementation FFSCMemoHint
- (void)dealloc {[key release];[hash release];[super dealloc];}
@end
@interface FFSCReadbackTarget:NSObject {
@public id<MTLBuffer> buffer;ffrb_record expected;uint64_t payload,view,ref_offset,ref_length;
    uint32_t resource;int delivered;
}
@end
@implementation FFSCReadbackTarget
- (void)dealloc {[buffer release];[super dealloc];}
@end
@interface FFSCCompletionBinding:NSObject {
@public id<MTLCommandBuffer> command;ffsc_packet_header packet;NSMutableData *queries;
    unsigned char fetched[FFCC_MAX_QUERIES];size_t fetched_count;uint64_t frame_digest;int tracked,published,source_completed,presented;
    NSMutableArray *readbacks;uint64_t readback_bytes;size_t returned;
}
@end
@implementation FFSCCompletionBinding
- (void)dealloc {[command release];[queries release];[readbacks release];[super dealloc];}
@end
@interface FFSCSourcePayload:NSObject {
@public FFSCSourceChunk *chunk;uint64_t payload;int token;NSMutableDictionary *blobs;NSString *kind;
    NSMutableDictionary *segments;NSMutableSet *original_names;
    NSMutableDictionary *identities;
    NSMutableDictionary *texture_proofs,*texture_budget_owners;
    uint32_t encoder,category;ffcc_query query;int has_query;
    uint64_t resident_bytes,retained_limit;NSMutableDictionary *retained_snapshots;
}
@end
@implementation FFSCSourcePayload
- (void)dealloc {[blobs release];[segments release];[original_names release];[identities release];[texture_proofs release];[texture_budget_owners release];[retained_snapshots release];[kind release];[super dealloc];}
@end
@interface FFSCSourceChunk:NSObject {
@public uint64_t serial,stream,frame,chunk,queue_completion,bytes;NSMutableData *records;
    uint64_t logical_bytes;size_t blob_count;
    ffsa_lease shared_lease;size_t shared_blob_count,shared_views_live;
    int shared_claimed,shared_sealed,shared_view_created,shared_unexported;
    NSMutableDictionary *payloads;NSMutableArray *dependencies,*retirements;int source_completed,sealed,published,frame_begin,frame_end;
    NSMutableDictionary *resident_blobs;NSMutableSet *retired_during_chunk,*synthetic_roots;
    FFSCCompletionBinding *completion;
    FFSCSourceProfile profile;uint64_t born_ns,admitted_ns,sealed_ns,gpu_done_ns,payload_ready_ns,publish_begin_ns,published_ns,gpu_ns;
}
@end
@implementation FFSCSourceChunk
- (void)dealloc {[records release];[payloads release];[resident_blobs release];[retired_during_chunk release];[synthetic_roots release];[dependencies release];[retirements release];[completion release];[super dealloc];}
@end

static pthread_mutex_t source_lock=PTHREAD_MUTEX_INITIALIZER;
/* Stop and transport publication have one linearization point. */
static pthread_mutex_t publish_lock=PTHREAD_MUTEX_INITIALIZER;
/* Two lanes share their capacity with the segmented-page workers. */
static pthread_mutex_t serializer_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t serializer_changed=PTHREAD_COND_INITIALIZER;
static unsigned serializer_permits=2,serializer_waiters;
static _Thread_local int serializer_owned,serializer_extra;
static pthread_once_t private_serializer_once=PTHREAD_ONCE_INIT;
static void private_serializer_initialize(void){const char *v=getenv("BEDROCK_PRIVATE_SOURCE_IO");
    serializer_permits=v&&!strcmp(v,"3")?3u:v&&!strcmp(v,"4")?4u:2u;
    fprintf(stderr,"[IOP1] permits=%u\n",serializer_permits);
}
void fullframe_chunk_serializer_enter(void){
    pthread_once(&private_serializer_once,private_serializer_initialize);
    if(serializer_owned)abort();pthread_mutex_lock(&serializer_lock);
    if(!serializer_permits){serializer_waiters++;
        while(!serializer_permits)pthread_cond_wait(&serializer_changed,&serializer_lock);
        serializer_waiters--;}
    serializer_permits--;serializer_owned=1;pthread_mutex_unlock(&serializer_lock);
}
void fullframe_chunk_serializer_leave(void){
    if(!serializer_owned||serializer_extra)abort();pthread_mutex_lock(&serializer_lock);
    serializer_owned=0;serializer_permits++;pthread_cond_signal(&serializer_changed);pthread_mutex_unlock(&serializer_lock);
}
static int serializer_try_extra(void){
    if(!serializer_owned||serializer_extra)return 0;pthread_mutex_lock(&serializer_lock);
    int ok=serializer_permits&&!serializer_waiters;if(ok){serializer_permits--;serializer_extra=1;}
    pthread_mutex_unlock(&serializer_lock);return ok;
}
static void serializer_return_extra(void){
    if(!serializer_owned||!serializer_extra)abort();pthread_mutex_lock(&serializer_lock);
    serializer_extra=0;serializer_permits++;pthread_cond_signal(&serializer_changed);pthread_mutex_unlock(&serializer_lock);
}
static pthread_cond_t source_changed=PTHREAD_COND_INITIALIZER;
static ffsc_endpoint *endpoint;
static ffsa_endpoint *snapshot_arena;
static NSMutableArray *chunks;
static NSMutableDictionary *tokens,*cache;
static NSMutableDictionary *seen_roots,*seen_root_generations;
static NSMutableArray *pending_retirements,*collector_retirements;
static FFSCSourceChunk *current;
static ffs_collector *collector;
static ffs_record frame_prefix;
static int has_prefix,initialized,stopped,exiting,next_token=2,collector_ended,receiver_digest_enabled;
static uint64_t next_serial=1,cache_bytes;
static uint64_t source_progress_generation,source_capture_headroom=FFSC_SOURCE_CAPTURE_HEADROOM;
/* Protected by source_lock from before admission releases it until the
 * prospective chunk takes ownership or admission fails. */
static uint64_t admission_serial;static NSMutableSet *admission_markers;
static unsigned source_staging_chunks=FFSC_SOURCE_STAGING_CHUNKS;
static FFSCSourceCacheEntry *cache_oldest,*cache_newest;
/* Metadata only: 8192 exact digest observations, no captured bytes or objects.
 * Eight-way buckets bound lookup work and memory even for all-new frame data. */
#define SOURCE_ADMISSION_BUCKETS 1024u
#define SOURCE_ADMISSION_WAYS 8u
typedef struct {unsigned char sha[32];uint64_t length,first_serial,touched;} FFSCAdmissionObservation;
static FFSCAdmissionObservation admission_seen[SOURCE_ADMISSION_BUCKETS][SOURCE_ADMISSION_WAYS];
static uint64_t admission_clock,admission_cold_skips,admission_repeats,admission_immutable;
static int admission_active;

static ffcc_registry *completions;
static NSMutableDictionary *completion_bindings;
static int completion_enabled,captured_started,timeline_enabled;
/* Access is serialized by source_lock; the ring is allocated only when opted in. */
static ff_source_frame_samples source_frame_samples = {.directory_fd = -1};
static uint64_t native_completed,native_timestamp_groups,native_event_groups,native_presented_frames;
static ffrb_endpoint *readback_endpoint;
static uint64_t native_readback_ranges,native_readback_bytes,native_readback_cpu_bytes;
static FFSCSourceProfile profile_total;
static uint64_t profiled_chunks;
/* Ordinary hints compare every fresh byte. A separate exact ordered-version
 * proof permits retaining an already captured non-shareable private texture. */
#define SOURCE_MEMO_BYTES (UINT64_C(64)*1024*1024)
#define SOURCE_MEMO_HINTS 4096u
static pthread_mutex_t memo_lock=PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *memo_samples,*memo_contents;
static FFSCMemoHint *memo_oldest,*memo_newest;
static uint64_t memo_retained;
static NSString *texture_record_key(uint64_t root,uint64_t generation,uint64_t view,uint64_t version);
static uint64_t profile_clock(void){struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;return (uint64_t)t.tv_sec*1000000000+(uint64_t)t.tv_nsec;}
/* Timeline events use the same host CLOCK_MONOTONIC domain as the native
 * worker. Disabled unless explicitly requested; never compare GPU timestamps
 * or process-relative clocks without a separate calibration. */
static void timeline_chunk(const char *event,FFSCSourceChunk *c,uint64_t at){
    if(!timeline_enabled||!c)return;
    fprintf(stderr,"[native-source-timeline] clock=CLOCK_MONOTONIC event=%s at_ns=%llu stream=%llu frame=%llu chunk=%llu serial=%llu queue_completion=%llu begin_ns=%llu admitted_ns=%llu sealed_ns=%llu gpu_done_ns=%llu payload_ready_ns=%llu publish_begin_ns=%llu published_ns=%llu\n",
        event,(unsigned long long)at,(unsigned long long)c->stream,(unsigned long long)c->frame,
        (unsigned long long)c->chunk,(unsigned long long)c->serial,(unsigned long long)c->queue_completion,
        (unsigned long long)c->born_ns,(unsigned long long)c->admitted_ns,(unsigned long long)c->sealed_ns,
        (unsigned long long)c->gpu_done_ns,(unsigned long long)c->payload_ready_ns,
        (unsigned long long)c->publish_begin_ns,(unsigned long long)c->published_ns);
}
static void profile_add(FFSCSourceChunk *c,uint32_t stage,uint64_t ns,uint64_t bytes,uint64_t count){
    if(!c)return;FFSCSourceProfile *p=&c->profile;
    if(stage==FFSC_PROFILE_PREPARE)p->prepare_ns+=ns;
    else if(stage==FFSC_PROFILE_SNAPSHOT_BUFFER){p->buffer_bytes+=bytes;p->snapshot_copies+=count;}
    else if(stage==FFSC_PROFILE_SNAPSHOT_TEXTURE){p->texture_bytes+=bytes;p->snapshot_copies+=count;}
    else if(stage==FFSC_PROFILE_SERIALIZE)p->serialize_ns+=ns;
    else if(stage==FFSC_PROFILE_IO_WAIT)p->io_wait_ns+=ns;
    else if(stage==FFSC_PROFILE_JSON){p->json_ns+=ns;p->json_bytes+=bytes;}
    else if(stage==FFSC_PROFILE_COMPACT)p->compact_ns+=ns;
    else if(stage==FFSC_PROFILE_BUFFER_SINK)p->buffer_sink_ns+=ns;
    else if(stage==FFSC_PROFILE_TEXTURE_SINK)p->texture_sink_ns+=ns;
    else if(stage==FFSC_PROFILE_GRAPH)p->graph_ns+=ns;
    else if(stage==FFSC_PROFILE_REPLAY)p->replay_ns+=ns;
    else if(stage==FFSC_PROFILE_SIDECAR)p->sidecar_ns+=ns;
}
void fullframe_chunk_profile_context(const ffs_producer_context *context,uint32_t stage,uint64_t ns,uint64_t bytes,uint64_t count){
    if(!context)return;pthread_mutex_lock(&source_lock);
    for(FFSCSourceChunk *c in chunks)if(c->stream==context->stream&&c->frame==context->frame&&c->chunk==context->chunk){profile_add(c,stage,ns,bytes,count);break;}
    pthread_mutex_unlock(&source_lock);
}
void fullframe_chunk_profile_token(int token,uint32_t stage,uint64_t ns,uint64_t bytes,uint64_t count){
    if(token>=-1)return;pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    if(p&&!p->kind)profile_add(p->chunk,stage,ns,bytes,count);pthread_mutex_unlock(&source_lock);
}
static void profile_published(FFSCSourceChunk *c){
    uint64_t now=profile_clock(),ready=c->sealed_ns;if(c->gpu_done_ns>ready)ready=c->gpu_done_ns;
    if(c->payload_ready_ns>ready)ready=c->payload_ready_ns;profiled_chunks++;
#define ADD_PROFILE(field) profile_total.field+=c->profile.field
    ADD_PROFILE(prepare_ns);ADD_PROFILE(serialize_ns);ADD_PROFILE(io_wait_ns);ADD_PROFILE(json_ns);ADD_PROFILE(json_bytes);
    ADD_PROFILE(buffer_bytes);ADD_PROFILE(texture_bytes);ADD_PROFILE(snapshot_copies);ADD_PROFILE(clone_ns);ADD_PROFILE(clone_bytes);
    ADD_PROFILE(hash_ns);ADD_PROFILE(hash_bytes);ADD_PROFILE(packet_ns);ADD_PROFILE(publish_ns);ADD_PROFILE(wire_bytes);
    ADD_PROFILE(inline_bytes);ADD_PROFILE(cached_bytes);ADD_PROFILE(logical_bytes);ADD_PROFILE(record_ns);
    ADD_PROFILE(compare_ns);ADD_PROFILE(compare_bytes);ADD_PROFILE(digest_reused_bytes);ADD_PROFILE(interned_bytes);
    ADD_PROFILE(segmented_bytes);ADD_PROFILE(segment_pages);
    ADD_PROFILE(cache_hits);ADD_PROFILE(cache_misses);ADD_PROFILE(cache_evictions);ADD_PROFILE(stable_identity_bytes);ADD_PROFILE(staging_wait_ns);
    ADD_PROFILE(private_texture_hits);ADD_PROFILE(private_texture_misses);ADD_PROFILE(private_texture_reused_bytes);
    ADD_PROFILE(staging_count_ns);ADD_PROFILE(staging_budget_ns);ADD_PROFILE(staging_cuts_ns);
    ADD_PROFILE(packet_lock_ns);ADD_PROFILE(retirement_commit_ns);
    ADD_PROFILE(shared_alloc_bytes);ADD_PROFILE(shared_alloc_count);
    ADD_PROFILE(shared_slot_full_bytes);ADD_PROFILE(shared_slot_full_count);
    ADD_PROFILE(compact_ns);ADD_PROFILE(buffer_sink_ns);ADD_PROFILE(texture_sink_ns);
    ADD_PROFILE(graph_ns);ADD_PROFILE(replay_ns);ADD_PROFILE(sidecar_ns);
#undef ADD_PROFILE
    if(profiled_chunks<=4||!(profiled_chunks%32))fprintf(stderr,"[native-source-profile] serial=%llu frame=%llu chunk=%llu chunks=%llu prepare_ns=%llu records_ns=%llu serialize_ns=%llu io_wait_ns=%llu json_ns=%llu json_bytes=%llu snapshot_buffer_bytes=%llu snapshot_texture_bytes=%llu snapshot_copies=%llu clone_ns=%llu clone_bytes=%llu hash_ns=%llu hash_bytes=%llu packet_ns=%llu publish_ns=%llu wire_bytes=%llu cached_bytes=%llu inline_bytes=%llu logical_bytes=%llu resident_bytes=%llu gpu_ns=%llu begin_to_gpu_ns=%llu ready_to_publish_ns=%llu begin_to_publish_ns=%llu total_prepare_ns=%llu total_serialize_ns=%llu total_hash_ns=%llu total_packet_ns=%llu total_wire_bytes=%llu compare_ns=%llu compare_bytes=%llu digest_reused_bytes=%llu interned_bytes=%llu total_compare_ns=%llu total_digest_reused_bytes=%llu segmented_bytes=%llu segment_pages=%llu cache_bytes=%llu cache_blobs=%llu cache_hits=%llu cache_misses=%llu cache_evictions=%llu total_cache_hits=%llu total_cache_misses=%llu total_cache_evictions=%llu stable_identity_bytes=%llu total_stable_identity_bytes=%llu staging_wait_ns=%llu source_staging_chunks=%llu total_staging_wait_ns=%llu private_texture_hits=%llu private_texture_misses=%llu private_texture_reused_bytes=%llu total_private_texture_reused_bytes=%llu staging_count_ns=%llu staging_budget_ns=%llu staging_cuts_ns=%llu total_staging_count_ns=%llu total_staging_budget_ns=%llu total_staging_cuts_ns=%llu packet_lock_ns=%llu retirement_commit_ns=%llu total_packet_lock_ns=%llu total_retirement_commit_ns=%llu retirement_notices=%llu shared_alloc_bytes=%llu shared_alloc_count=%llu shared_slot_full_bytes=%llu shared_slot_full_count=%llu total_shared_alloc_bytes=%llu total_shared_slot_full_bytes=%llu compact_ns=%llu buffer_sink_ns=%llu texture_sink_ns=%llu graph_ns=%llu replay_ns=%llu sidecar_ns=%llu total_compact_ns=%llu total_buffer_sink_ns=%llu total_texture_sink_ns=%llu total_graph_ns=%llu total_replay_ns=%llu total_sidecar_ns=%llu\n",
        (unsigned long long)c->serial,(unsigned long long)c->frame,(unsigned long long)c->chunk,(unsigned long long)profiled_chunks,
        (unsigned long long)c->profile.prepare_ns,(unsigned long long)c->profile.record_ns,(unsigned long long)c->profile.serialize_ns,(unsigned long long)c->profile.io_wait_ns,
        (unsigned long long)c->profile.json_ns,(unsigned long long)c->profile.json_bytes,(unsigned long long)c->profile.buffer_bytes,(unsigned long long)c->profile.texture_bytes,
        (unsigned long long)c->profile.snapshot_copies,(unsigned long long)c->profile.clone_ns,(unsigned long long)c->profile.clone_bytes,(unsigned long long)c->profile.hash_ns,
        (unsigned long long)c->profile.hash_bytes,(unsigned long long)c->profile.packet_ns,(unsigned long long)c->profile.publish_ns,(unsigned long long)c->profile.wire_bytes,
        (unsigned long long)c->profile.cached_bytes,(unsigned long long)c->profile.inline_bytes,(unsigned long long)c->profile.logical_bytes,(unsigned long long)c->bytes,
        (unsigned long long)c->gpu_ns,(unsigned long long)(c->gpu_done_ns>=c->born_ns?c->gpu_done_ns-c->born_ns:0),
        (unsigned long long)(now>=ready?now-ready:0),(unsigned long long)(now>=c->born_ns?now-c->born_ns:0),
        (unsigned long long)profile_total.prepare_ns,(unsigned long long)profile_total.serialize_ns,(unsigned long long)profile_total.hash_ns,
        (unsigned long long)profile_total.packet_ns,(unsigned long long)profile_total.wire_bytes,
        (unsigned long long)c->profile.compare_ns,(unsigned long long)c->profile.compare_bytes,
        (unsigned long long)c->profile.digest_reused_bytes,(unsigned long long)c->profile.interned_bytes,
        (unsigned long long)profile_total.compare_ns,(unsigned long long)profile_total.digest_reused_bytes,
        (unsigned long long)c->profile.segmented_bytes,(unsigned long long)c->profile.segment_pages,
        (unsigned long long)cache_bytes,(unsigned long long)cache.count,(unsigned long long)c->profile.cache_hits,
        (unsigned long long)c->profile.cache_misses,(unsigned long long)c->profile.cache_evictions,
        (unsigned long long)profile_total.cache_hits,(unsigned long long)profile_total.cache_misses,(unsigned long long)profile_total.cache_evictions,
        (unsigned long long)c->profile.stable_identity_bytes,(unsigned long long)profile_total.stable_identity_bytes,
        (unsigned long long)c->profile.staging_wait_ns,(unsigned long long)chunks.count,(unsigned long long)profile_total.staging_wait_ns,
        (unsigned long long)c->profile.private_texture_hits,(unsigned long long)c->profile.private_texture_misses,
        (unsigned long long)c->profile.private_texture_reused_bytes,(unsigned long long)profile_total.private_texture_reused_bytes,
        (unsigned long long)c->profile.staging_count_ns,(unsigned long long)c->profile.staging_budget_ns,(unsigned long long)c->profile.staging_cuts_ns,
        (unsigned long long)profile_total.staging_count_ns,(unsigned long long)profile_total.staging_budget_ns,(unsigned long long)profile_total.staging_cuts_ns,
        (unsigned long long)c->profile.packet_lock_ns,(unsigned long long)c->profile.retirement_commit_ns,
        (unsigned long long)profile_total.packet_lock_ns,(unsigned long long)profile_total.retirement_commit_ns,
        (unsigned long long)c->retirements.count,
        (unsigned long long)c->profile.shared_alloc_bytes,(unsigned long long)c->profile.shared_alloc_count,
        (unsigned long long)c->profile.shared_slot_full_bytes,(unsigned long long)c->profile.shared_slot_full_count,
        (unsigned long long)profile_total.shared_alloc_bytes,(unsigned long long)profile_total.shared_slot_full_bytes,
        (unsigned long long)c->profile.compact_ns,(unsigned long long)c->profile.buffer_sink_ns,
        (unsigned long long)c->profile.texture_sink_ns,(unsigned long long)c->profile.graph_ns,
        (unsigned long long)c->profile.replay_ns,(unsigned long long)c->profile.sidecar_ns,
        (unsigned long long)profile_total.compact_ns,(unsigned long long)profile_total.buffer_sink_ns,
        (unsigned long long)profile_total.texture_sink_ns,(unsigned long long)profile_total.graph_ns,
        (unsigned long long)profile_total.replay_ns,(unsigned long long)profile_total.sidecar_ns);
}

static void rejected_record(const ffs_record *r,const char *reason){
    ffs_summary s=ffs_inspect(collector);ffs_occupancy occupancy=ffs_inspect_occupancy(collector);
    NSMutableSet *physical_roots=[NSMutableSet set];NSUInteger buffers=0,textures=0;
    for(NSDictionary *root in seen_roots.allValues){
        [physical_roots addObject:[NSString stringWithFormat:@"%@:%@",root[@"kind"],root[@"root"]]];
        if([root[@"kind"]unsignedLongLongValue]==FFS_BUFFER)buffers++;
        else if([root[@"kind"]unsignedLongLongValue]==FFS_TEXTURE)textures++;
    }
    static const char *errors[]={"ok","bad-packet","order","count","limit","identity","dependency","resource-version","missing-present","producer-reject"};
    const char *error=(unsigned)s.error<sizeof(errors)/sizeof(errors[0])?errors[s.error]:"unknown";
    fprintf(stderr,"[native-chunk-source-reject] reason=%s kind=%u flags=%u stream=%llu frame=%llu chunk=%llu encoder=%u item=%u sequence=%llu serial=%llu status=%s error=%s next_sequence=%llu records=%llu chunks=%llu encoders=%llu resources=%llu dependencies=%llu roots=%lu physical_roots=%lu retirements=%lu collector_retirements=%lu buffer_generations=%lu texture_generations=%lu collector_generations=%zu collector_views=%zu collector_dependencies=%zu collector_records=%zu collector_record_capacity=%zu collector_limit=%s collector_view_mapped_bytes=%zu collector_view_control_bytes=%zu collector_view_budget_bytes=%zu data=",
        reason,r->kind,r->flags,(unsigned long long)r->stream,(unsigned long long)r->frame,(unsigned long long)r->chunk,r->encoder,r->item,
        (unsigned long long)r->sequence,(unsigned long long)(next_serial-1),ffs_status_name(s.status),error,
        (unsigned long long)s.next_sequence,(unsigned long long)s.records,(unsigned long long)s.chunks,(unsigned long long)s.encoders,
        (unsigned long long)s.resources,(unsigned long long)s.dependencies,(unsigned long)seen_roots.count,(unsigned long)physical_roots.count,(unsigned long)pending_retirements.count,
        (unsigned long)collector_retirements.count,(unsigned long)buffers,(unsigned long)textures,
        occupancy.generations,occupancy.views,occupancy.dependencies,occupancy.stored_records,occupancy.record_capacity,ffs_limit_name(occupancy.limit),
        ffs_view_storage_bytes(collector),sizeof(void *)+2*sizeof(size_t),(size_t)FFS_VIEW_BUDGET_BYTES);
    for(unsigned i=0;i<12;i++)fprintf(stderr,"%s%llu",i?",":"",(unsigned long long)r->data[i]);fputc('\n',stderr);
    if(r->kind==FFS_RESOURCE){
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)r->data[0],(unsigned long long)r->data[1],(unsigned long long)r->data[3]];
        NSDictionary *old=seen_roots[key];
        if(old)fprintf(stderr,"[native-chunk-source-prior-resource] kind=%llu root=%llu generation=%llu view=%llu offset=%llu length=%llu input=%llu output=%llu last_use_serial=%llu\n",
            [old[@"kind"] unsignedLongLongValue],[old[@"root"] unsignedLongLongValue],[old[@"generation"] unsignedLongLongValue],
            [old[@"view"] unsignedLongLongValue],[old[@"offset"] unsignedLongLongValue],[old[@"length"] unsignedLongLongValue],
            [old[@"input_version"] unsignedLongLongValue],[old[@"output_version"] unsignedLongLongValue],[old[@"last_use_serial"] unsignedLongLongValue]);
    }
}

int fullframe_chunk_stream_enabled(void){const char *p=getenv(FFSC_ENDPOINT_ENV);return p&&p[0]=='/';}
static void stop_source(const char *reason){
    if(exiting)return; /* atexit already quiesced producers; closed channels are expected. */
    if(!stopped)fprintf(stderr,"[native-chunk-source] stopped: %s\n",reason);
    pthread_mutex_lock(&publish_lock);stopped=1;ffsc_stop(endpoint);pthread_mutex_unlock(&publish_lock);
    if(completions)ffcc_fail(completions);ffrb_stop(readback_endpoint);
    ffsa_stop(snapshot_arena);pthread_cond_broadcast(&source_changed);
}
/* Normal process exit is an orderly transport close. Crashes and _exit() do
 * not run this hook, so the peer still reports a dead source in those cases. */
static void close_source_on_exit(void){
    pthread_mutex_lock(&source_lock);exiting=1;
    pthread_mutex_lock(&publish_lock);stopped=1;ffsc_source_close(endpoint);pthread_mutex_unlock(&publish_lock);
    ffrb_stop(readback_endpoint);ffsa_stop(snapshot_arena);
    pthread_cond_broadcast(&source_changed);pthread_mutex_unlock(&source_lock);
    if(source_frame_samples.samples){
        if(!ff_source_frame_samples_write(&source_frame_samples))
            fprintf(stderr,"[native-source-frame-samples] cannot save observation\n");
        ff_source_frame_samples_close(&source_frame_samples);
    }
}
/* `current` is borrowed from chunks and can outlive its last retained slot.
 * Check membership before dereferencing it after transport consumption. */
static int current_chunk_open(void){return chunks.count&&chunks.lastObject==current&&!current->sealed;}
static int queue_retirement(NSDictionary *root){
    if(pending_retirements.count==FFSC_MAX_RETIREMENTS||collector_retirements.count==FFSC_MAX_RETIREMENTS)return 0;
    /* A notice cannot accompany an older packet while this chunk is still
     * recording. It may contain a later use we have not observed yet. */
    uint64_t floor=[root[@"last_use_serial"]unsignedLongLongValue];
    if(admission_serial)floor=MAX(floor,admission_serial);
    else if(current_chunk_open())floor=MAX(floor,current->serial);
    NSMutableDictionary *notice=[root mutableCopy];notice[@"publish_floor"]=@(floor);
    [pending_retirements addObject:notice];[collector_retirements addObject:notice];[notice release];return 1;
}
/* The packet owns the exact notice objects it serialized. New equal-valued
 * notices can arrive while its bytes are assembled or published; preserve
 * them. Pointer membership and one stable bulk removal avoid quadratic
 * NSDictionary equality work under source_lock. */
static void remove_published_retirements(NSArray *published){
    if(!published.count||!pending_retirements.count)return;
    NSHashTable *done=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality|NSPointerFunctionsStrongMemory];
    for(id notice in published)[done addObject:notice];
    NSMutableIndexSet *indexes=[NSMutableIndexSet indexSet];NSUInteger index=0;
    for(id notice in pending_retirements){if([done containsObject:notice])[indexes addIndex:index];index++;}
    [pending_retirements removeObjectsAtIndexes:indexes];
}
static NSString *physical_root_key(uint64_t kind,uint64_t root){
    return [NSString stringWithFormat:@"%llu:%llu",(unsigned long long)kind,(unsigned long long)root];
}
/* source_lock is held. The exact-generation table remains authoritative; this
 * secondary index bounds destruction notices to one physical root's keys. */
static void forget_seen_root(NSString *key,NSDictionary *root){
    extern void fullframe_live_history_retire(uint64_t,uint64_t,uint64_t);fullframe_live_history_retire([root[@"kind"]unsignedLongLongValue],[root[@"root"]unsignedLongLongValue],[root[@"generation"]unsignedLongLongValue]);
    NSString *physical=physical_root_key([root[@"kind"] unsignedLongLongValue],[root[@"root"] unsignedLongLongValue]);
    NSMutableSet *generations=seen_root_generations[physical];[generations removeObject:key];
    if(!generations.count)[seen_root_generations removeObjectForKey:physical];[seen_roots removeObjectForKey:key];
}
/* Only raw upload identities used in this chunk can satisfy the original
 * end-of-chunk retirement rule. The set is exact and lazily allocated. */
static int retire_chunk_synthetic(FFSCSourceChunk *chunk){
    for(NSString *key in chunk->synthetic_roots){NSDictionary *root=seen_roots[key];
        if(root&&[root[@"last_use_serial"]unsignedLongLongValue]==chunk->serial){
            if(!queue_retirement(root))return 0;forget_seen_root(key,root);
        }
    }
    [chunk->synthetic_roots release];chunk->synthetic_roots=nil;return 1;
}
static int retire_collector_generations(void){
    if(!collector)return !collector_retirements.count;
    for(NSDictionary *root in collector_retirements)if(!ffs_retire_generation(collector,[root[@"kind"] unsignedLongLongValue],
        [root[@"root"] unsignedLongLongValue],[root[@"generation"] unsignedLongLongValue]))return 0;
    [collector_retirements removeAllObjects];return 1;
}
static NSString *digest_name(const unsigned char hash[32]){
    static const char digits[]="0123456789abcdef";char hex[65];
    for(unsigned i=0;i<32;i++){hex[i*2]=digits[hash[i]>>4];hex[i*2+1]=digits[hash[i]&15];}hex[64]=0;return @(hex);
}
static NSString *hash_name(NSData *data,unsigned char hash[32]){
    CC_SHA256(data.bytes,(CC_LONG)data.length,hash);return digest_name(hash);
}
static void memo_touch(FFSCMemoHint *entry){
    if(memo_newest==entry)return;
    if(entry->previous)entry->previous->next=entry->next;else if(memo_oldest==entry)memo_oldest=entry->next;
    if(entry->next)entry->next->previous=entry->previous;
    entry->previous=memo_newest;entry->next=nil;
    if(memo_newest)memo_newest->next=entry;else memo_oldest=entry;memo_newest=entry;
}
static FFSCSourceBlob *memo_find(NSString *hint){
    pthread_mutex_lock(&memo_lock);FFSCMemoHint *entry=memo_samples[hint];
    FFSCSourceBlob *sample=entry?[memo_contents[entry->hash] retain]:nil;
    /* Retaining the object alone does not retain its aggregate budget charge. */
    if(sample)sample->memo_pins++;
    if(entry)memo_touch(entry);
    pthread_mutex_unlock(&memo_lock);return sample;
}
static void memo_release_unused(FFSCSourceBlob *sample){
    if(!sample->memo_refs&&!sample->memo_pins){uint64_t length=sample->length;
        [memo_contents removeObjectForKey:sample->hash];memo_retained-=length;fullframe_frame_stream_release_memo(length);}
}
static void memo_unpin(FFSCSourceBlob *sample){
    if(!sample)return;pthread_mutex_lock(&memo_lock);
    if(!sample->memo_pins)abort();sample->memo_pins--;memo_release_unused(sample);pthread_mutex_unlock(&memo_lock);
}
static FFSCPrivateTexture *memo_pin_texture(NSString *key){
    FFSCPrivateTexture *owner=[[FFSCPrivateTexture alloc]init];if(!owner)return nil;
    pthread_mutex_lock(&memo_lock);FFSCMemoHint *hint=memo_samples[key];FFSCSourceBlob *sample=hint?memo_contents[hint->hash]:nil;
    if(sample&&sample->data.length==sample->length&&sample->length){
        sample->memo_pins++;owner->sample=[sample retain];memo_touch(hint);}
    pthread_mutex_unlock(&memo_lock);
    if(!owner->sample){[owner release];return nil;}return owner;
}
/* memo_lock only. No source_lock is held across the aggregate budget calls:
 * payload completion takes guard then source_lock in the opposite direction. */
static void memo_evict(FFSCMemoHint *entry){
    if(!entry)return;FFSCSourceBlob *sample=memo_contents[entry->hash];
    if(entry->previous)entry->previous->next=entry->next;else memo_oldest=entry->next;
    if(entry->next)entry->next->previous=entry->previous;else memo_newest=entry->previous;
    sample->memo_refs--;memo_release_unused(sample);
    [memo_samples removeObjectForKey:entry->key];
}
static void memo_store(NSString *hint,FFSCSourceBlob *blob,const void *fresh,uint64_t *clone_ns,uint64_t *clone_bytes){
    if(!hint||blob->length>SOURCE_MEMO_BYTES)return;
    pthread_mutex_lock(&memo_lock);if(!memo_samples){memo_samples=[[NSMutableDictionary alloc]init];memo_contents=[[NSMutableDictionary alloc]init];}
    FFSCMemoHint *old=memo_samples[hint];
    if(old&&[old->hash isEqual:blob->hash]){memo_touch(old);pthread_mutex_unlock(&memo_lock);return;}
    /* Hits refresh recency; changing tiny constants cannot evict a hot arena
     * merely by advancing a clock slot. Both limits still bound this cache. */
    if(old)memo_evict(old);
    while(memo_samples.count>=SOURCE_MEMO_HINTS)memo_evict(memo_oldest);
    FFSCSourceBlob *sample=memo_contents[blob->hash];
    if(sample&&sample->length!=blob->length){pthread_mutex_unlock(&memo_lock);return;}
    if(!sample){
        while(blob->length>SOURCE_MEMO_BYTES-memo_retained&&memo_oldest)memo_evict(memo_oldest);
        if(blob->length>SOURCE_MEMO_BYTES-memo_retained){pthread_mutex_unlock(&memo_lock);return;}
        if(!fullframe_frame_stream_reserve_memo(blob->length)){pthread_mutex_unlock(&memo_lock);return;}
        sample=[[[FFSCSourceBlob alloc]init]autorelease];sample->length=blob->length;
        if(blob->data)sample->data=[blob->data retain];
        else{uint64_t start=profile_clock();sample->data=[[NSData alloc]initWithBytes:fresh length:(NSUInteger)blob->length];
            *clone_ns+=profile_clock()-start;*clone_bytes+=sample->data.length;}
        if(!sample->data){fullframe_frame_stream_release_memo(blob->length);pthread_mutex_unlock(&memo_lock);return;}
        memcpy(sample->sha,blob->sha,sizeof(sample->sha));sample->hash=[blob->hash copy];
        memo_contents[blob->hash]=sample;memo_retained+=sample->length;
    }
    FFSCMemoHint *entry=[[[FFSCMemoHint alloc]init]autorelease];entry->key=[hint copy];entry->hash=[blob->hash copy];
    sample->memo_refs++;memo_samples[hint]=entry;memo_touch(entry);pthread_mutex_unlock(&memo_lock);
}
/* source_lock is held for the cache dictionary, LRU links and writer pins. */
static void cache_touch(FFSCSourceCacheEntry *entry){
    if(cache_newest==entry)return;
    if(entry->previous)entry->previous->next=entry->next;else if(cache_oldest==entry)cache_oldest=entry->next;
    if(entry->next)entry->next->previous=entry->previous;
    entry->previous=cache_newest;entry->next=nil;
    if(cache_newest)cache_newest->next=entry;else cache_oldest=entry;cache_newest=entry;
}
static FFSCSourceCacheEntry *cache_insert(NSString *hash,uint64_t length,uint64_t serial){
    FFSCSourceCacheEntry *entry=[[[FFSCSourceCacheEntry alloc]init]autorelease];
    entry->hash=[hash copy];entry->length=length;entry->serial=serial;cache[hash]=entry;cache_bytes+=length;cache_touch(entry);return entry;
}
static void cache_remove(FFSCSourceCacheEntry *entry){
    if(entry->previous)entry->previous->next=entry->next;else cache_oldest=entry->next;
    if(entry->next)entry->next->previous=entry->previous;else cache_newest=entry->previous;
    cache_bytes-=entry->length;[cache removeObjectForKey:entry->hash];
}
/* source_lock held. Repeated references inside one packet, or before the
 * first packet has been consumed, do not establish cross-packet reuse. */
static BOOL cache_observe_reuse(FFSCSourceBlob *blob,uint64_t serial,uint64_t consumed){
    uint64_t hash;memcpy(&hash,blob->sha,sizeof(hash));
    FFSCAdmissionObservation *bucket=admission_seen[hash&(SOURCE_ADMISSION_BUCKETS-1)],*victim=&bucket[0];
    uint64_t tick=++admission_clock;
    for(unsigned i=0;i<SOURCE_ADMISSION_WAYS;i++){
        FFSCAdmissionObservation *seen=&bucket[i];
        if(seen->first_serial&&seen->length==blob->length&&!memcmp(seen->sha,blob->sha,32)){
            seen->touched=tick;return seen->first_serial<serial&&seen->first_serial<=consumed;
        }
        if(!seen->first_serial||seen->touched<victim->touched)victim=seen;
    }
    memcpy(victim->sha,blob->sha,32);victim->length=blob->length;
    victim->first_serial=serial;victim->touched=tick;return NO;
}
static BOOL cache_dynamic_metadata(NSString *name){
    return [name isEqual:@"cut-snapshot-batch.bin"]||([name hasSuffix:@".json"]&&![name isEqual:@"replay-template.json"])||
        [name isEqual:@"draw-resource-cut.bin"]||[name isEqual:@"bindings.bin"]||
        ([name hasPrefix:@"cut-buffer-"]&&[name hasSuffix:@".nref"]);
}
static NSMutableArray *cache_plan_policy(FFSCSourceChunk *owner,NSArray *entries,uint64_t consumed,uint64_t byte_limit,NSUInteger entry_limit,BOOL selective){
    NSMutableArray *retired=[NSMutableArray array];NSMutableSet *pinned=[NSMutableSet set];
    /* Published/unpublished chunks may have omitted data after an earlier ACK.
     * Protect all of them, including entries already captured for this packet. */
    for(FFSCSourceChunk *chunk in chunks)for(FFSCSourcePayload *payload in chunk->payloads.allValues)
        for(FFSCSourceBlob *blob in payload->blobs.allValues)[pinned addObject:blob->hash];
    for(NSDictionary *entry in entries)[pinned addObject:((FFSCSourceBlob *)entry[@"blob"])->hash];
    FFSCSourceCacheEntry *victim=cache_oldest;
    for(NSDictionary *entry in entries){
        FFSCSourceBlob *blob=entry[@"blob"];NSString *name=entry[@"name"];
        if(cache_dynamic_metadata(name)||blob->receiver_digest||
           cache[blob->hash]||!blob->data||blob->length>byte_limit||!entry_limit)continue;
        if(selective){
            BOOL repeated=cache_observe_reuse(blob,owner->serial,consumed);
            BOOL immutable=[name hasSuffix:@".metallib"]||[name isEqual:@"replay-template.json"]||[name isEqual:@"draw-plan.bin"];
            if(cache.count>=entry_limit/2||cache_bytes>=byte_limit/2)admission_active=1;
            if(admission_active&&!immutable&&!repeated){admission_cold_skips++;continue;}
            if(immutable)admission_immutable++;else if(repeated)admission_repeats++;
        }
        while((cache.count>=entry_limit||cache_bytes>byte_limit||blob->length>byte_limit-cache_bytes)&&victim){
            FFSCSourceCacheEntry *candidate=victim;victim=victim->next;
            if(candidate->writer_pins||candidate->serial>consumed||[pinned containsObject:candidate->hash])continue;
            [retired addObject:@{@"sha256":candidate->hash,@"bytes":@(candidate->length),@"admitted_serial":@(candidate->serial)}];
            cache_remove(candidate);
        }
        if(cache.count<entry_limit&&cache_bytes<=byte_limit&&blob->length<=byte_limit-cache_bytes)
            (void)cache_insert(blob->hash,blob->length,owner->serial);
    }
    owner->profile.cache_evictions+=retired.count;return retired;
}
static NSMutableArray *cache_plan(FFSCSourceChunk *owner,NSArray *entries,uint64_t consumed,uint64_t byte_limit,NSUInteger entry_limit){
    NSMutableArray *retired=cache_plan_policy(owner,entries,consumed,byte_limit,entry_limit,YES);
    if(!(owner->serial%32))fprintf(stderr,"[native-source-admission] serial=%llu active=%d cold_skips=%llu repeats=%llu immutable=%llu\n",
        (unsigned long long)owner->serial,admission_active,(unsigned long long)admission_cold_skips,
        (unsigned long long)admission_repeats,(unsigned long long)admission_immutable);
    return retired;
}
static int ready(FFSCSourceChunk *c){
    const char *live=getenv("BEDROCK_LIVE_COMMANDS");
    if(!c->sealed||(!(live&&!strcmp(live,"1"))&&!c->source_completed)||c->published)return 0;
    for(FFSCSourcePayload *p in c->payloads.allValues)if(!p->kind)return 0;return 1;
}
static int source_integer(id value,uint64_t expected){
    return [value isKindOfClass:[NSNumber class]]&&CFGetTypeID((CFTypeRef)value)==CFNumberGetTypeID()&&
        !CFNumberIsFloatType((CFNumberRef)value)&&[value compare:@(expected)]==NSOrderedSame;
}
static int source_query_context(FFSCSourcePayload *p,const ffs_producer_context *c){
    p->encoder=c->encoder;p->category=c->category;
    if(c->category==FFS_TIMESTAMP){
        if(c->resource_count||c->command_count||!c->query_count||c->query_count>1000000||c->readback_index>=1000000)return 0;
        p->query=(ffcc_query){.kind=FFSC_TIMESTAMP,.id=c->chunk,.index=c->readback_index,.count=c->query_count};p->has_query=1;
    }else if(c->category==FFS_SIGNAL_EVENT){
        const ffs_producer_dependency *deps=c->dependencies.ptr,*signal=NULL;
        if(c->resource_count||c->command_count||(c->dependency_count&&!deps))return 0;
        for(size_t i=0;i<c->dependency_count;i++)if(deps[i].domain==FFS_EVENT&&deps[i].action==FFS_SIGNAL){if(signal)return 0;signal=&deps[i];}
        if(!signal||!signal->id||!signal->value||signal->flags||signal->reserved)return 0;
        p->query=(ffcc_query){.kind=FFSC_EVENT_QUERY,.id=signal->id,.count=1,.value=signal->value};p->has_query=1;
    }return 1;
}
/* Source context, immutable source sidecar and accepted source ledger must all
 * describe the same query. Native receipt values never create expectations. */
static int source_queries(FFSCSourceChunk *c,NSMutableData *queries){
    NSMutableSet *used=[NSMutableSet set];const ffs_record *records=c->records.bytes;size_t count=c->records.length/sizeof(*records);
    for(size_t i=0;i<count;i++){
        const ffs_record *r=&records[i];if(r->kind!=FFS_ENCODER_BEGIN)continue;
        if(r->data[0]!=FFS_TIMESTAMP&&r->data[0]!=FFS_SIGNAL_EVENT)continue;
        FFSCSourcePayload *p=c->payloads[@(r->data[4])];
        if(!p||!p->has_query||p->encoder!=r->encoder||p->category!=r->data[0]||r->data[1]||r->data[2]||
           ![p->kind isEqual:@"operation"]||[used containsObject:@(p->payload)]||queries.length/sizeof(ffcc_query)==FFCC_MAX_QUERIES)return 0;
        FFSCSourceBlob *blob=p->blobs[@"bindings.json"];id object=blob&&blob->data?[NSJSONSerialization JSONObjectWithData:blob->data options:0 error:nil]:nil;
        if(![object isKindOfClass:[NSDictionary class]])return 0;NSDictionary *metadata=object;
        if((![metadata[@"format"] isEqual:@"bedrock-native-frame-operation"]&&![metadata[@"format"]isEqual:@"bedrock-live-commands"])||!source_integer(metadata[@"version"],1)||
           !source_integer(metadata[@"stream"],c->stream)||!source_integer(metadata[@"frame"],c->frame)||
           !source_integer(metadata[@"chunk"],c->chunk)||!source_integer(metadata[@"encoder"],r->encoder)||
           !source_integer(metadata[@"category"],p->category)||!source_integer(metadata[@"payload_id"],p->payload)||
           ![metadata[@"operations"] isKindOfClass:[NSArray class]]||[metadata[@"operations"] count]!=1)return 0;
        id raw=metadata[@"operations"][0];if(![raw isKindOfClass:[NSDictionary class]])return 0;NSDictionary *op=raw;
        ffcc_query q=p->query;
        if(q.kind==FFSC_TIMESTAMP){
            if(![op[@"op"] isEqual:@"timestamp"]||![op[@"mode"] isEqual:@"command-buffer-end-ns"]||
               !source_integer(op[@"readback_index"],q.index)||!source_integer(op[@"query_count"],q.count))return 0;
        }else{
            if(![op[@"op"] isEqual:@"signal_event"]||!source_integer(op[@"domain"],FFS_EVENT)||
               !source_integer(op[@"id"],q.id)||!source_integer(op[@"value"],q.value))return 0;
            unsigned signals=0;size_t j=i+1;
            for(;j<count&&records[j].kind!=FFS_ENCODER_END;j++)if(records[j].kind==FFS_DEPENDENCY&&
                records[j].data[0]==FFS_EVENT&&records[j].data[4]==FFS_SIGNAL){
                if(records[j].encoder!=r->encoder||records[j].data[1]!=q.id||records[j].data[2]!=q.value||records[j].flags)return 0;signals++;
            }
            if(j==count||signals!=1)return 0;
        }
        [queries appendBytes:&q length:sizeof(q)];[used addObject:@(p->payload)];
    }
    for(FFSCSourcePayload *p in c->payloads.allValues)if(p->has_query&&![used containsObject:@(p->payload)])return 0;
    return 1;
}
static int source_readbacks(FFSCSourceChunk *c,FFSCCompletionBinding *binding){
    const ffs_record *records=c->records.bytes;size_t count=c->records.length/sizeof(*records);
    for(FFSCReadbackTarget *target in binding->readbacks){
        int resource_found=0,command_found=0;uint64_t final_version=0;size_t resource=0;
        FFSCSourcePayload *p=c->payloads[@(target->payload)];if(!p||p->encoder!=target->expected.encoder||
            p->category!=FFS_BLIT||![p->kind isEqual:@"operation"])return 0;
        for(size_t i=0;i<count;i++){const ffs_record *r=&records[i];
            if(r->kind==FFS_ENCODER_BEGIN)resource=0;
            if(r->kind==FFS_RESOURCE){
                if(r->data[0]==FFS_BUFFER&&r->data[1]==target->expected.root&&r->data[3]==target->expected.generation&&(r->flags&FFS_WRITE))final_version=r->data[8];
                if(r->encoder==target->expected.encoder&&resource==target->resource){
                    if(r->data[0]!=FFS_BUFFER||r->data[1]!=target->expected.root||r->data[2]!=target->view||
                       r->data[3]!=target->expected.generation||r->data[5]!=target->ref_offset||r->data[6]!=target->ref_length||
                       r->data[7]!=target->payload||!(r->flags&FFS_WRITE))return 0;resource_found=1;
                }resource++;
            }
            if(r->kind==FFS_COMMAND&&r->encoder==target->expected.encoder&&r->item==target->expected.command){
                if(r->data[0]!=WMTBlitCommandCopyFromTextureToBuffer||r->data[1]!=target->payload)return 0;command_found=1;
            }
        }
        if(!resource_found||!command_found||!final_version)return 0;target->expected.content_version=final_version;
    }return 1;
}
static int track_completion(FFSCSourceChunk *c,const void *wire,size_t wire_length){
    if(!completion_enabled)return 1;FFSCCompletionBinding *binding=c->completion;
    if(!binding||binding->tracked||wire_length<sizeof(ffsc_packet_header))return 0;
    NSMutableData *queries=[NSMutableData data];if(!source_queries(c,queries)||!source_readbacks(c,binding))return 0;
    ffsc_packet_header packet;memcpy(&packet,wire,sizeof(packet));
    if(ffcc_track(completions,&packet,queries.bytes,queries.length/sizeof(ffcc_query))!=FFCC_OK)return 0;
    if(packet.flags&FFSC_FRAME_END){const ffs_record *records=c->records.bytes;size_t count=c->records.length/sizeof(*records);
        if(!count||records[count-1].kind!=FFS_FRAME_END)return 0;binding->frame_digest=records[count-1].data[4];}
    binding->packet=packet;binding->queries=[queries mutableCopy];binding->tracked=1;
    for(FFSCReadbackTarget *target in binding->readbacks){target->expected.serial=packet.serial;target->expected.stream=packet.stream;
        target->expected.frame=packet.frame;target->expected.chunk=packet.chunk;target->expected.record_digest=packet.record_digest;
        target->expected.queue_completion=packet.queue_completion;}
    return 1;
}
static int accept_presentation(const ffsc_receipt *r){
    const char *offscreen=getenv("BEDROCK_NATIVE_OFFSCREEN");
    if(r->kind!=((offscreen&&!strcmp(offscreen,"1"))?FFSC_OFFSCREEN_COMPLETED:FFSC_PRESENTED))return 0;
    FFSCCompletionBinding *binding=completion_bindings[@(r->queue_completion)];
    if(!binding||!binding->tracked||!binding->published||binding->presented||!(binding->packet.flags&FFSC_FRAME_END)||
       r->status!=FFSC_COMPLETED||r->version!=FFSC_VERSION||r->serial!=binding->packet.serial||r->stream!=binding->packet.stream||
       r->frame!=binding->packet.frame||r->chunk!=binding->packet.chunk||r->record_digest!=binding->packet.record_digest||
       r->queue_completion!=binding->packet.queue_completion||r->value!=binding->frame_digest||r->query_kind||r->id||r->index||
       r->count||r->root||r->generation||r->offset||r->length)return 0;
    binding->presented=1;return 1;
}
static size_t packet(FFSCSourceChunk *c,void *target,size_t capacity){
    uint64_t started=profile_clock();
    pthread_mutex_lock(&source_lock);
    if(c->shared_claimed&&!c->shared_sealed){
        if(!c->shared_blob_count){
            c->shared_unexported=1;
            if(!c->shared_views_live){
                if(ffsa_source_abandon(snapshot_arena,c->shared_lease)!=FFSA_OK){pthread_mutex_unlock(&source_lock);return 0;}
                c->shared_claimed=0;
            }
        }else{
            if(ffsa_seal(snapshot_arena,c->shared_lease)!=FFSA_OK){pthread_mutex_unlock(&source_lock);return 0;}
            c->shared_sealed=1;
        }
    }
    pthread_mutex_unlock(&source_lock);
    NSMutableArray *entries=[NSMutableArray array],*payloads=[NSMutableArray array],*segments=[NSMutableArray array];
    NSArray *ids=[[c->payloads allKeys] sortedArrayUsingSelector:@selector(compare:)];
    for(NSNumber *key in ids){
        FFSCSourcePayload *p=c->payloads[key];
        [payloads addObject:@{@"payload_id":@(p->payload),@"kind":p->kind,@"directory":[NSString stringWithFormat:@"payload-%llu",(unsigned long long)p->payload]}];
        for(NSString *name in [[p->blobs allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [entries addObject:@{@"payload":@(p->payload),@"name":name,@"blob":p->blobs[name]}];
        for(NSString *name in [[p->segments allKeys] sortedArrayUsingSelector:@selector(compare:)])
            [segments addObject:p->segments[name]];
    }
    if(entries.count>=FFSC_MAX_BLOBS)return 0;
    /* The sealed, source-completed chunk and its ready payloads are immutable.
     * Only cache decisions and the retirement snapshot require source_lock.
     * Fixed flags preserve this exact transaction while newer blob writers
     * proceed during JSON, hashing, allocation and packet copies. */
    NSMutableData *flagData=[NSMutableData dataWithLength:entries.count*sizeof(uint32_t)];uint32_t *flags=flagData.mutableBytes;
    pthread_mutex_lock(&source_lock);
    if(stopped||!ready(c)){pthread_mutex_unlock(&source_lock);return 0;}
    uint64_t locked=profile_clock();
    uint64_t consumed=ffsc_transport_consumed(endpoint);
    NSArray *evictions=cache_plan(c,entries,consumed,FFSC_CACHE_MAX_BYTES,FFSC_CACHE_MAX_BLOBS);
    for(NSUInteger i=0;i<entries.count;i++){
        NSDictionary *entry=entries[i];FFSCSourceBlob *blob=entry[@"blob"];NSString *name=entry[@"name"];
        if(blob->shared_snapshot){flags[i]=FFSC_BLOB_SHARED_SNAPSHOT;continue;}
        if(blob->receiver_digest){flags[i]=FFSC_BLOB_INLINE|FFSC_BLOB_RECEIVER_DIGEST;c->profile.cache_misses++;continue;}
        FFSCSourceCacheEntry *known=cache_dynamic_metadata(name)?nil:cache[blob->hash];
        if(known&&known->length==blob->length&&known->serial<=consumed){
            flags[i]=FFSC_BLOB_CACHED;c->profile.cached_bytes+=blob->length;c->profile.cache_hits++;cache_touch(known);}
        else{flags[i]=FFSC_BLOB_INLINE;c->profile.cache_misses++;
            if(known&&known->length==blob->length){if(known->serial==c->serial)flags[i]|=FFSC_BLOB_CACHE;cache_touch(known);}}
    }
    [c->retirements removeAllObjects];
    for(NSDictionary *r in pending_retirements)if([r[@"publish_floor"] unsignedLongLongValue]<=c->serial)[c->retirements addObject:r];
    c->profile.packet_lock_ns+=profile_clock()-locked;
    pthread_mutex_unlock(&source_lock);
    NSMutableDictionary *manifest=[@{@"format":@"bedrock-native-chunk-files",@"version":@1,@"serial":@(c->serial),@"stream":@(c->stream),
        @"frame":@(c->frame),@"chunk":@(c->chunk),@"producer_completed":@YES,@"payloads":payloads,@"dependencies":c->dependencies}
        mutableCopy];if(segments.count)manifest[@"segmented_blobs"]=segments;
    if(c->shared_blob_count)manifest[@"shared_snapshot"]=@{@"slot":@(c->shared_lease.slot),
        @"generation":@(c->shared_lease.generation),@"serial":@(c->shared_lease.serial)};
    if(evictions.count)manifest[@"cache_evictions"]=evictions;
    uint64_t json_start=profile_clock();NSData *json=[NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
    c->profile.json_ns+=profile_clock()-json_start;c->profile.json_bytes+=json.length;
    [manifest release];
    if(!json||json.length>8u*1024u*1024u)return 0;
    FFSCSourceBlob *manifest_blob=[[[FFSCSourceBlob alloc]init]autorelease];manifest_blob->data=[json retain];manifest_blob->length=json.length;
    uint64_t hash_start=profile_clock();manifest_blob->hash=[hash_name(json,manifest_blob->sha)copy];
    c->profile.hash_ns+=profile_clock()-hash_start;c->profile.hash_bytes+=json.length;
    [entries insertObject:@{@"payload":@0,@"name":@"chunk.json",@"blob":manifest_blob} atIndex:0];
    if(entries.count>FFSC_MAX_BLOBS||c->records.length/sizeof(ffs_record)>FFS_MAX_RECORDS)return 0;
    size_t table=sizeof(ffsc_packet_header)+c->records.length,retirements_offset=table+entries.count*sizeof(ffsc_blob_entry);
    size_t base=retirements_offset+c->retirements.count*sizeof(ffsc_retirement);
    if(!target||base>capacity||base>FFSC_MAX_PACKET_BYTES)return 0;
    unsigned char *wire=target;memset(wire,0,base);
    ffsc_packet_header h={.magic=FFSC_PACKET_MAGIC,.version=FFSC_VERSION,.bytes=sizeof(h),.serial=c->serial,.stream=c->stream,
        .frame=c->frame,.chunk=c->chunk,.queue_completion=c->queue_completion,.flags=FFSC_SOURCE_READY|
        (c->frame_begin?FFSC_FRAME_BEGIN:0)|(c->frame_end?FFSC_FRAME_END:0),.record_count=(uint32_t)(c->records.length/sizeof(ffs_record)),
        .blob_count=(uint32_t)entries.count,.retirement_count=(uint32_t)c->retirements.count,.records_offset=sizeof(h),.blobs_offset=table,
        .retirements_offset=c->retirements.count?retirements_offset:0};
    const ffs_record *records=c->records.bytes;h.first_sequence=records[0].sequence;h.next_sequence=records[h.record_count-1].sequence+1;
    h.record_digest=UINT64_C(14695981039346656037);for(unsigned i=0;i<h.record_count;i++)h.record_digest=ffs_digest(h.record_digest,&records[i]);
    memcpy(wire+h.records_offset,c->records.bytes,c->records.length);
    for(NSUInteger i=0;i<c->retirements.count;i++){
        NSDictionary *r=c->retirements[i];ffsc_retirement entry={.root=[r[@"root"] unsignedLongLongValue],
            .generation=[r[@"generation"] unsignedLongLongValue],.last_use_serial=[r[@"last_use_serial"] unsignedLongLongValue],.kind=[r[@"kind"] unsignedIntValue]};
        memcpy(wire+retirements_offset+i*sizeof(entry),&entry,sizeof(entry));
    }
    NSMutableDictionary *in_packet=[NSMutableDictionary dictionary];
    size_t length=base;
    for(NSUInteger i=0;i<entries.count;i++){
        NSDictionary *entry=entries[i];FFSCSourceBlob *blob=entry[@"blob"];NSData *data=blob->data;NSString *name=entry[@"name"];
        ffsc_blob_entry b={.payload_id=[entry[@"payload"] unsignedLongLongValue],.length=blob->length};
        const char *leaf=name.UTF8String;size_t name_bytes=leaf?strlen(leaf):0;if(!name_bytes||name_bytes>=sizeof(b.name))return 0;
        b.name_bytes=(uint32_t)name_bytes;memcpy(b.name,leaf,name_bytes);NSString *hash=blob->hash;memcpy(b.sha256,blob->sha,32);
        /* Ordinary metadata stays inline; the separately resolved replay
         * template may use the acknowledged content cache. */
        b.flags=i?flags[i-1]:FFSC_BLOB_INLINE;
        if(b.flags==FFSC_BLOB_SHARED_SNAPSHOT)b.offset=blob->shared_offset;
        else if(b.flags&FFSC_BLOB_INLINE){
            if(!data||data.length!=blob->length)return 0;
            NSNumber *prior=in_packet[hash];
            if(prior)b.offset=prior.unsignedLongLongValue;
            else{
                size_t offset=(length+7)&~(size_t)7;
                if(offset>capacity||offset>FFSC_MAX_PACKET_BYTES||data.length>capacity-offset||
                   data.length>FFSC_MAX_PACKET_BYTES-offset)return 0;
                memset(wire+length,0,offset-length);b.offset=offset;
                memcpy(wire+offset,data.bytes,data.length);length=offset+data.length;
                in_packet[hash]=@(offset);c->profile.inline_bytes+=data.length;
            }
        }
        memcpy(wire+table+i*sizeof(b),&b,sizeof(b));
    }
    h.total_bytes=length;memcpy(wire,&h,sizeof(h));
    /* ffsc_publish validates the final copied packet before visibility. Avoid
     * running the same envelope/table validation twice in the source process. */
    c->profile.cache_misses++;c->profile.packet_ns+=profile_clock()-started;
    c->profile.wire_bytes=length;return length;
}
static void drain_receipts(void){
    ffsc_receipt r;enum ffsc_result result;
    while((result=ffsc_receive_receipt(endpoint,&r))==FFSC_OK){
        if(timeline_enabled)fprintf(stderr,"[native-source-timeline] clock=CLOCK_MONOTONIC event=receipt_observed at_ns=%llu stream=%llu frame=%llu chunk=%llu serial=%llu queue_completion=%llu kind=%u status=%u\n",
            (unsigned long long)profile_clock(),(unsigned long long)r.stream,(unsigned long long)r.frame,
            (unsigned long long)r.chunk,(unsigned long long)r.serial,(unsigned long long)r.queue_completion,r.kind,r.status);
        pthread_mutex_lock(&source_lock);
        if(r.kind==FFSC_ERROR||r.status==FFSC_FAILED)stop_source("native completion error");
        else if(completion_enabled){
            if(r.kind==FFSC_PRESENTED||r.kind==FFSC_OFFSCREEN_COMPLETED){if(!accept_presentation(&r))stop_source("native presentation identity, digest or completion mismatch");}
            else{enum ffcc_result accepted=ffcc_accept(completions,&r);
                if(accepted!=FFCC_READY&&accepted!=FFCC_PENDING)stop_source("native completion identity or query mismatch");}
        }
        pthread_cond_broadcast(&source_changed);int failed=stopped;pthread_mutex_unlock(&source_lock);if(failed)return;
    }
    if(result!=FFSC_EMPTY){pthread_mutex_lock(&source_lock);stop_source("receipt transport closed");pthread_mutex_unlock(&source_lock);}
}
static void drain_readbacks(void){
    if(!readback_endpoint)return;ffrb_record r;const void *bytes=NULL;size_t length=0;enum ffrb_result result;
    while((result=ffrb_peek(readback_endpoint,&r,&bytes,&length))==FFRB_OK){
        pthread_mutex_lock(&source_lock);FFSCCompletionBinding *binding=completion_bindings[@(r.queue_completion)];FFSCReadbackTarget *target=nil;
        if(binding&&binding->tracked&&binding->published&&!binding->source_completed){pthread_mutex_unlock(&source_lock);break;}
        if(binding&&binding->tracked&&binding->published&&binding->source_completed&&
           binding->packet.serial==r.serial&&binding->packet.stream==r.stream&&binding->packet.frame==r.frame&&binding->packet.chunk==r.chunk&&
           binding->packet.record_digest==r.record_digest&&binding->packet.queue_completion==r.queue_completion)
            for(FFSCReadbackTarget *candidate in binding->readbacks)if(candidate->expected.encoder==r.encoder&&candidate->expected.command==r.command){target=candidate;break;}
        int valid=!stopped&&target&&!target->delivered;
        if(valid){ffrb_record e=target->expected;
            valid=r.root==e.root&&r.generation==e.generation&&r.content_version==e.content_version&&r.offset==e.offset&&
                r.row_bytes==e.row_bytes&&r.row_length==e.row_length&&r.row_count==e.row_count&&r.length==e.length&&length==e.length;
        }
        uint64_t cpu_bytes=0;
        if(valid){uint64_t span=(r.row_count-1)*r.row_bytes+r.row_length;
            valid=r.offset<=target->buffer.length&&span<=target->buffer.length-r.offset;
            if(valid&&target->buffer.storageMode==MTLStorageModeShared){unsigned char *destination=target->buffer.contents;
                if(!destination)valid=0;
                else{for(uint64_t row=0;row<r.row_count;row++)memcpy(destination+r.offset+row*r.row_bytes,(const unsigned char *)bytes+row*r.row_length,(size_t)r.row_length);cpu_bytes=length;}
            }else if(valid&&target->buffer.storageMode!=MTLStorageModePrivate)valid=0;
        }
        if(valid&&ffrb_consume(readback_endpoint,r.sequence)==FFRB_OK){
            target->delivered=1;binding->returned++;native_readback_ranges++;native_readback_bytes+=length;native_readback_cpu_bytes+=cpu_bytes;
            if(native_readback_ranges==1||!(native_readback_ranges%64))fprintf(stderr,"[native-readback-applied] stream=%llu queue_completion=%llu chunk=%llu encoder=%u command=%u root=%llu generation=%llu version=%llu offset=%llu row_bytes=%llu row_length=%llu rows=%llu bytes=%llu cpu_bytes=%llu ranges=%llu\n",
                (unsigned long long)r.stream,(unsigned long long)r.queue_completion,(unsigned long long)r.chunk,r.encoder,r.command,
                (unsigned long long)r.root,(unsigned long long)r.generation,(unsigned long long)r.content_version,(unsigned long long)r.offset,
                (unsigned long long)r.row_bytes,(unsigned long long)r.row_length,(unsigned long long)r.row_count,(unsigned long long)length,
                (unsigned long long)cpu_bytes,(unsigned long long)native_readback_ranges);
            pthread_cond_broadcast(&source_changed);
        }else stop_source("native readback identity, shape, bytes or backing mismatch");
        int failed=stopped;pthread_mutex_unlock(&source_lock);if(failed)return;
    }
    if(result!=FFRB_EMPTY){pthread_mutex_lock(&source_lock);stop_source("readback transport stopped or malformed");pthread_mutex_unlock(&source_lock);}
}
/* source_lock held. Transfer each payload's guard pins before its chunk or
 * blobs can be destroyed; the returned array must be released after unlocking. */
static int defer_texture_budget_owners(FFSCSourcePayload *p,NSMutableArray **deferred){
    if(!p->texture_budget_owners)return 1;
    if(!*deferred)*deferred=[[NSMutableArray alloc]init];
    if(!*deferred)return 0;
    [*deferred addObject:p->texture_budget_owners];
    [p->texture_budget_owners release];p->texture_budget_owners=nil;return 1;
}
static void *pump(void *unused){(void)unused;
    for(;;){@autoreleasepool{
        drain_readbacks();drain_receipts();pthread_mutex_lock(&source_lock);
        if(stopped){pthread_mutex_unlock(&source_lock);break;}
        uint64_t consumed=ffsc_transport_consumed(endpoint),released=0;
        NSMutableArray *retired_owners=nil;int retire_failed=0;
        while(chunks.count&&((FFSCSourceChunk *)chunks[0])->published&&((FFSCSourceChunk *)chunks[0])->serial<=consumed){
            FFSCSourceChunk *c=chunks[0];uint64_t bytes=c->bytes;
            timeline_chunk("transport_consumed_observed",c,profile_clock());
            for(FFSCSourcePayload *p in c->payloads.allValues){
                if(!defer_texture_budget_owners(p,&retired_owners)){
                    retire_failed=1;stop_source("cannot defer texture owners");break;}
                [tokens removeObjectForKey:@(p->token)];
            }
            if(retire_failed)break;
            [chunks removeObjectAtIndex:0];released+=bytes;pthread_cond_broadcast(&source_changed);
        }
        FFSCSourceChunk *candidate=nil;
        for(FFSCSourceChunk *c in chunks)if(!c->published){if(ready(c))candidate=[c retain];break;}
        int poll_ms=captured_started?1:5;
        uint64_t observed_generation=source_progress_generation;
        pthread_mutex_unlock(&source_lock);
        /* Last memo pin may take memo_lock and the frame guard. */
        [retired_owners release];
        if(released)fullframe_frame_stream_release_storage(released);
        if(retire_failed){[candidate release];break;}
        int published=0;
        if(candidate){
            void *target=NULL;size_t capacity=0;enum ffsc_result result=ffsc_reserve(endpoint,&target,&capacity);
            if(result==FFSC_OK){
                size_t wire_length=packet(candidate,target,capacity);pthread_mutex_lock(&source_lock);
                if(wire_length&&!track_completion(candidate,target,wire_length)){wire_length=0;stop_source("invalid source query expectations or registry capacity");}
                pthread_mutex_unlock(&source_lock);
                if(!wire_length){ffsc_abort(endpoint);result=FFSC_TOO_LARGE;}
                else{uint64_t publish_start=profile_clock();candidate->publish_begin_ns=publish_start;
#ifdef BEDROCK_TEST_SOURCE_COMPLETION
                    fullframe_test_before_publish(candidate->serial);
#endif
                    pthread_mutex_lock(&publish_lock);result=ffsc_publish(endpoint,wire_length);pthread_mutex_unlock(&publish_lock);
                    candidate->published_ns=profile_clock();candidate->profile.publish_ns+=candidate->published_ns-publish_start;}
                pthread_mutex_lock(&source_lock);
                if(result==FFSC_OK){candidate->published=1;published=1;
                    timeline_chunk("published",candidate,candidate->published_ns);if(candidate->completion)candidate->completion->published=1;
                    uint64_t commit=profile_clock();remove_published_retirements(candidate->retirements);
                    candidate->profile.retirement_commit_ns+=profile_clock()-commit;
                    profile_published(candidate);pthread_cond_broadcast(&source_changed);}
                else stop_source("chunk packet rejected/oversize");pthread_mutex_unlock(&source_lock);
            }else if(result!=FFSC_BACKPRESSURE){pthread_mutex_lock(&source_lock);stop_source("chunk transport closed");pthread_mutex_unlock(&source_lock);}
            [candidate release];
        }
        /* A successful publish may leave another sealed chunk ready. Recheck
         * receipts, retirements and admission before sleeping for peer work. */
        if(published)continue;
        /* Local completion wakes the pump immediately; remote receipts and
         * credits still require bounded polling. Generation closes the gap
         * between selecting a candidate and entering the condition wait. */
        enum ffsc_result waiting=ffsc_wait(endpoint,0);
        if(waiting!=FFSC_OK&&waiting!=FFSC_EMPTY){pthread_mutex_lock(&source_lock);stop_source("peer stopped or died");pthread_mutex_unlock(&source_lock);}
        else if(waiting==FFSC_EMPTY){
            pthread_mutex_lock(&source_lock);
            if(!stopped&&observed_generation==source_progress_generation){
                struct timespec interval={.tv_sec=0,.tv_nsec=(long)poll_ms*1000000};
                int error=pthread_cond_timedwait_relative_np(&source_changed,&source_lock,&interval);
                if(error&&error!=ETIMEDOUT)stop_source("source pump wait failed");
            }
            pthread_mutex_unlock(&source_lock);
        }
    }}return NULL;
}
static int initialize_source(void){
    if(initialized)return !stopped;initialized=1;
    const char *timeline=getenv("BEDROCK_NATIVE_SOURCE_TIMELINE");timeline_enabled=timeline&&!strcmp(timeline,"1");
    const char *depth=getenv(FFSC_SOURCE_PIPELINE_DEPTH_ENV);
    if(depth){
        if(strcmp(depth,"8")){stop_source("unsupported source pipeline depth");return 0;}
        source_staging_chunks=FFSC_SOURCE_STAGING_CHUNKS_EXPERIMENT;
    }
    const char *headroom=getenv(FFSC_SOURCE_HEADROOM_ENV);
    if(headroom){
        if(strcmp(headroom,"128")){stop_source("unsupported source admission headroom");return 0;}
        source_capture_headroom=FFSC_SOURCE_CAPTURE_HEADROOM_EXPERIMENT;
    }
    fprintf(stderr,"[native-source-admission] headroom_mib=%llu staging_chunks=%u hard_frame_mib=512\n",
        (unsigned long long)(source_capture_headroom/(1024*1024)),source_staging_chunks);
    const char *receiver=getenv(FFSC_RECEIVER_DIGEST_ENV);receiver_digest_enabled=receiver&&!strcmp(receiver,"1");
    const char *path=getenv(FFSC_ENDPOINT_ENV);int fd=path?open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC):-1;
    enum ffsc_result result=fd>=0?ffsc_attach(fd,FFSC_PRODUCER,&endpoint):FFSC_INVALID;if(fd>=0)close(fd);
    if(result!=FFSC_OK){stop_source("cannot attach private endpoint");return 0;}
    const char *arena_path=getenv("BEDROCK_NATIVE_SNAPSHOT_ARENA");
    if(arena_path){
        int arena_fd=arena_path[0]=='/'&&receiver_digest_enabled?open(arena_path,O_RDWR|O_NOFOLLOW|O_CLOEXEC):-1;
        ffsa_result arena_result=arena_fd>=0?ffsa_attach(arena_fd,FFSA_SOURCE,&snapshot_arena):FFSA_INVALID;
        if(arena_fd>=0)close(arena_fd);
        if(arena_result!=FFSA_OK){stop_source("cannot attach private snapshot arena");return 0;}
        if(!fullframe_frame_stream_reserve_snapshot_arena(FFSA_SLOT_COUNT*FFSA_MAX_SLOT_BYTES)){
            stop_source("snapshot arena exceeds source frame budget");return 0;}
    }
    if(atexit(close_source_on_exit)){stop_source("cannot register orderly source shutdown");return 0;}
    const char *frame_age=getenv("BEDROCK_NATIVE_FRAME_AGE");
    if(frame_age&&!strcmp(frame_age,"1")&&
       !ff_source_frame_samples_open(&source_frame_samples,getenv("BEDROCK_FULLFRAME_FRAME_STREAM_DIRECTORY"),
                                     getenv("BEDROCK_NATIVE_FRAME_AGE_RUN_ID")))
        fprintf(stderr,"[native-source-frame-samples] cannot initialize observation\n");
    chunks=[[NSMutableArray alloc]init];tokens=[[NSMutableDictionary alloc]init];cache=[[NSMutableDictionary alloc]init];
    seen_roots=[[NSMutableDictionary alloc]init];seen_root_generations=[[NSMutableDictionary alloc]init];
    pending_retirements=[[NSMutableArray alloc]init];collector_retirements=[[NSMutableArray alloc]init];
    const char *option=getenv(FFSC_COMPLETION_ENV);completion_enabled=option&&!strcmp(option,"1");
    if(completion_enabled){completions=ffcc_create();completion_bindings=[[NSMutableDictionary alloc]init];
        if(!completions||!completion_bindings){stop_source("cannot allocate bounded completion registry");return 0;}
        const char *path=getenv(FFRB_ENDPOINT_ENV);
        if(path&&path[0]){int fd=path[0]=='/'?open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC):-1;
            enum ffrb_result result=fd>=0?ffrb_attach(fd,FFRB_SOURCE,&readback_endpoint):FFRB_INVALID;if(fd>=0)close(fd);
            if(result!=FFRB_OK){stop_source("cannot attach bounded readback endpoint");return 0;}}
    }
    pthread_t thread;if(pthread_create(&thread,NULL,pump,NULL)){stop_source("cannot create completion pump");return 0;}pthread_detach(thread);return 1;
}
uint32_t fullframe_chunk_stream_record(const ffs_record *r,uint64_t bytes){@autoreleasepool{
    if(!r||bytes!=sizeof(*r))return FFS_EMIT_REJECT;uint64_t started=profile_clock();pthread_mutex_lock(&source_lock);
    if(!initialize_source()||stopped){pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}
    if(r->kind==FFS_FRAME_BEGIN){
        if(!ffsc_is_armed(endpoint)){pthread_mutex_unlock(&source_lock);return FFS_EMIT_IDLE;}
        captured_started=1;
        if(collector&&!collector_ended){stop_source("frame overlap");pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}
        if(collector){if(!ffs_begin_next_frame(collector,r->sequence)){stop_source("invalid next frame boundary");pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}}
        else collector=ffs_create(r->stream,r->sequence,FFS_MAX_RECORDS);collector_ended=0;
        frame_prefix=*r;has_prefix=1;
    }
    if(r->kind==FFS_CHUNK_BEGIN){
        /* Publication may already have consumed the wire notices. The collector
         * owns a separate queue, drained only between complete chunks. */
        if(!retire_collector_generations()){
            rejected_record(r,"collector-retirement");stop_source("invalid collector retirement");
            pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;
        }
        if(admission_serial||!next_serial){stop_source("overlapping or exhausted chunk admission");pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}
        admission_serial=next_serial;admission_markers=[[NSMutableSet alloc]init];
        if(!admission_markers){admission_serial=0;stop_source("cannot allocate admission markers");pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}
        uint64_t count_wait=0,budget_wait=0,cuts_wait=0;
        while(!stopped){
            /* A failed older payload may prevent every count credit. Check
             * failure even with full staging, outside source_lock. Older work
             * was committed by the sole DXMT encode thread before this boundary. */
            uint64_t generation=source_progress_generation;
            pthread_mutex_unlock(&source_lock);
            int admission=fullframe_frame_stream_admission_reasons(source_capture_headroom);
            pthread_mutex_lock(&source_lock);
            if(stopped)break;
            if(generation!=source_progress_generation)continue;
            if(admission<0){stop_source("source payload budget failed before chunk admission");break;}
            int reasons=admission|(chunks.count>=source_staging_chunks?FFSC_ADMISSION_COUNT:0);
            if(!reasons)break;
            struct timespec interval={.tv_sec=0,.tv_nsec=10000000};
            uint64_t wait_start=profile_clock();int error=pthread_cond_timedwait_relative_np(&source_changed,&source_lock,&interval);
            uint64_t waited=profile_clock()-wait_start;
            if(reasons&FFSC_ADMISSION_COUNT)count_wait+=waited;
            if(reasons&FFSC_ADMISSION_BUDGET)budget_wait+=waited;
            if(reasons&FFSC_ADMISSION_CUTS)cuts_wait+=waited;
            if(error&&error!=ETIMEDOUT){stop_source("source staging admission wait failed");break;}
        }
        if(stopped){[admission_markers release];admission_markers=nil;admission_serial=0;
            pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;}
        /* Allocation destructors can queue notices while admission releases the
         * lock. Apply those between chunks before accepting any new references. */
        if(!retire_collector_generations()){
            rejected_record(r,"collector-retirement");stop_source("invalid collector retirement after admission");
            [admission_markers release];admission_markers=nil;admission_serial=0;
            pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;
        }
        current=[[[FFSCSourceChunk alloc]init]autorelease];current->serial=next_serial++;current->stream=r->stream;current->frame=r->frame;
        current->profile.staging_wait_ns=profile_clock()-started;
        current->profile.staging_count_ns=count_wait;current->profile.staging_budget_ns=budget_wait;current->profile.staging_cuts_ns=cuts_wait;
        current->born_ns=started;current->admitted_ns=profile_clock();
        current->chunk=r->chunk;current->queue_completion=r->data[3];current->records=[[NSMutableData alloc]init];
        current->payloads=[[NSMutableDictionary alloc]init];current->dependencies=[[NSMutableArray alloc]init];
        current->resident_blobs=[[NSMutableDictionary alloc]init];current->retired_during_chunk=admission_markers;
        admission_markers=nil;admission_serial=0;
        current->retirements=[[NSMutableArray alloc]init];
        if(has_prefix){current->frame_begin=1;[current->records appendBytes:&frame_prefix length:sizeof(frame_prefix)];has_prefix=0;}
        [chunks addObject:current];
    }
    /* The source cannot infer future uses from a destruction notification.
     * Reject an observed same-chunk reuse before a stale notice is visible.
     * This does not prove safety of later chunks or notices outside this chunk. */
    if(r->kind==FFS_RESOURCE&&current_chunk_open()&&current->retired_during_chunk.count){
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)r->data[0],
            (unsigned long long)r->data[1],(unsigned long long)r->data[3]];
        NSString *wildcard=[NSString stringWithFormat:@"%llu:%llu:0",(unsigned long long)r->data[0],(unsigned long long)r->data[1]];
        if([current->retired_during_chunk containsObject:key]||[current->retired_during_chunk containsObject:wildcard]){
            rejected_record(r,"same-chunk-use-after-retirement");stop_source("same-chunk use after retirement");
            pthread_mutex_unlock(&source_lock);return FFS_EMIT_REJECT;
        }
    }
    int ok=collector&&ffs_consume(collector,r);const char *failure=ok?NULL:"collector";
    if(ok&&r->kind!=FFS_FRAME_BEGIN){
        if(!current||current->stream!=r->stream||current->frame!=r->frame||current->chunk!=r->chunk){ok=0;failure="source-chunk-identity";}
        else [current->records appendBytes:r length:sizeof(*r)];
    }
    if(ok&&(r->flags&FFS_UNSUPPORTED||r->kind==FFS_RESOURCE_UNRESOLVED||r->kind==FFS_REJECT)){ok=0;failure="unsupported-source-record";}
    if(ok&&r->kind==FFS_DEPENDENCY&&(r->flags&FFS_EXTERNAL)){
        NSDictionary *dependency=@{@"domain":@(r->data[0]),@"id":@(r->data[1]),@"value":@(r->data[2]),@"payload_id":@(r->data[5])};
        if(![current->dependencies containsObject:dependency])[current->dependencies addObject:dependency];
    }
    if(ok&&r->kind==FFS_RESOURCE){
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)r->data[0],(unsigned long long)r->data[1],(unsigned long long)r->data[3]];
        if(!seen_roots[key]&&seen_roots.count==FFS_MAX_GENERATIONS){ok=0;failure="source-roots-limit";}
        else{
            if(!seen_roots[key]){NSString *physical=physical_root_key(r->data[0],r->data[1]);
                NSMutableSet *generations=seen_root_generations[physical];
                if(!generations){generations=[NSMutableSet set];seen_root_generations[physical]=generations;}[generations addObject:key];}
            NSDictionary *previous=seen_roots[key];
            NSArray *nativeRange=previous[@"native_range"]?:@[];
            if([previous[@"output_version"] unsignedLongLongValue]!=r->data[4])nativeRange=@[];
            if(r->data[0]==FFS_BUFFER&&(r->flags&FFS_WRITE)&&r->data[6]&&r->data[5]<=UINT64_MAX-r->data[6]){
                uint64_t lo=r->data[5],hi=lo+r->data[6];
                if(nativeRange.count==2){uint64_t oldLo=[nativeRange[0] unsignedLongLongValue],oldHi=[nativeRange[1] unsignedLongLongValue];
                    if(lo<=oldHi&&oldLo<=hi){lo=MIN(lo,oldLo);hi=MAX(hi,oldHi);}
                    else if(oldHi-oldLo>hi-lo){lo=oldLo;hi=oldHi;}}
                nativeRange=@[@(lo),@(hi)];
            }
            uint64_t validated=MAX([seen_roots[key][@"validated_version"]unsignedLongLongValue],r->data[8]);
            seen_roots[key]=@{@"kind":@(r->data[0]),@"root":@(r->data[1]),@"generation":@(r->data[3]),@"last_use_serial":@(current->serial),
                @"view":@(r->data[2]),@"offset":@(r->data[5]),@"length":@(r->data[6]),@"input_version":@(r->data[4]),@"output_version":@(r->data[8]),@"validated_version":@(validated),@"native_range":nativeRange,@"native_texture":@((r->data[0]==FFS_TEXTURE)&&((r->flags&FFS_WRITE)||([previous[@"native_texture"] boolValue]&&[previous[@"output_version"] unsignedLongLongValue]==r->data[4])))};
            if(r->data[0]==FFS_BUFFER&&(r->data[1]&UINT64_C(0x8000000000000000))){
                if(!current->synthetic_roots)current->synthetic_roots=[[NSMutableSet alloc]init];
                [current->synthetic_roots addObject:key];
            }
            FFSCSourcePayload *payload=current->payloads[@(r->data[7])];
            if(r->data[0]==FFS_TEXTURE&&payload&&payload->texture_proofs.count&&(r->flags&FFS_READ)&&!(r->flags&FFS_WRITE)){
                FFSCSourceIdentity *proof=payload->texture_proofs[texture_record_key(r->data[1],r->data[3],r->data[2],r->data[4])];
                if(proof)proof->private_accepted=1;}
        }
    }
    if(ok&&r->kind==FFS_CHUNK_END){
        current->sealed=1;current->sealed_ns=profile_clock();source_progress_generation++;pthread_cond_broadcast(&source_changed);
        if(!retire_chunk_synthetic(current)){ok=0;failure="source-retirements-limit";}
        if(ok&&!retire_collector_generations()){ok=0;failure="collector-retirement";}
        if(ok&&!ffs_discard_consumed_chunks(collector)){ok=0;failure="collector-discard";}
    }
    if(ok&&r->kind==FFS_FRAME_END){current->frame_end=1;collector_ended=1;}
    if(!ok){rejected_record(r,failure?:"unknown");stop_source("invalid or unsupported chunk ledger");}
    if(ok&&r->kind==FFS_FRAME_BEGIN)
        ff_source_frame_samples_record(&source_frame_samples,r->stream,r->frame,r->chunk,started);
    if(ok&&r->kind!=FFS_FRAME_BEGIN&&current)current->profile.record_ns+=profile_clock()-started;
    pthread_mutex_unlock(&source_lock);return ok?FFS_EMIT_ACCEPT:FFS_EMIT_REJECT;
}}
int fullframe_chunk_payload_open(const ffs_producer_context *c,uint64_t payload){@autoreleasepool{
    pthread_mutex_lock(&source_lock);int token=-1;
    if(!stopped&&c&&current&&current->chunk==c->chunk&&current->stream==c->stream&&current->frame==c->frame&&
       current->payloads.count<128&&next_token<INT_MAX){
        FFSCSourcePayload *p=[[[FFSCSourcePayload alloc]init]autorelease];p->chunk=current;p->payload=payload;p->token=-next_token++;
        p->encoder=c->encoder;p->category=c->category;
        p->blobs=[[NSMutableDictionary alloc]init];p->segments=[[NSMutableDictionary alloc]init];p->original_names=[[NSMutableSet alloc]init];
        p->identities=[[NSMutableDictionary alloc]init];p->retained_snapshots=[[NSMutableDictionary alloc]init];
        if(completion_enabled&&(!current->completion||!source_query_context(p,c)))stop_source("invalid source completion query context");
        else{tokens[@(p->token)]=p;current->payloads[@(payload)]=p;token=p->token;}
    }
    pthread_mutex_unlock(&source_lock);return token;
}}
int fullframe_chunk_payload_retained_limit(int token,uint64_t limit){
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    int ok=!stopped&&p&&!p->kind&&!p->retained_limit&&limit&&limit<=UINT64_C(512)*1024*1024;
    if(ok)p->retained_limit=limit;
    pthread_mutex_unlock(&source_lock);return ok;
}
id<MTLBuffer> fullframe_chunk_snapshot_allocate(int token,id<MTLDevice> device,size_t length,ffsa_extent_desc *out){
    if(out)memset(out,0,sizeof(*out));
    if(!out||!snapshot_arena||!device||length<65536u||length>FFSA_MAX_SLOT_BYTES)return nil;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    FFSCSourceChunk *c=p?p->chunk:nil;
    if(stopped||!p||p->kind||!c||c->shared_sealed){pthread_mutex_unlock(&source_lock);return nil;}
    if(!c->shared_claimed){
        ffsa_result claimed=ffsa_claim(snapshot_arena,c->serial,&c->shared_lease);
        if(claimed==FFSA_BACKPRESSURE){c->profile.shared_slot_full_bytes+=length;
            c->profile.shared_slot_full_count++;pthread_mutex_unlock(&source_lock);return nil;}
        if(claimed!=FFSA_OK){stop_source("snapshot arena claim failed");pthread_mutex_unlock(&source_lock);return nil;}
        c->shared_claimed=1;
    }
    void *bytes=NULL;ffsa_extent_desc extent={0};
    ffsa_result allocated=ffsa_allocate(snapshot_arena,c->shared_lease,length,&extent,&bytes);
    if(allocated==FFSA_BACKPRESSURE){
        c->profile.shared_slot_full_bytes+=length;c->profile.shared_slot_full_count++;
        if(!c->shared_view_created){
            if(ffsa_source_abandon(snapshot_arena,c->shared_lease)!=FFSA_OK)stop_source("snapshot arena abandon failed");
            c->shared_claimed=0;memset(&c->shared_lease,0,sizeof(c->shared_lease));
        }
        pthread_mutex_unlock(&source_lock);return nil;
    }
    if(allocated!=FFSA_OK||!bytes){stop_source("snapshot arena allocation failed");pthread_mutex_unlock(&source_lock);return nil;}
    /* The arena core zeros the rounded padding before returning this extent. */
    void *view_owner=(void *)[c retain];
    id<MTLBuffer> buffer=[device newBufferWithBytesNoCopy:bytes length:(NSUInteger)extent.allocated_length
        options:MTLResourceStorageModeShared deallocator:^(void *storage,NSUInteger size){
            (void)storage;(void)size;FFSCSourceChunk *owner=(FFSCSourceChunk *)view_owner;
            pthread_mutex_lock(&source_lock);if(owner->shared_views_live)owner->shared_views_live--;
            if(owner->shared_unexported&&owner->source_completed&&!owner->shared_views_live&&
               owner->shared_claimed&&!owner->shared_blob_count){
                if(ffsa_source_abandon(snapshot_arena,owner->shared_lease)==FFSA_OK)owner->shared_claimed=0;
            }
            pthread_mutex_unlock(&source_lock);[owner release];}];
    if(!buffer){[(FFSCSourceChunk *)view_owner release];
        if(!c->shared_view_created){
            if(ffsa_source_abandon(snapshot_arena,c->shared_lease)!=FFSA_OK)stop_source("snapshot arena abandon failed");
            c->shared_claimed=0;memset(&c->shared_lease,0,sizeof(c->shared_lease));
        }
        pthread_mutex_unlock(&source_lock);return nil;}
    if(buffer.contents!=bytes){stop_source("snapshot arena Metal view mismatch");pthread_mutex_unlock(&source_lock);[buffer release];return nil;}
    c->shared_view_created=1;c->shared_views_live++;
    c->profile.shared_alloc_bytes+=extent.allocated_length;c->profile.shared_alloc_count++;
    *out=extent;pthread_mutex_unlock(&source_lock);return buffer;
}
int fullframe_chunk_blob_identity(int token,const char *name,uint64_t kind,uint64_t root,uint64_t view,uint64_t offset,uint64_t length){@autoreleasepool{
    if(!name||!name[0]||strlen(name)>=FFSC_BLOB_NAME_BYTES||!root||!length||offset>UINT64_MAX-length||
       (kind!=FFS_BUFFER&&kind!=FFS_TEXTURE))return 0;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    int ok=!stopped&&p&&!p->kind&&!p->identities[@(name)]&&![p->original_names containsObject:@(name)];
    if(ok){FFSCSourceIdentity *identity=[[[FFSCSourceIdentity alloc]init]autorelease];
        identity->kind=kind;identity->root=root;identity->view=kind==FFS_TEXTURE?view:0;identity->offset=offset;identity->length=length;
        p->identities[@(name)]=identity;}
    pthread_mutex_unlock(&source_lock);return ok;
}}
static NSString *texture_record_key(uint64_t root,uint64_t generation,uint64_t view,uint64_t version){
    return [NSString stringWithFormat:@"%llu:%llu:%llu:%llu",(unsigned long long)root,(unsigned long long)generation,
        (unsigned long long)view,(unsigned long long)version];
}
static int private_texture_eligible(id<MTLTexture> texture){
    /* Private shared/imported textures exist in DXMT. Check every backing view,
     * not just storage mode, and exclude all externally writable/aliased forms. */
    for(unsigned depth=0;texture;depth++){
        if(depth==16||![texture conformsToProtocol:@protocol(MTLTexture)]||texture.storageMode!=MTLStorageModePrivate||
           texture.shareable||texture.iosurface||texture.buffer||texture.heap||texture.remoteStorageTexture)return 0;
        texture=texture.parentTexture;
    }
    return 1;
}
static NSString *private_texture_key(uint64_t stream,const ffs_producer_resource *r,const ff_texture_snapshot *s){
    if(!s||!s->length||s->plane_count>FF_TEXTURE_PLANE_LIMIT)return nil;
    uint64_t words[18+5*FF_TEXTURE_PLANE_LIMIT]={stream,r->root,r->allocation_generation,r->input_content_version,r->view,
        s->format,s->texture_type,s->width,s->height,s->mip_count,s->array_length,s->plane_count,s->has_swizzle,
        s->swizzle[0],s->swizzle[1],s->swizzle[2],s->swizzle[3],s->length};
    size_t count=18;
    for(size_t i=0;i<s->plane_count;i++){ff_texture_plane p=s->planes[i];
        if(!p.length||p.offset>s->length||p.length>s->length-p.offset)return nil;
        words[count++]=p.mip;words[count++]=p.slice;words[count++]=p.offset;words[count++]=p.row_bytes;words[count++]=p.length;}
    unsigned char sha[32];CC_SHA256(words,(CC_LONG)(count*sizeof(*words)),sha);
    return [@"private-texture:" stringByAppendingString:digest_name(sha)];
}
id fullframe_chunk_private_texture(int token,const char *name,const ffs_producer_resource *r,const ff_texture_snapshot *s){@autoreleasepool{
    if(token>=-1||!name||!r||r->kind!=FFS_TEXTURE||r->role!=FFS_ROLE_SHADER||!(r->flags&FFS_READ)||
       (r->flags&FFS_WRITE)||!r->handle||!r->root||!r->view||!r->allocation_generation||!r->input_content_version||
       r->input_content_version!=r->output_content_version||!s)return nil;
    id<MTLTexture> texture=(id<MTLTexture>)r->handle;
    if(!private_texture_eligible(texture)||texture.pixelFormat!=s->format||texture.textureType!=s->texture_type||
       texture.width!=s->width||texture.height!=s->height||texture.mipmapLevelCount!=s->mip_count||texture.arrayLength!=s->array_length)return nil;
    NSString *rootKey=[NSString stringWithFormat:@"%u:%llu:%llu",FFS_TEXTURE,(unsigned long long)r->root,(unsigned long long)r->allocation_generation];
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];FFSCSourceIdentity *identity=p?p->identities[@(name)]:nil;
    int allowed=!stopped&&p&&!p->kind&&p->category==FFS_RENDER&&identity&&identity->kind==FFS_TEXTURE&&
        identity->root==r->root&&identity->view==r->view&&identity->length==s->length&&!identity->private_key;
    NSString *key=allowed?[private_texture_key(p->chunk->stream,r,s)copy]:nil;
    int observed=allowed&&[seen_roots[rootKey][@"validated_version"]unsignedLongLongValue]==r->input_content_version;
    if(key){identity->private_key=[key copy];if(!p->texture_proofs)p->texture_proofs=[[NSMutableDictionary alloc]init];
        p->texture_proofs[texture_record_key(r->root,r->allocation_generation,r->view,r->input_content_version)]=identity;}
    pthread_mutex_unlock(&source_lock);if(!key)return nil;
    FFSCPrivateTexture *owner=observed?memo_pin_texture(key):nil;
    pthread_mutex_lock(&source_lock);p=tokens[@(token)];identity=p?p->identities[@(name)]:nil;
    int currentProof=!stopped&&p&&!p->kind&&identity&&[identity->private_key isEqual:key];
    if(currentProof){
        if(owner&&owner.length==s->length){identity->private_digest=[owner->sample->hash copy];p->chunk->profile.private_texture_hits++;}
        else p->chunk->profile.private_texture_misses++;
    }
    pthread_mutex_unlock(&source_lock);[key release];
    if(!currentProof||(owner&&owner.length!=s->length)){[owner release];return nil;}return owner;
}}
int fullframe_chunk_retain_texture_budget(int token,const char *name,id object){
    if(!name||![object isKindOfClass:[FFSCPrivateTexture class]])return 0;
    FFSCPrivateTexture *owner=object;FFSCSourceBlob *sample=owner->sample;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    FFSCSourceIdentity *identity=p?p->identities[@(name)]:nil;
    int ok=!stopped&&p&&!p->kind&&identity&&identity->private_digest&&sample&&
        [identity->private_digest isEqual:sample->hash]&&identity->length==sample->length&&
        sample->data.length==sample->length&&sample->data.bytes&&
        !p->texture_budget_owners[@(name)];
    if(ok){if(!p->texture_budget_owners)p->texture_budget_owners=[[NSMutableDictionary alloc]init];
        if(p->texture_budget_owners)p->texture_budget_owners[@(name)]=owner;else ok=0;}
    pthread_mutex_unlock(&source_lock);return ok;
}
void fullframe_chunk_release_texture_budget(int token){
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    /* A partially written payload may have blobs retaining memo owners. Keep
     * this dictionary until the pump defers it outside source_lock; otherwise
     * destruction of such a blob under source_lock could take memo_lock. */
    NSMutableDictionary *owners=p&&!p->blobs.count?p->texture_budget_owners:nil;
    if(owners)p->texture_budget_owners=nil;pthread_mutex_unlock(&source_lock);
    [owners release];
}
static NSString *stable_hint(FFSCSourceIdentity *identity,size_t offset,size_t length){
    if(!identity)return nil;
    return [NSString stringWithFormat:@"resource:%llu:%llu:%llu:%llu:%zu",(unsigned long long)identity->kind,
        (unsigned long long)identity->root,(unsigned long long)identity->view,(unsigned long long)(identity->offset+offset),length];
}
static int blob_write_leaf(int token,const char *name,const void *bytes,size_t length,NSString *identity_hint,
    FFSCSourceBlob *proven,NSString *privateKey,id<MTLBuffer> snapshot){@autoreleasepool{
    if(!name||!bytes||!length||length>FFSC_MAX_PACKET_BYTES)return 0;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    if(stopped||!p||p->kind||p->blobs[@(name)]){pthread_mutex_unlock(&source_lock);return 0;}[p retain];FFSCSourceChunk *owner=[p->chunk retain];pthread_mutex_unlock(&source_lock);
    FFSCSourceBlob *blob=[[[FFSCSourceBlob alloc]init]autorelease];blob->length=length;
    size_t name_length=strlen(name);int metadata=(name_length>=5&&!strcmp(name+name_length-5,".json")&&strcmp(name,"replay-template.json"))||
        !strcmp(name,"draw-resource-cut.bin")||!strcmp(name,"bindings.bin")||
        (name_length>=5&&!strncmp(name,"cut-buffer-",11)&&!strcmp(name+name_length-5,".nref"));
    blob->receiver_digest=receiver_digest_enabled&&ffsc_receiver_digest_name(name)&&!proven&&!privateKey;
    NSString *hint=metadata||blob->receiver_digest?nil:(identity_hint?:[NSString stringWithFormat:@"%u:%u:%zu:%s",p->category,p->encoder,length,name]);
    FFSCSourceBlob *sample=proven?[proven retain]:(hint?memo_find(hint):nil);uint64_t compare_ns=0,hash_ns=0;
    int equal=proven!=nil,compared=!proven&&sample&&sample->length==length&&sample->data.length==length;if(compared){
        uint64_t start=profile_clock();equal=!memcmp(bytes,sample->data.bytes,length);compare_ns=profile_clock()-start;}
    if(blob->receiver_digest){
        /* A process-local owner key, never a content digest or a cache key.
         * The completed cut snapshot may own these immutable bytes directly. */
        blob->hash=[[NSString stringWithFormat:@"receiver:%llu:%llu:%s",(unsigned long long)owner->serial,
            (unsigned long long)p->payload,name]copy];
    }else if(equal){memcpy(blob->sha,sample->sha,sizeof(blob->sha));blob->hash=[sample->hash copy];}
    else{uint64_t start=profile_clock();CC_SHA256(bytes,(CC_LONG)length,blob->sha);blob->hash=[digest_name(blob->sha)copy];hash_ns=profile_clock()-start;}
    /* Even same-generation WRITE_NO_OVERWRITE data is compared in full (or
     * freshly hashed). Only a native-acknowledged digest can omit wire bytes. */
    pthread_mutex_lock(&source_lock);FFSCSourceCacheEntry *known=cache[blob->hash];
    int cached=!metadata&&!blob->receiver_digest&&known&&known->length==length&&known->serial<=ffsc_transport_consumed(endpoint);
    /* Protect the interval before this blob appears in its chunk's dictionary.
     * A packet plan on another thread cannot invalidate omitted immutable data. */
    if(cached)known->writer_pins++;
    FFSCSourceBlob *prior=owner->resident_blobs[blob->hash];
    if(!cached&&prior&&prior->length==length)blob->data=[prior->data retain];pthread_mutex_unlock(&source_lock);
    uint64_t clone_start=profile_clock(),clone_bytes=0;
    if(!cached&&!blob->data){
        if(equal)blob->data=[sample->data retain];
        else if(snapshot&&blob->receiver_digest){
            blob->snapshot_owner=[snapshot retain];fullframe_stage_pool_retain(snapshot);
            blob->data=[[NSData alloc]initWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];}
        else{blob->data=[[NSData alloc]initWithBytes:bytes length:length];clone_bytes=blob->data.length;}}
    uint64_t clone_ns=profile_clock()-clone_start;
    pthread_mutex_lock(&source_lock);int ok=0;prior=owner->resident_blobs[blob->hash];
    FFSCPrivateTexture *budget_owner=p->texture_budget_owners[@(name)];
    int memo_backed=proven&&budget_owner&&budget_owner->sample==proven&&
        blob->data==proven->data;
    if(memo_backed)blob->memo_owner=[budget_owner retain];
    uint64_t resident=cached||prior||blob->snapshot_owner||memo_backed?0:blob->data.length;
    p->chunk->profile.hash_ns+=hash_ns;p->chunk->profile.hash_bytes+=equal||blob->receiver_digest?0:length;
    p->chunk->profile.compare_ns+=compare_ns;p->chunk->profile.compare_bytes+=compared?length:0;
    p->chunk->profile.digest_reused_bytes+=equal?length:0;
    p->chunk->profile.stable_identity_bytes+=identity_hint?length:0;
    p->chunk->profile.private_texture_reused_bytes+=proven?length:0;
    p->chunk->profile.clone_ns+=clone_ns;p->chunk->profile.clone_bytes+=clone_bytes;
    if(!stopped&&tokens[@(token)]==p&&!p->kind&&!p->blobs[@(name)]&&(cached||blob->data)&&
       (!prior||prior->length==length)&&resident<=FFSC_MAX_PACKET_BYTES-p->chunk->bytes){
        if(!cached){if(prior){[blob->data release];blob->data=[prior->data retain];p->chunk->profile.interned_bytes+=length;}
            else owner->resident_blobs[blob->hash]=blob;}
        p->blobs[@(name)]=blob;p->resident_bytes+=resident;p->chunk->bytes+=resident;p->chunk->profile.logical_bytes+=length;ok=1;
    }else if(!stopped)fprintf(stderr,"[native-source-blob-reject] serial=%llu payload=%llu incoming=%llu resident=%llu retained=%llu cached=%d cap=%u\n",
        (unsigned long long)p->chunk->serial,(unsigned long long)p->payload,(unsigned long long)length,(unsigned long long)resident,
        (unsigned long long)p->chunk->bytes,cached,FFSC_MAX_PACKET_BYTES);
    if(cached)known->writer_pins--;pthread_mutex_unlock(&source_lock);
    /* Failure has no resident charge; drop borrowed data before its memo pin. */
    if(!ok){[blob->data release];blob->data=nil;}
    if(sample&&!proven)memo_unpin(sample);
    [sample release];
    if(ok&&hint){uint64_t memo_clone_ns=0,memo_clone_bytes=0;memo_store(hint,blob,bytes,&memo_clone_ns,&memo_clone_bytes);
        pthread_mutex_lock(&source_lock);owner->profile.clone_ns+=memo_clone_ns;owner->profile.clone_bytes+=memo_clone_bytes;pthread_mutex_unlock(&source_lock);}
    if(ok&&privateKey){uint64_t memo_clone_ns=0,memo_clone_bytes=0;memo_store(privateKey,blob,bytes,&memo_clone_ns,&memo_clone_bytes);
        pthread_mutex_lock(&source_lock);owner->profile.clone_ns+=memo_clone_ns;owner->profile.clone_bytes+=memo_clone_bytes;pthread_mutex_unlock(&source_lock);}
    [owner release];[p release];return ok;
}}
#define SOURCE_PAGE_BYTES 65536u
#define SOURCE_SEGMENT_MIN (4u*SOURCE_PAGE_BYTES)
static int chunk_blob_write(int token,const char *name,const void *bytes,size_t length,id<MTLBuffer> snapshot){@autoreleasepool{
    if(!name||!bytes||!length||length>FFSC_MAX_PACKET_BYTES||!strncmp(name,"page-",5))return 0;
    size_t names=strlen(name);if(!names||names>=FFSC_BLOB_NAME_BYTES)return 0;
    int segmented=length>=SOURCE_SEGMENT_MIN&&names>=4&&!strcmp(name+names-4,".bin")&&
        (!strncmp(name,"cut-buffer-",11)||!strncmp(name,"operation-buffer-",17));
    size_t pages=segmented?(length+SOURCE_PAGE_BYTES-1)/SOURCE_PAGE_BYTES:1;
    if(segmented&&(names+10>=FFSC_BLOB_NAME_BYTES||length>32u*1024u*1024u))return 0;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];FFSCSourceChunk *owner=p?p->chunk:nil;
    FFSCSourceIdentity *identity=p?p->identities[@(name)]:nil;
    NSString *privateKey=identity?[identity->private_key copy]:nil,*privateDigest=identity?[identity->private_digest copy]:nil;
    int allowed=!stopped&&p&&!p->kind&&![p->original_names containsObject:@(name)]&&
        (!identity||identity->length==length)&&
        (!privateKey||identity->private_accepted)&&(!privateDigest||!segmented)&&
        pages<=FFSC_MAX_BLOBS-1&&owner->blob_count<=FFSC_MAX_BLOBS-1-pages&&
        length<=UINT64_C(512)*1024*1024-owner->logical_bytes;
    /* The snapshot's whole Metal allocation remains live through transport.
     * Charge it once, before parallel pages can begin, including trimmed tail
     * and allocator rounding. A non-fitting owner keeps the copy path. */
    id<MTLBuffer> borrowed=nil;
    if(allowed&&snapshot&&receiver_digest_enabled&&p->retained_limit&&!privateKey&&!privateDigest&&
       ffsc_receiver_digest_name(name)&&snapshot.contents==bytes&&snapshot.length>=length&&
       snapshot.storageMode==MTLStorageModeShared){
        uint64_t allocation=MAX((uint64_t)snapshot.allocatedSize,(uint64_t)snapshot.length);
        NSValue *key=[NSValue valueWithPointer:(void *)snapshot];
        if(p->retained_snapshots[key])borrowed=snapshot;
        else if(allocation&&allocation<=FFSC_MAX_PACKET_BYTES-owner->bytes&&
                p->resident_bytes<=p->retained_limit&&allocation<=p->retained_limit-p->resident_bytes){
            p->retained_snapshots[key]=snapshot;p->resident_bytes+=allocation;owner->bytes+=allocation;borrowed=snapshot;
        }
    }
    if(allowed){[p retain];[owner retain];[p->original_names addObject:@(name)];owner->blob_count+=pages;owner->logical_bytes+=length;}
    pthread_mutex_unlock(&source_lock);if(!allowed){[privateKey release];[privateDigest release];return 0;}
    FFSCSourceBlob *proven=nil;
    if(privateDigest){pthread_mutex_lock(&memo_lock);FFSCSourceBlob *sample=memo_contents[privateDigest];
        if(sample&&sample->length==length&&sample->data.bytes==bytes&&sample->data.length==length)proven=[sample retain];
        pthread_mutex_unlock(&memo_lock);}
    int ok=!privateDigest||proven;
    if(ok&&!segmented)ok=blob_write_leaf(token,name,bytes,length,stable_hint(identity,0,length),proven,privateKey,borrowed);
    else{
        NSMutableArray *leaves=[NSMutableArray arrayWithCapacity:pages];
        for(size_t i=0;i<pages;i++){
            char leaf[FFSC_BLOB_NAME_BYTES];snprintf(leaf,sizeof(leaf),"page-%s-%04zu",name,i);[leaves addObject:@(leaf)];
        }
        int extra=pages>=32&&serializer_try_extra();
        if(pages>=32&&(!serializer_owned||extra)){
            /* Two synchronous workers keep exact comparison and hashing bounded;
             * the manifest retains its original page order. */
            __block _Atomic int complete=1;
            dispatch_apply(2,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^(size_t worker){@autoreleasepool{
                for(size_t i=worker;i<pages&&atomic_load(&complete);i+=2){
                    size_t offset=i*SOURCE_PAGE_BYTES,count=MIN((size_t)SOURCE_PAGE_BYTES,length-offset);
                    NSString *leaf=leaves[i];
                    if(!blob_write_leaf(token,leaf.UTF8String,(const unsigned char *)bytes+offset,count,
                        stable_hint(identity,offset,count),nil,nil,borrowed))atomic_store(&complete,0);
                }
            }});
            ok=atomic_load(&complete);if(extra)serializer_return_extra();
        }else for(size_t i=0;i<pages&&ok;i++){
            size_t offset=i*SOURCE_PAGE_BYTES,count=MIN((size_t)SOURCE_PAGE_BYTES,length-offset);
            NSString *leaf=leaves[i];
            ok=blob_write_leaf(token,leaf.UTF8String,(const unsigned char *)bytes+offset,count,stable_hint(identity,offset,count),nil,nil,borrowed);
        }
        if(ok){pthread_mutex_lock(&source_lock);
            if(stopped||tokens[@(token)]!=p||p->kind)ok=0;
            else{p->segments[@(name)]=@{@"payload_id":@(p->payload),@"name":@(name),@"length":@(length),
                @"page_bytes":@(SOURCE_PAGE_BYTES),@"pages":leaves};owner->profile.segmented_bytes+=length;owner->profile.segment_pages+=pages;}
            pthread_mutex_unlock(&source_lock);}
    }
    [privateKey release];[privateDigest release];[proven release];[owner release];[p release];return ok;
}}
int fullframe_chunk_blob_write(int token,const char *name,const void *bytes,size_t length){
    return chunk_blob_write(token,name,bytes,length,nil);
}

/* Private single-transaction equivalent of the small owned receiver-digest
 * path. Ineligible inputs use the original code. No transport credit, source
 * completion, cache admission or byte-ownership condition changes. */
static unsigned sfr_mode(void){static unsigned mode;static dispatch_once_t once;
    dispatch_once(&once,^{const char *v=getenv("BEDROCK_PRIVATE_SOURCE_RECEIVER_FAST");mode=v&&!strcmp(v,"2")?2u:0u;});return mode;}
static _Atomic uint64_t sfr_used,sfr_fallback;
static void sfr_report(int used){uint64_t n=atomic_fetch_add(used?&sfr_used:&sfr_fallback,1)+1;
    if(n<=2||!(n%1024))fprintf(stderr,"[SFR1] used=%llu fallback=%llu\n",(unsigned long long)atomic_load(&sfr_used),(unsigned long long)atomic_load(&sfr_fallback));}
static char *sfk_decimal(char *out,uint64_t value){char reversed[20];unsigned count=0;
    do{reversed[count++]=(char)('0'+value%10);value/=10;}while(value);
    while(count)*out++=reversed[--count];return out;}
static NSString *sfk_key(uint64_t serial,uint64_t payload,const char *name){
    static unsigned direct;static dispatch_once_t once;
    dispatch_once(&once,^{const char *v=getenv("BEDROCK_PRIVATE_SOURCE_KEY");direct=v&&!strcmp(v,"2");fprintf(stderr,"[SFK1] direct=%u\n",direct);});
    if(!direct)return [[NSString stringWithFormat:@"receiver:%llu:%llu:%s",(unsigned long long)serial,(unsigned long long)payload,name]copy];
    size_t length=strnlen(name,FFSC_BLOB_NAME_BYTES);if(!length||length>=FFSC_BLOB_NAME_BYTES)return nil;
    char text[9+20+1+20+1+FFSC_BLOB_NAME_BYTES],*at=text;memcpy(at,"receiver:",9);at+=9;
    at=sfk_decimal(at,serial);*at++=':';at=sfk_decimal(at,payload);*at++=':';memcpy(at,name,length);at+=length;
    return [[NSString alloc]initWithBytes:text length:(NSUInteger)(at-text) encoding:NSASCIIStringEncoding];
}
static int sfr_small_snapshot(int token,const char *name,id<MTLBuffer> snapshot,size_t length){@autoreleasepool{
    if(!sfr_mode())return -1;
    if(!receiver_digest_enabled||length>=SOURCE_SEGMENT_MIN||!ffsc_receiver_digest_name(name)){sfr_report(0);return -1;}
    const void *bytes=snapshot.contents;uint64_t allocation=MAX((uint64_t)snapshot.allocatedSize,(uint64_t)snapshot.length);
    NSString *filename=@(name);NSValue *snapshotKey=[NSValue valueWithPointer:(void *)snapshot];
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];FFSCSourceChunk *owner=p?p->chunk:nil;
    FFSCSourceIdentity *identity=p?p->identities[filename]:nil;
    int priorSnapshot=p&&p->retained_snapshots[snapshotKey]!=nil;
    int allowed=!stopped&&p&&!p->kind&&p->retained_snapshots&&p->retained_limit&&owner&&bytes&&
        snapshot.contents==bytes&&snapshot.storageMode==MTLStorageModeShared&&snapshot.length>=length&&allocation&&
        ![p->original_names containsObject:filename]&&!p->blobs[filename]&&
        (!identity||identity->length==length)&&(!identity||(!identity->private_key&&!identity->private_digest))&&
        owner->blob_count<=FFSC_MAX_BLOBS-2&&length<=UINT64_C(512)*1024*1024-owner->logical_bytes&&
        (priorSnapshot||(allocation<=FFSC_MAX_PACKET_BYTES-owner->bytes&&p->resident_bytes<=p->retained_limit&&allocation<=p->retained_limit-p->resident_bytes));
    if(!allowed){pthread_mutex_unlock(&source_lock);sfr_report(0);return -1;}
    FFSCSourceBlob *blob=[[[FFSCSourceBlob alloc]init]autorelease];blob->length=length;blob->receiver_digest=1;
    blob->hash=sfk_key(owner->serial,p->payload,name);
    if(!blob->hash||owner->resident_blobs[blob->hash]){pthread_mutex_unlock(&source_lock);sfr_report(0);return -1;}
    uint64_t cloneStart=profile_clock();blob->snapshot_owner=[snapshot retain];fullframe_stage_pool_retain(snapshot);
    blob->data=[[NSData alloc]initWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
    uint64_t cloneEnd=profile_clock();
    if(!blob->data){pthread_mutex_unlock(&source_lock);sfr_report(0);return -1;}
    if(!priorSnapshot){p->retained_snapshots[snapshotKey]=snapshot;p->resident_bytes+=allocation;owner->bytes+=allocation;}
    [p->original_names addObject:filename];owner->blob_count++;owner->logical_bytes+=length;
    owner->resident_blobs[blob->hash]=blob;p->blobs[filename]=blob;owner->profile.logical_bytes+=length;
    owner->profile.stable_identity_bytes+=identity?length:0;owner->profile.clone_ns+=cloneEnd>=cloneStart?cloneEnd-cloneStart:0;
    pthread_mutex_unlock(&source_lock);sfr_report(1);return 1;
}}

int fullframe_chunk_blob_write_completed_snapshot(int token,const char *name,id<MTLBuffer> snapshot,size_t length){
    if(!snapshot||!name||(strncmp(name,"cut-buffer-",11)&&strncmp(name,"operation-buffer-",17))||snapshot.storageMode!=MTLStorageModeShared||
       !snapshot.contents||!length||length>snapshot.length)return 0;
    int fast=sfr_small_snapshot(token,name,snapshot,length);if(fast>=0)return fast;
    return chunk_blob_write(token,name,snapshot.contents,length,snapshot);
}
int fullframe_chunk_blob_write_shared_snapshot(int token,const char *name,id<MTLBuffer> snapshot,size_t length,
    ffsa_extent_desc extent){@autoreleasepool{
    if(!name||!ffsc_shared_snapshot_name(name)||!snapshot||!snapshot_arena||
       snapshot.storageMode!=MTLStorageModeShared||!snapshot.contents||!length||length>snapshot.length||
       length>extent.length||extent.offset%FFSA_ALIGNMENT||extent.allocated_length<extent.length)return 0;
    pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];FFSCSourceChunk *c=p?p->chunk:nil;
    FFSCSourceIdentity *identity=p?p->identities[@(name)]:nil;
    int ok=!stopped&&p&&!p->kind&&c&&c->shared_claimed&&!c->shared_sealed&&
        c->shared_lease.slot==extent.lease.slot&&c->shared_lease.generation==extent.lease.generation&&
        c->shared_lease.serial==extent.lease.serial&&identity&&identity->length==length&&
        ![p->original_names containsObject:@(name)]&&!p->blobs[@(name)]&&
        c->blob_count<FFSC_MAX_BLOBS&&length<=UINT64_C(512)*1024*1024-c->logical_bytes;
    if(ok){FFSCSourceBlob *blob=[[[FFSCSourceBlob alloc]init]autorelease];
        blob->length=length;blob->shared_offset=extent.offset;blob->shared_snapshot=1;
        blob->hash=[[NSString stringWithFormat:@"shared:%llu:%llu:%s",
            (unsigned long long)c->serial,(unsigned long long)p->payload,name]copy];
        [p->original_names addObject:@(name)];p->blobs[@(name)]=blob;
        c->blob_count++;c->logical_bytes+=length;c->shared_blob_count++;c->profile.logical_bytes+=length;}
    pthread_mutex_unlock(&source_lock);return ok;
}}
uint64_t fullframe_chunk_payload_bytes(int token){pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];uint64_t bytes=0;
    if(!p)bytes=UINT64_MAX;else bytes=p->resident_bytes;pthread_mutex_unlock(&source_lock);return bytes;}
void fullframe_chunk_payload_ready(int token,const char *kind){pthread_mutex_lock(&source_lock);FFSCSourcePayload *p=tokens[@(token)];
    if(p&&!p->kind&&p->blobs[@"bindings.json"]){p->kind=[@(kind) copy];p->chunk->payload_ready_ns=profile_clock();source_progress_generation++;
        pthread_cond_broadcast(&source_changed);}
    else stop_source("incomplete immutable payload");pthread_mutex_unlock(&source_lock);}
void fullframe_chunk_source_serialization_failed(void){
    pthread_mutex_lock(&source_lock);stop_source("payload serialization failed");pthread_mutex_unlock(&source_lock);
}
void fullframe_chunk_source_budget_changed(void){
    pthread_mutex_lock(&source_lock);source_progress_generation++;
    pthread_cond_broadcast(&source_changed);pthread_mutex_unlock(&source_lock);
}
int fullframe_chunk_source_completion(id<MTLCommandBuffer> command,const ffs_producer_context *context){
    pthread_mutex_lock(&source_lock);FFSCSourceChunk *c=current;
    int ok=!stopped&&c&&c->chunk==context->chunk&&c->frame==context->frame&&c->stream==context->stream&&
        (!completion_enabled||(c->completion&&c->completion->command==command&&c->queue_completion==context->completion));
    if(ok)[c retain];pthread_mutex_unlock(&source_lock);if(!ok)return 0;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){pthread_mutex_lock(&source_lock);
        if(completed.status==MTLCommandBufferStatusCompleted){c->source_completed=1;c->gpu_done_ns=profile_clock();source_progress_generation++;
            if([completed respondsToSelector:@selector(GPUStartTime)]&&[completed respondsToSelector:@selector(GPUEndTime)]){
                double start=completed.GPUStartTime,end=completed.GPUEndTime;if(start>0&&end>=start&&end-start<60)c->gpu_ns=(uint64_t)((end-start)*1000000000.0);}
            if(c->completion)c->completion->source_completed=1;}
        else stop_source("source snapshot GPU failure");pthread_cond_broadcast(&source_changed);
        pthread_mutex_unlock(&source_lock);[c release];}];return 1;
}
int fullframe_chunk_buffer_has_prior_native_write(const ffs_producer_context *c,const ffs_producer_resource *r){@autoreleasepool{
    if(!c||!r||r->kind!=FFS_BUFFER||!(r->flags&FFS_READ)||!r->root||!r->allocation_generation||!r->length||r->offset>UINT64_MAX-r->length)return 0;
    pthread_mutex_lock(&source_lock);int covered=0;
    if(completion_enabled&&!stopped&&current&&!current->sealed&&current->stream==c->stream&&current->frame==c->frame&&current->chunk==c->chunk){
        NSString *key=[NSString stringWithFormat:@"%u:%llu:%llu",FFS_BUFFER,(unsigned long long)r->root,(unsigned long long)r->allocation_generation];
        NSDictionary *known=seen_roots[key];NSArray *range=known[@"native_range"];
        if(range.count==2&&[known[@"output_version"] unsignedLongLongValue]==r->input_content_version){
            uint64_t lo=[range[0] unsignedLongLongValue],hi=[range[1] unsignedLongLongValue];
            covered=r->offset>=lo&&r->offset<=hi&&r->length<=hi-r->offset;
        }
    }
    pthread_mutex_unlock(&source_lock);return covered;
}}
uint32_t fullframe_chunk_stream_retire(uint64_t kind,uint64_t root,uint64_t generation){@autoreleasepool{
    extern void fullframe_live_history_retire(uint64_t,uint64_t,uint64_t);fullframe_live_history_retire(kind,root,generation);
    if(!fullframe_chunk_stream_enabled())return 1;pthread_mutex_lock(&source_lock);
    if(!initialized||!seen_roots){pthread_mutex_unlock(&source_lock);return 1;}
    if((kind!=FFS_BUFFER&&kind!=FFS_TEXTURE)||!root){pthread_mutex_unlock(&source_lock);return 0;}
    NSMutableSet *markers=admission_serial?admission_markers:(current_chunk_open()?current->retired_during_chunk:nil);
    if(markers){
        NSString *marker=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)kind,(unsigned long long)root,(unsigned long long)generation];
        if(![markers containsObject:marker]){
            if(markers.count>=FFSC_MAX_RETIREMENTS){stop_source("source retirement marker capacity");pthread_mutex_unlock(&source_lock);return 0;}
            [markers addObject:marker];
        }
    }
    NSString *physical=physical_root_key(kind,root);
    NSArray *keys=generation?@[[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)kind,(unsigned long long)root,(unsigned long long)generation]]:
        [seen_root_generations[physical] allObjects];
    for(NSString *key in keys){NSDictionary *r=seen_roots[key];
        if(r){
            if(!queue_retirement(r)){stop_source("source retirement capacity");break;}
            forget_seen_root(key,r);
        }
    }
    int ok=!stopped;pthread_mutex_unlock(&source_lock);return ok;
}}

/* All registry operations and binding lifetimes share source_lock. Transport
 * consumption releases blob storage only; these command/query identities stay
 * retained until the original PE finish thread explicitly consumes/releases. */
static FFSCCompletionBinding *completion_binding(void *command,uint64_t stream,uint64_t chunk,uint64_t queue_completion){
    if(stopped)return nil;
    FFSCCompletionBinding *binding=completion_bindings[@(queue_completion)];
    if(!completion_enabled||!binding||!command||!stream||binding->command!=(id)command||
       binding->packet.stream!=stream||binding->packet.chunk!=chunk||binding->packet.queue_completion!=queue_completion){
        stop_source("unknown native completion command binding");return nil;
    }return binding;
}
static uint32_t completion_state(FFSCCompletionBinding *binding){
    if(stopped)return FFSC_COMPLETION_FAILED;
    if(!binding->tracked||!binding->published||!binding->source_completed)return FFSC_COMPLETION_PENDING;
    enum ffcc_result state=ffcc_state(completions,binding->packet.stream,binding->packet.queue_completion);
    if(state==FFCC_READY){
        if(binding->returned!=binding->readbacks.count)return FFSC_COMPLETION_PENDING;
        if((binding->packet.flags&FFSC_FRAME_END)&&!binding->presented){
            typedef uint32_t (*suspended_fn)(void);static suspended_fn suspended;static dispatch_once_t once;
            dispatch_once(&once,^{suspended=(suspended_fn)dlsym(RTLD_DEFAULT,"fullframe_native_overlay_suspended");});
            const char *offscreen=getenv("BEDROCK_NATIVE_OFFSCREEN");
            return (!offscreen||strcmp(offscreen,"1"))&&suspended&&suspended()==1?FFSC_COMPLETION_SUSPENDED:FFSC_COMPLETION_PENDING;
        }return FFSC_COMPLETION_READY;
    }
    if(state==FFCC_PENDING)return FFSC_COMPLETION_PENDING;
    stop_source("missing native completion registry identity");return FFSC_COMPLETION_FAILED;
}
uint32_t fullframe_chunk_completion_begin(void *command,uint64_t stream,uint64_t chunk,uint64_t queue_completion){@autoreleasepool{
    pthread_mutex_lock(&source_lock);uint32_t result=FFSC_COMPLETION_FAILED;
    if(!fullframe_chunk_stream_enabled()||!initialize_source()||stopped||!completion_enabled)goto done;
    if(!command){stop_source("missing native completion command");goto done;}
    if(!stream){
        if(!captured_started&&!collector&&!has_prefix)result=FFSC_COMPLETION_BYPASS;
        else stop_source("captured native completion cannot bypass");goto done;
    }
    id<MTLCommandBuffer> original=(id)command;
    if(!queue_completion||!current||current->stream!=stream||current->chunk!=chunk||current->queue_completion!=queue_completion||
       current->sealed||current->completion||completion_bindings[@(queue_completion)]||completion_bindings.count==FFCC_CAPACITY||
       ![original conformsToProtocol:@protocol(MTLCommandBuffer)]||original.status>=MTLCommandBufferStatusCommitted){
        stop_source("invalid or exhausted native completion binding");goto done;
    }
    FFSCCompletionBinding *binding=[[[FFSCCompletionBinding alloc]init]autorelease];
    binding->readbacks=[[NSMutableArray alloc]init];
    binding->command=[original retain];binding->packet=(ffsc_packet_header){.serial=current->serial,.stream=stream,
        .frame=current->frame,.chunk=chunk,.queue_completion=queue_completion};
    current->completion=[binding retain];completion_bindings[@(queue_completion)]=binding;result=FFSC_COMPLETION_CAPTURED;
done:pthread_mutex_unlock(&source_lock);return result;
}}
uint32_t fullframe_chunk_completion_wait(void *command,uint64_t stream,uint64_t chunk,uint64_t queue_completion,uint32_t timeout_ms){@autoreleasepool{
    pthread_mutex_lock(&source_lock);FFSCCompletionBinding *binding=completion_binding(command,stream,chunk,queue_completion);
    uint32_t result=FFSC_COMPLETION_FAILED;if(!binding)goto done;[binding retain];
    if(timeout_ms>30000){stop_source("native completion wait exceeds bounded deadline");goto done;}
    struct timespec now;clock_gettime(CLOCK_MONOTONIC,&now);
    uint64_t deadline=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec+(uint64_t)timeout_ms*1000000;
    while((result=completion_state(binding))==FFSC_COMPLETION_PENDING&&timeout_ms){
        clock_gettime(CLOCK_MONOTONIC,&now);uint64_t time=(uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
        if(time>=deadline)break;uint64_t remaining=deadline-time;
        struct timespec interval={.tv_sec=(time_t)(remaining/1000000000),.tv_nsec=(long)(remaining%1000000000)};
        int error=pthread_cond_timedwait_relative_np(&source_changed,&source_lock,&interval);
        if(error&&error!=ETIMEDOUT){stop_source("native completion wait failed");result=FFSC_COMPLETION_FAILED;break;}
    }
done:[binding release];pthread_mutex_unlock(&source_lock);return result;
}}
uint32_t fullframe_chunk_completion_query(void *command,uint64_t stream,uint64_t chunk,uint64_t queue_completion,
    uint32_t kind,uint64_t id,uint64_t index,uint64_t count,uint64_t expected_value,uint64_t *value){@autoreleasepool{
    if(value)*value=0;pthread_mutex_lock(&source_lock);uint32_t result=FFSC_COMPLETION_FAILED;
    FFSCCompletionBinding *binding=completion_binding(command,stream,chunk,queue_completion);if(!binding)goto done;
    if(!value){stop_source("missing native query result destination");goto done;}
    ffcc_query query={.kind=kind,.id=id,.index=index,.count=count,.value=expected_value};
    if(!binding->tracked){result=FFSC_COMPLETION_PENDING;goto done;}
    const ffcc_query *queries=binding->queries.bytes;size_t length=binding->queries.length/sizeof(*queries),i=0;
    for(;i<length;i++)if(!memcmp(&queries[i],&query,sizeof(query)))break;
    if(i==length){stop_source("unknown native completion query tuple");result=FFSC_COMPLETION_FAILED;goto done;}
    result=completion_state(binding);if(result!=FFSC_COMPLETION_READY)goto done;
    if(ffcc_lookup(completions,stream,queue_completion,&query,value)!=FFCC_READY){
        *value=0;stop_source("native query expectation disappeared");result=FFSC_COMPLETION_FAILED;goto done;
    }
    if(!binding->fetched[i]){binding->fetched[i]=1;binding->fetched_count++;}
done:pthread_mutex_unlock(&source_lock);return result;
}}
uint32_t fullframe_chunk_completion_release(void *command,uint64_t stream,uint64_t chunk,uint64_t queue_completion){@autoreleasepool{
    pthread_mutex_lock(&source_lock);uint32_t result=FFSC_COMPLETION_FAILED;
    FFSCCompletionBinding *binding=completion_binding(command,stream,chunk,queue_completion);if(!binding)goto done;
    if(completion_state(binding)!=FFSC_COMPLETION_READY||binding->fetched_count!=binding->queries.length/sizeof(ffcc_query)||
       ffcc_release(completions,&binding->packet)!=FFCC_OK){stop_source("incomplete native query consumption or release");goto done;}
    const ffcc_query *queries=binding->queries.bytes;size_t count=binding->queries.length/sizeof(*queries);
    for(size_t i=0;i<count;i++)if(queries[i].kind==FFSC_TIMESTAMP)native_timestamp_groups++;else if(queries[i].kind==FFSC_EVENT_QUERY)native_event_groups++;
    native_completed++;
    if(binding->packet.flags&FFSC_FRAME_END)native_presented_frames++;
    if(native_completed==1||!(native_completed%64))fprintf(stderr,"[native-completion-consumed] stream=%llu queue_completion=%llu chunk=%llu completed=%llu timestamp_groups=%llu event_groups=%llu presented_frames=%llu readback_ranges=%llu readback_bytes=%llu cpu_bytes=%llu\n",
        (unsigned long long)stream,(unsigned long long)queue_completion,(unsigned long long)chunk,(unsigned long long)native_completed,
        (unsigned long long)native_timestamp_groups,(unsigned long long)native_event_groups,(unsigned long long)native_presented_frames,
        (unsigned long long)native_readback_ranges,(unsigned long long)native_readback_bytes,(unsigned long long)native_readback_cpu_bytes);
    id<MTLCommandBuffer> original=binding->command;binding->command=nil;[original release];
    [completion_bindings removeObjectForKey:@(queue_completion)];pthread_cond_broadcast(&source_changed);result=FFSC_COMPLETION_READY;
done:pthread_mutex_unlock(&source_lock);return result;
}}
int fullframe_chunk_readback_register(const ffs_producer_context *c,uint64_t payload,uint32_t command_index,uint32_t resource,
    uint64_t offset,uint64_t row_bytes,uint64_t row_length,uint64_t row_count){@autoreleasepool{
    const char *option=getenv(FFSC_COMPLETION_ENV);if(!option||strcmp(option,"1"))return 1;
    pthread_mutex_lock(&source_lock);int ok=0;
    if(stopped||!completion_enabled||!readback_endpoint||!c||!current||!current->completion||
       current->stream!=c->stream||current->frame!=c->frame||current->chunk!=c->chunk||c->category!=FFS_BLIT||
       !c->resources.ptr||resource>=c->resource_count||!c->commands.ptr||command_index>=c->command_count)goto done;
    FFSCCompletionBinding *binding=current->completion;FFSCSourcePayload *p=current->payloads[@(payload)];
    if(!p||p->encoder!=c->encoder||p->category!=FFS_BLIT||binding->tracked||current->sealed||
       binding->readbacks.count==FFCC_MAX_QUERIES||!row_length||!row_count||row_bytes<row_length||
       (offset&3)||(row_bytes&3)||(row_length&3)||row_length>FFRB_MAX_BYTES/row_count)goto done;
    uint64_t length=row_length*row_count;if(length>FFRB_MAX_BYTES-binding->readback_bytes)goto done;
    const ffs_producer_resource *ref=&((const ffs_producer_resource *)c->resources.ptr)[resource];
    const struct wmtcmd_base *command=c->commands.ptr;
    for(uint32_t i=0;command&&i<command_index;i++)command=command->next.ptr;
    if(!command||command->type!=WMTBlitCommandCopyFromTextureToBuffer||ref->kind!=FFS_BUFFER||!ref->root||!ref->view||
       !ref->allocation_generation||(ref->flags&(FFS_READ|FFS_WRITE))!=(FFS_READ|FFS_WRITE)||
       offset<ref->offset||offset-ref->offset>ref->length||row_count-1>UINT64_MAX/row_bytes)goto done;
    const struct wmtcmd_blit_copy_from_texture_to_buffer *copy=(const void *)command;
    if(copy->dst!=ref->handle||copy->offset!=offset||copy->bytes_per_row!=row_bytes||copy->size.height!=row_count||copy->size.depth!=1)goto done;
    uint64_t span=(row_count-1)*row_bytes;
    if(row_length>UINT64_MAX-span)goto done;span+=row_length;
    id<MTLBuffer> buffer=(id)ref->handle;
    if(![buffer conformsToProtocol:@protocol(MTLBuffer)]||buffer.device!=binding->command.device||
       (buffer.storageMode!=MTLStorageModeShared&&buffer.storageMode!=MTLStorageModePrivate)||
       (buffer.storageMode==MTLStorageModeShared&&!buffer.contents)||offset>buffer.length||span>buffer.length-offset||
       span>ref->length-(offset-ref->offset))goto done;
    for(FFSCReadbackTarget *old in binding->readbacks){
        if(old->expected.encoder==c->encoder&&old->expected.command==command_index)goto done;
        uint64_t old_span=(old->expected.row_count-1)*old->expected.row_bytes+old->expected.row_length;
        if(old->buffer==buffer&&(old->expected.root!=ref->root||old->expected.generation!=ref->allocation_generation)&&
           offset<old->expected.offset+old_span&&old->expected.offset<offset+span)goto done;
    }
    FFSCReadbackTarget *target=[[[FFSCReadbackTarget alloc]init]autorelease];target->buffer=[buffer retain];
    target->payload=payload;target->resource=resource;target->view=ref->view;target->ref_offset=ref->offset;target->ref_length=ref->length;
    target->expected=(ffrb_record){.encoder=c->encoder,.command=command_index,.root=ref->root,.generation=ref->allocation_generation,
        .content_version=ref->output_content_version,.offset=offset,.row_bytes=row_bytes,.row_length=row_length,.row_count=row_count,.length=length};
    [binding->readbacks addObject:target];binding->readback_bytes+=length;ok=1;
done:if(!ok&&!stopped)stop_source("invalid native readback target, shape, alias or missing channel");pthread_mutex_unlock(&source_lock);return ok;
}}

int fullframe_chunk_texture_has_prior_native_write(const ffs_producer_context *c,const ffs_producer_resource *r){@autoreleasepool{
 if(!c||!r||r->kind!=FFS_TEXTURE||!(r->flags&FFS_READ)||(r->flags&FFS_WRITE)||!r->handle||
    !private_texture_eligible((id<MTLTexture>)r->handle))return 0;
 pthread_mutex_lock(&source_lock);NSString *key=[NSString stringWithFormat:@"%u:%llu:%llu",FFS_TEXTURE,(unsigned long long)r->root,(unsigned long long)r->allocation_generation];
 NSDictionary *known=seen_roots[key];int yes=completion_enabled&&!stopped&&current&&!current->sealed&&current->stream==c->stream&&current->frame==c->frame&&current->chunk==c->chunk&&[known[@"native_texture"] boolValue]&&[known[@"output_version"] unsignedLongLongValue]==r->input_content_version;
 pthread_mutex_unlock(&source_lock);return yes;
}}

int fullframe_live_has_native_buffer(const ffs_producer_context *c,const ffs_producer_resource *r){
 if(!c||!r||r->kind!=FFS_BUFFER||!(r->flags&FFS_READ))return 0;
 pthread_mutex_lock(&source_lock);NSString *key=[NSString stringWithFormat:@"%u:%llu:%llu",FFS_BUFFER,r->root,r->allocation_generation];NSDictionary*known=seen_roots[key];NSArray*range=known[@"native_range"];
 int ok=completion_enabled&&!stopped&&current&&!current->sealed&&current->stream==c->stream&&current->frame==c->frame&&current->chunk==c->chunk&&range.count==2&&[known[@"output_version"]unsignedLongLongValue]==r->input_content_version;
 pthread_mutex_unlock(&source_lock);return ok;
}
