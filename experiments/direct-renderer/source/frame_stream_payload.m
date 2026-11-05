#include "retained_observer.h"
/* Whole-pass producer payloads. MRC; original DXMT work remains authoritative
 * until the separate native backend completes and returns verified output. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>
#import "frame_stream_private.h"
#define FFSC_PRODUCER_API __attribute__((weak_import))
#import "chunk_stream_producer.h"
#define FF_DRAW_TYPED_API __attribute__((weak_import))
#import "draw_cut_blobs.h"
#define FFMD_ENCODER_API __attribute__((weak_import))
#import "metadata_wire_encode.h"
#import "shared_texture_pass_capture.h"
#import "shared_texture_attachment.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/mman.h>
#include <time.h>
#include <unistd.h>
#import "native_boundary_pass.h"
#ifdef BEDROCK_BOUNDARY_UPLOADS
#include "native_boundary_upload.h"
#endif

extern int fullframe_frame_capture_layout(id<MTLRenderPipelineState>,ff_draw_layout *);
extern FFSTPassRecord *fullframe_frame_capture_record(id<MTLCommandBuffer>,const struct WMTRenderPassInfo *,const struct wmtcmd_base *,const struct ff_draw_cut *);
extern int fullframe_write_resource_cut(int,struct ff_draw_cut *,FFSTPassRecord *,int);
extern void fullframe_draw_cut_add_load_fence(id<MTLFence>,id<MTLFence>);

#define FRAME_BYTES (UINT64_C(512)*1024*1024)
#define FRAME_PAYLOADS 128
static pthread_mutex_t guard=PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t io,io_second,io_third,io_fourth;
static _Atomic uint64_t io_ticket;
#ifdef BEDROCK_TEST_SOURCE_COMPLETION
__attribute__((weak)) int fullframe_test_payload_single_lane(void){return 0;}
__attribute__((weak)) void fullframe_test_payload_event(int token,int phase){(void)token;(void)phase;}
#endif
static void payload_test_event(int token,int phase){
#ifdef BEDROCK_TEST_SOURCE_COMPLETION
    fullframe_test_payload_event(token,phase);
#else
    (void)token;(void)phase;
#endif
}
static unsigned private_io_mode(void){static unsigned mode;static dispatch_once_t once;
    dispatch_once(&once,^{const char *v=getenv("BEDROCK_PRIVATE_SOURCE_IO");mode=v&&!strcmp(v,"2")?2u:v&&!strcmp(v,"3")?3u:v&&!strcmp(v,"4")?4u:0u;
        fprintf(stderr,"[IOS1] mode=%u\n",mode);});return mode;}
static dispatch_queue_t payload_io(int directory,uint64_t bytes){
#ifdef BEDROCK_TEST_SOURCE_COMPLETION
    if(fullframe_test_payload_single_lane())return io;
#endif
    /* Keep large segmented work on one lane so it can borrow the idle page
     * worker; small payloads may use either lane. */
    if(directory < -1){unsigned mode=private_io_mode();
        if(mode>=3){uint64_t ticket=atomic_fetch_add_explicit(&io_ticket,1,memory_order_relaxed)%mode;
            return ticket==3?io_fourth:ticket==2?io_third:ticket==1?io_second:io;}}
    return directory < -1&&(private_io_mode()==2||bytes<2u*1024u*1024u)&&io_second&&
        (atomic_fetch_add_explicit(&io_ticket,1,memory_order_relaxed)&1)?io_second:io;
}
static int root_directory=-1,failed,coverage_failed,ended,published;
static uint64_t stream_id,frame_id,next_payload=2,reserved_bytes,stored_bytes,shared_bytes,memo_bytes,snapshot_arena_bytes;
static uint32_t shared_cuts;
static size_t pending,completed_chunks,expected_chunks;
static NSMutableArray *payloads,*dependencies;
static NSMutableSet *registered_chunks,*dependency_keys;
static _Atomic(FFSTAttachmentCapture) attachment_capture;
/* Continuous success records are opt-in: failure diagnostics and aggregate
 * profiling remain available without formatting a line for every payload. */
static pthread_once_t success_trace_once=PTHREAD_ONCE_INIT;
static int success_trace;
static void initialize_success_trace(void){
    const char *option=getenv("BEDROCK_NATIVE_SOURCE_TIMELINE");success_trace=option&&!strcmp(option,"1");
}
static int log_payload_success(int directory){
    if(directory>=-1)return 1;pthread_once(&success_trace_once,initialize_success_trace);return success_trace;
}
/* guard is held. The capture object lives until bridge shutdown; its own lock
 * reports current retained leases, including completed retirement ACKs. */
static void refresh_shared_bytes_locked(void){
    FFSTAttachmentCapture capture=atomic_load_explicit(&attachment_capture,memory_order_acquire);
    uint64_t outstanding=0;shared_cuts=capture?ffst_attachment_capture_pending(capture,&outstanding):0;shared_bytes=outstanding;
}
static int budget_allows_locked(uint64_t bytes){
    uint64_t available=FRAME_BYTES-snapshot_arena_bytes;
    return reserved_bytes<=available&&shared_bytes<=available-reserved_bytes&&
        memo_bytes<=available-reserved_bytes-shared_bytes&&bytes<=available-reserved_bytes-shared_bytes-memo_bytes;
}
static int payload_fits_locked(int ok,uint64_t bytes,uint64_t reservation){
    uint64_t available=FRAME_BYTES-snapshot_arena_bytes;
    return !failed&&ok&&bytes<=reservation&&stored_bytes<=available&&bytes<=available-stored_bytes;
}
/* The full arena is already charged to FRAME_BYTES. Once an exact allocated
 * extent is known to use that arena, return its duplicate per-payload charge.
 * A bounded page map under guard prevents duplicate/overlapping credits, even
 * across payloads and concurrent callers. Old/stale lease generations fail
 * closed and simply keep their conservative reservation. */
#define FFSA_CREDIT_PAGES (FFSA_MAX_SLOT_BYTES / FFSA_ALIGNMENT)
#define FFSA_CREDIT_WORDS (FFSA_CREDIT_PAGES / 64u)
_Static_assert(FFSA_MAX_SLOT_BYTES % FFSA_ALIGNMENT == 0 && FFSA_CREDIT_PAGES % 64u == 0,
    "arena credit bitmap must cover every slot page");
typedef struct { uint64_t generation,serial,pages[FFSA_CREDIT_WORDS]; } FFSAChargeSlot;
static FFSAChargeSlot arena_charges[FFSA_SLOT_COUNT];
static uint64_t credit_shared_extents(uint64_t *reservation,const ffsa_extent_desc *extents,size_t count){
    if(!reservation||(!extents&&count)||count>FFS_MAX_RESOURCES)return 0;
    uint64_t credited=0;pthread_mutex_lock(&guard);
    if(snapshot_arena_bytes==FFSA_SLOT_COUNT*(uint64_t)FFSA_MAX_SLOT_BYTES){
        for(size_t i=0;i<count;i++){
            ffsa_extent_desc e=extents[i];
            if(e.lease.slot>=FFSA_SLOT_COUNT||e.lease.reserved||!e.lease.generation||!e.lease.serial||
               !e.length||e.length>FFSA_MAX_SLOT_BYTES||e.offset%FFSA_ALIGNMENT||
               e.allocated_length!=((e.length+FFSA_ALIGNMENT-1)&~((uint64_t)FFSA_ALIGNMENT-1))||
               e.offset>FFSA_MAX_SLOT_BYTES||e.allocated_length>FFSA_MAX_SLOT_BYTES-e.offset||
               e.length>*reservation||e.length>reserved_bytes)continue;
            FFSAChargeSlot *slot=&arena_charges[e.lease.slot];
            if(slot->generation>e.lease.generation||(slot->generation==e.lease.generation&&slot->serial!=e.lease.serial))continue;
            if(slot->generation<e.lease.generation){memset(slot->pages,0,sizeof(slot->pages));slot->generation=e.lease.generation;slot->serial=e.lease.serial;}
            size_t first=(size_t)(e.offset/FFSA_ALIGNMENT),pages=(size_t)(e.allocated_length/FFSA_ALIGNMENT);int collision=0;
            for(size_t j=0;j<pages;j++)if(slot->pages[(first+j)/64]&(UINT64_C(1)<<((first+j)%64))){collision=1;break;}
            if(collision)continue;
            for(size_t j=0;j<pages;j++)slot->pages[(first+j)/64]|=UINT64_C(1)<<((first+j)%64);
            *reservation-=e.length;reserved_bytes-=e.length;credited+=e.length;
        }
    }
    pthread_mutex_unlock(&guard);
    if(credited&&fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
    return credited;
}
int fullframe_frame_stream_reserve_snapshot_arena(uint64_t bytes){
    if(bytes!=FFSA_SLOT_COUNT*FFSA_MAX_SLOT_BYTES)return 0;
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();
    int ok=!failed&&!snapshot_arena_bytes&&budget_allows_locked(bytes);
    if(ok)snapshot_arena_bytes=bytes;
    pthread_mutex_unlock(&guard);return ok;
}
int fullframe_frame_stream_admission_reasons(uint64_t headroom){
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();
    /* Leave eight of the existing sixteen shared-load cuts for the new chunk.
     * Larger/unsupported chunks retain their original immediate hard failures. */
    int result=failed||coverage_failed?-1:((budget_allows_locked(headroom)?0:FFSC_ADMISSION_BUDGET)|(shared_cuts>8?FFSC_ADMISSION_CUTS:0));
    pthread_mutex_unlock(&guard);return result;
}
int fullframe_frame_stream_admission_ready(uint64_t headroom){int reasons=fullframe_frame_stream_admission_reasons(headroom);return reasons<0?-1:!reasons;}
int fullframe_frame_stream_reserve_memo(uint64_t bytes){
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();int ok=!failed&&budget_allows_locked(bytes);
    if(ok)memo_bytes+=bytes;pthread_mutex_unlock(&guard);return ok;
}
void fullframe_frame_stream_release_memo(uint64_t bytes){
    pthread_mutex_lock(&guard);if(bytes<=memo_bytes)memo_bytes-=bytes;
    else{fprintf(stderr,"[full-frame-memo-budget-reject] bytes=%llu retained=%llu\n",(unsigned long long)bytes,(unsigned long long)memo_bytes);failed=1;}
    pthread_mutex_unlock(&guard);
}
static int chunk_mode(void){return fullframe_chunk_stream_enabled&&fullframe_chunk_stream_enabled();}
static void payload_fail_fast(int directory){
    pthread_mutex_lock(&guard);failed=1;pthread_mutex_unlock(&guard);
    if(directory < -1&&fullframe_chunk_source_serialization_failed)fullframe_chunk_source_serialization_failed();
}
static uint64_t payload_profile_now(void){
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return 0;
    return (uint64_t)now.tv_sec*UINT64_C(1000000000)+(uint64_t)now.tv_nsec;
}
static uint64_t payload_profile_elapsed(uint64_t start){uint64_t end=payload_profile_now();return end>=start?end-start:0;}
static void payload_profile_token(int token,uint32_t stage,uint64_t ns,uint64_t bytes,uint64_t count){
    if(token < -1&&fullframe_chunk_profile_token)fullframe_chunk_profile_token(token,stage,ns,bytes,count);
}
static void payload_close(int directory){if(directory>=0)close(directory);}
static int chunk_sink(void *context,const char *name,const void *bytes,size_t length){
    return fullframe_chunk_blob_write((int)(intptr_t)context,name,bytes,length);
}
static int chunk_snapshot_sink(void *context,const char *name,id<MTLBuffer> snapshot,size_t length,
    const ffsa_extent_desc *shared_extent){
    if(shared_extent&&shared_extent->lease.generation)
        return fullframe_chunk_blob_write_shared_snapshot((int)(intptr_t)context,name,snapshot,length,*shared_extent);
    return fullframe_chunk_blob_write_completed_snapshot((int)(intptr_t)context,name,snapshot,length);
}
static void register_payload(int directory,uint64_t payload,const char *kind){
    if(directory < -1)fullframe_chunk_payload_ready(directory,kind);
    else [payloads addObject:@{@"payload_id":@(payload),@"directory":[NSString stringWithFormat:@"payload-%llu",(unsigned long long)payload],@"kind":@(kind)}];
}
void fullframe_frame_stream_release_storage(uint64_t bytes){
    pthread_mutex_lock(&guard);if(bytes<=stored_bytes&&bytes<=reserved_bytes){stored_bytes-=bytes;reserved_bytes-=bytes;}
    else{fprintf(stderr,"[full-frame-storage-reject] bytes=%llu stored=%llu reserved=%llu\n",(unsigned long long)bytes,(unsigned long long)stored_bytes,(unsigned long long)reserved_bytes);failed=1;}pthread_mutex_unlock(&guard);
    if(fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
}


static int write_bytes(int directory,const char *name,const void *bytes,size_t length){
    if(directory < -1)return fullframe_chunk_blob_write(directory,name,bytes,length);
    char temp[192];if(snprintf(temp,sizeof(temp),".%s.tmp",name)>=(int)sizeof(temp))return 0;
    int fd=openat(directory,temp,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 0;
    const unsigned char *p=bytes;
    while(length){ssize_t n=write(fd,p,length);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;length-=(size_t)n;}
    int ok=!length&&!fsync(fd);if(close(fd))ok=0;
    if(ok)ok=!linkat(directory,temp,directory,name,0);unlinkat(directory,temp,0);return ok&&!fsync(directory);
}
static int write_json(int directory,const char *name,NSDictionary *record){
    uint64_t started=payload_profile_now();
    NSData *data=[NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    payload_profile_token(directory,FFSC_PROFILE_JSON,payload_profile_elapsed(started),data.length,1);
    return data&&data.length<=8u*1024u*1024u&&write_bytes(directory,name,data.bytes,data.length);
}
static NSString *metadata_digest(NSData *data){
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
    char hex[65];for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return @(hex);
}
static uint64_t directory_bytes(int directory){
    if(directory < -1)return fullframe_chunk_payload_bytes(directory);
    DIR *listing=fdopendir(dup(directory));if(!listing)return UINT64_MAX;
    uint64_t result=0;struct dirent *entry;
    while((entry=readdir(listing))){
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        struct stat st;if(fstatat(directory,entry->d_name,&st,AT_SYMLINK_NOFOLLOW)||!S_ISREG(st.st_mode)||st.st_uid!=getuid()||
            st.st_nlink!=1||(st.st_mode&077)||st.st_size<0||(uint64_t)st.st_size>FRAME_BYTES-result){result=UINT64_MAX;break;}
        result+=(uint64_t)st.st_size;
    }
    closedir(listing);return result;
}
static NSDictionary *ledger_info(void){
    char name[128];snprintf(name,sizeof(name),"frame-%llu-%llu.complete.ffs",(unsigned long long)stream_id,(unsigned long long)frame_id);
    int fd=openat(root_directory,name,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;
    struct stat st;int valid=!fstat(fd,&st)&&S_ISREG(st.st_mode)&&st.st_uid==getuid()&&st.st_nlink==1&&!(st.st_mode&077)&&
        st.st_size>0&&(uint64_t)st.st_size<=FFS_MAX_RECORDS*sizeof(ffs_record);
    CC_SHA256_CTX sha;CC_SHA256_Init(&sha);unsigned char buffer[65536],digest[CC_SHA256_DIGEST_LENGTH];
    while(valid){ssize_t n=read(fd,buffer,sizeof(buffer));if(n<0&&errno==EINTR)continue;if(n<0){valid=0;break;}if(!n)break;CC_SHA256_Update(&sha,buffer,(CC_LONG)n);}
    close(fd);if(!valid)return nil;CC_SHA256_Final(digest,&sha);char hex[65];
    for(unsigned i=0;i<sizeof(digest);i++)snprintf(hex+i*2,3,"%02x",digest[i]);
    return @{@"file":@(name),@"bytes":@((uint64_t)st.st_size),@"sha256":@(hex)};
}
/* Called on the serial I/O queue, after every original GPU callback and file
 * publication. Consumer retirement is deliberately a later native-side gate. */
static void finish_if_ready(void){
    if(chunk_mode())return;
    pthread_mutex_lock(&guard);
    if(!ended||pending||completed_chunks!=expected_chunks||published||failed||coverage_failed){pthread_mutex_unlock(&guard);return;}
    refresh_shared_bytes_locked();
    NSDictionary *ledger=ledger_info();uint64_t ledger_bytes=[ledger[@"bytes"] unsignedLongLongValue];
    uint64_t available=FRAME_BYTES-snapshot_arena_bytes;
    if(!ledger||shared_bytes>available||stored_bytes>available-shared_bytes||
       ledger_bytes>available-stored_bytes-shared_bytes){failed=1;pthread_mutex_unlock(&guard);return;}
    NSDictionary *record=@{@"format":@"bedrock-native-frame-files",@"version":@1,@"stream":@(stream_id),@"frame":@(frame_id),
        @"ledger":ledger,@"payloads":payloads,@"retained_bytes":@(stored_bytes+shared_bytes+ledger_bytes),
        @"producer_completed":@YES,@"dependencies":dependencies};
    char name[128];snprintf(name,sizeof(name),"frame-%llu-%llu.ready.json",(unsigned long long)stream_id,(unsigned long long)frame_id);
    published=write_json(root_directory,name,record);if(!published)failed=1;
#ifdef BEDROCK_BOUNDARY_UPLOADS
    fullframe_boundary_upload_report();
#endif
    fprintf(stderr,"[full-frame-payload] %s payloads=%lu chunks=%zu bytes=%llu\n",published?"ready":"failed",(unsigned long)payloads.count,expected_chunks,
        (unsigned long long)(stored_bytes+shared_bytes+ledger_bytes));pthread_mutex_unlock(&guard);
}

/* One-frame, default-off correctness oracle. Copy the exact logical Present
 * input after all source draws, on their command queue. This is diagnostic
 * readback, excluded from performance measurements and never used by native
 * execution. The completion receipt binds bytes to the source stream/frame. */
static int boundary_reference(id<MTLCommandBuffer> command,id<MTLTexture> texture,
                              const ffs_producer_context *c){
    const char *option=getenv("BEDROCK_BOUNDARY_REFERENCE");
    if(!option||strcmp(option,"1"))return 1;
    if(chunk_mode()||root_directory<0||texture.sampleCount!=1||
       !texture.width||!texture.height||texture.width>4096||texture.height>4096)return 0;
    NSUInteger row=(texture.width*4+255)&~(NSUInteger)255,length=row*texture.height;
    if(length>32u*1024u*1024u)return 0;
    int directory=dup(root_directory);if(directory<0)return 0;
    id<MTLBuffer> bytes=[command.device newBufferWithLength:length options:MTLResourceStorageModeShared];
    if(!bytes){close(directory);return 0;}
    /* DXMT uses untracked resources. Encoder order alone is not an execution
     * dependency. Match its barrierOnQueue signal/wait idiom on both sides
     * of this diagnostic copy, including future source use of the backbuffer. */
    id<MTLSharedEvent> barrier=[command.device newSharedEvent];
    if(!barrier){[bytes release];close(directory);return 0;}
    [command encodeSignalEvent:barrier value:1];[command encodeWaitForEvent:barrier value:1];
    id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];
    if(!copy){[barrier release];[bytes release];close(directory);return 0;}
    [copy copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(texture.width,texture.height,1) toBuffer:bytes destinationOffset:0
        destinationBytesPerRow:row destinationBytesPerImage:length];[copy endEncoding];
    [command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
    uint64_t stream=c->stream,frame=c->frame,width=texture.width,height=texture.height,format=texture.pixelFormat;
    pthread_mutex_lock(&guard);++pending;pthread_mutex_unlock(&guard);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){dispatch_async(io,^{@autoreleasepool{
        NSData *data=[NSData dataWithBytesNoCopy:bytes.contents length:length freeWhenDone:NO];
        int ok=completed.status==MTLCommandBufferStatusCompleted&&barrier.signaledValue==2&&write_bytes(directory,"boundary-reference.raw",data.bytes,data.length);
        if(ok)ok=write_json(directory,"boundary-reference.json",@{@"format":@"bedrock-boundary-reference-v1",
            @"stream":@(stream),@"frame":@(frame),@"width":@(width),@"height":@(height),
            @"pixel_format":@(format),@"row_bytes":@(row),@"bytes":@(length),@"sha256":metadata_digest(data),
            @"gpu_completed":@YES,@"ordering":@"source-queue-signal-wait-copy-signal-wait",@"barrier_completed":@2,
            @"scope":@"source backbuffer before presenter transfer"});
        close(directory);pthread_mutex_lock(&guard);--pending;if(!ok)failed=1;pthread_mutex_unlock(&guard);finish_if_ready();
    }});}];
    [barrier release];[bytes release];return 1;
}

/* prepare() runs just before the original encoder is created. Internal
 * snapshot encoders are already closed before this TLS token is published. */
static _Thread_local uint64_t boundary_pass_payload,boundary_pass_stream,boundary_pass_frame;
static _Thread_local id<MTLCommandBuffer> boundary_pass_command;
static _Thread_local const struct wmtcmd_base *boundary_pass_commands;
static _Thread_local id<MTLBuffer> boundary_pass_arguments;
static _Thread_local NSMutableArray *boundary_pass_textures;
static _Thread_local NSArray *boundary_pass_buffers;
static _Thread_local struct ff_draw_cut *boundary_pass_cut;
static _Thread_local NSDictionary *boundary_pass_state;
extern int fullframe_boundary_encode_commands(id<MTLRenderCommandEncoder>,const struct wmtcmd_base *,id<MTLBuffer>,NSDictionary *,int,NSMutableArray *);
static NSMutableDictionary *boundary_pass_encoders;
void fullframe_boundary_pass_begin(id<MTLRenderCommandEncoder> encoder,id<MTLCommandBuffer> command,MTLRenderPassDescriptor *pass){
    if(!boundary_pass_payload||boundary_pass_command!=command)return;
    uint64_t payload=boundary_pass_payload;boundary_pass_payload=0;boundary_pass_command=nil;
    MTLRenderPassColorAttachmentDescriptor *a=pass.colorAttachments[0];
    if(!a.texture||(a.storeAction!=MTLStoreActionStore&&a.storeAction!=MTLStoreActionStoreAndMultisampleResolve))return;
    NSArray *inputs=boundary_pass_textures?:@[];
    pthread_mutex_lock(&guard);
    if(!boundary_pass_encoders)boundary_pass_encoders=[[NSMutableDictionary alloc]init];
    boundary_pass_encoders[[NSValue valueWithPointer:encoder]]=@{@"command":command,@"color":a.texture,@"payload":@(payload),
        @"stream":@(boundary_pass_stream),@"frame":@(boundary_pass_frame),@"pass":[[pass copy] autorelease],
        @"commands":[NSValue valueWithPointer:boundary_pass_commands],@"arguments":(id)boundary_pass_arguments?:[NSNull null],@"textures":inputs,@"buffers":boundary_pass_buffers?:@[],@"cut":[NSValue valueWithPointer:boundary_pass_cut],@"state":boundary_pass_state?:@{}};
    [boundary_pass_textures release];boundary_pass_textures=nil;
    [boundary_pass_buffers release];boundary_pass_buffers=nil;
    pthread_mutex_unlock(&guard);
}
static BOOL boundary_buffer_bytes(NSDictionary *entry){
    NSArray *entries=entry[@"buffers"];if(!entries.count)return YES;
    id<MTLCommandBuffer> command=entry[@"command"];NSUInteger total=0;NSMutableArray *metadata=[NSMutableArray array];
    for(NSDictionary *item in entries){NSUInteger length=[item[@"length"] unsignedIntegerValue];
        if(!length||total>64u*1024u*1024u||length>64u*1024u*1024u-total)return NO;
        [metadata addObject:@{@"id":item[@"id"],@"offset":@(total),@"source_offset":item[@"source_offset"],@"length":@(length)}];total+=(length+255)&~(NSUInteger)255;
    }
    id<MTLBuffer> bytes=[command.device newBufferWithLength:total options:MTLResourceStorageModeShared];
    id<MTLSharedEvent> barrier=[command.device newSharedEvent];int directory=dup(root_directory);
    if(!bytes||!barrier||directory<0){[bytes release];[barrier release];if(directory>=0)close(directory);return NO;}
    [command encodeSignalEvent:barrier value:1];[command encodeWaitForEvent:barrier value:1];
    id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];if(!copy){[bytes release];[barrier release];close(directory);return NO;}
    for(NSUInteger i=0;i<entries.count;i++){NSDictionary *item=entries[i],*m=metadata[i];
        [copy copyFromBuffer:item[@"buffer"] sourceOffset:[item[@"source_offset"] unsignedIntegerValue] toBuffer:bytes destinationOffset:[m[@"offset"] unsignedIntegerValue] size:[m[@"length"] unsignedIntegerValue]];}
    [copy endEncoding];[command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
    pthread_mutex_lock(&guard);++pending;pthread_mutex_unlock(&guard);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){@autoreleasepool{
        BOOL ok=completed.status==MTLCommandBufferStatusCompleted&&barrier.signaledValue==2&&entries.count==metadata.count;
        if(ok)ok=write_bytes(directory,"boundary-buffers.raw",bytes.contents,total)&&write_json(directory,"boundary-buffers.json",@{@"ranges":metadata,@"gpu_completed":@YES,@"bytes":@(total)});
        close(directory);pthread_mutex_lock(&guard);--pending;if(!ok)failed=1;pthread_mutex_unlock(&guard);dispatch_async(io,^{finish_if_ready();});
    }}];[bytes release];[barrier release];return YES;
}
/* Inspect the unique terrain atlas after its source reads, before any later
 * pass can update it. Match every mip, excluding row padding in the audit. */
static BOOL boundary_atlas_bytes(id<MTLCommandBuffer> command,id<MTLTexture> texture){
    if(texture.width!=1024||texture.height!=512||texture.mipmapLevelCount!=4||texture.pixelFormat!=MTLPixelFormatRGBA8Unorm)return YES;
    NSUInteger length=0;NSMutableArray *planes=[NSMutableArray array];
    for(NSUInteger mip=0;mip<texture.mipmapLevelCount;mip++){
        NSUInteger width=MAX((NSUInteger)1,texture.width>>mip),height=MAX((NSUInteger)1,texture.height>>mip),row=(width*4+255)&~(NSUInteger)255;
        [planes addObject:@{@"mip":@(mip),@"width":@(width),@"height":@(height),@"row_bytes":@(row),@"offset":@(length)}];length+=row*height;
    }
    id<MTLBuffer> bytes=[command.device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLSharedEvent> barrier=[command.device newSharedEvent];int directory=dup(root_directory);
    if(!bytes||!barrier||directory<0){[bytes release];[barrier release];if(directory>=0)close(directory);return NO;}
    [command encodeSignalEvent:barrier value:1];[command encodeWaitForEvent:barrier value:1];
    id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];if(!copy){[bytes release];[barrier release];close(directory);return NO;}
    for(NSDictionary *plane in planes)[copy copyFromTexture:texture sourceSlice:0 sourceLevel:[plane[@"mip"] unsignedIntegerValue] sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake([plane[@"width"] unsignedIntegerValue],[plane[@"height"] unsignedIntegerValue],1) toBuffer:bytes destinationOffset:[plane[@"offset"] unsignedIntegerValue]
        destinationBytesPerRow:[plane[@"row_bytes"] unsignedIntegerValue] destinationBytesPerImage:[plane[@"row_bytes"] unsignedIntegerValue]*[plane[@"height"] unsignedIntegerValue]];
    [copy endEncoding];[command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
    pthread_mutex_lock(&guard);++pending;pthread_mutex_unlock(&guard);
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){@autoreleasepool{
        BOOL ok=completed.status==MTLCommandBufferStatusCompleted&&barrier.signaledValue==2&&texture.width==1024;
        if(ok)ok=write_bytes(directory,"boundary-atlas.raw",bytes.contents,length)&&write_json(directory,"boundary-atlas.json",@{@"planes":planes,@"gpu_completed":@YES,@"bytes":@(length)});
        close(directory);pthread_mutex_lock(&guard);--pending;if(!ok)failed=1;pthread_mutex_unlock(&guard);dispatch_async(io,^{finish_if_ready();});
    }}];[bytes release];[barrier release];return YES;
}
/* Control: original PSOs, tables and input objects, original WMT encoder.
 * Borrowed command nodes are used synchronously before DXMT destroys the pass.
 * Only clear-initialized terrain output is cloned; no source writes or queries. */
extern id fullframe_boundary_native_tables(id<MTLDevice>,const void *,NSDictionary *,int) __attribute__((weak_import));
extern id fullframe_boundary_trace_encoder(id,id,MTLRenderPassDescriptor *,int,NSString *,const void *) __attribute__((weak_import));
static BOOL boundary_clone(NSDictionary *entry,int mode){
    MTLRenderPassDescriptor *original=entry[@"pass"];
    const struct wmtcmd_base *commands=[entry[@"commands"] pointerValue];
    if(!commands||entry[@"arguments"]==[NSNull null]||original.colorAttachments[0].texture.sampleCount!=2||
       original.colorAttachments[0].loadAction!=MTLLoadActionClear||original.depthAttachment.loadAction!=MTLLoadActionClear||
       original.stencilAttachment.loadAction!=MTLLoadActionClear)return YES;
    unsigned draws=0,count=0;for(const struct wmtcmd_base *r=commands;r;r=r->next.ptr){
        if(++count>65536)return NO;
        if(r->type==WMTRenderCommandDraw||r->type==WMTRenderCommandDrawIndexed)++draws;
        if(r->type==WMTRenderCommandSetVisibilityMode)return NO;
    }
    if(draws<100)return YES;
    if(mode>=1000&&draws<(unsigned)(mode-1000))return NO;
    id<MTLCommandBuffer> command=entry[@"command"];
    MTLRenderPassDescriptor *pass=[[original copy] autorelease];NSMutableArray *owned=[NSMutableArray array];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){(void)owned.count;(void)completed.status;}];
    id<MTLTexture> source[3]={original.colorAttachments[0].texture,original.depthAttachment.texture,original.stencilAttachment.texture};
    id<MTLTexture> targets[3]={nil,nil,nil};
    for(unsigned i=0;i<3;i++)if(source[i]){
        if(i==2&&source[2]==source[1]){targets[2]=targets[1];continue;}
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:source[i].pixelFormat width:source[i].width height:source[i].height mipmapped:NO];
        d.textureType=source[i].textureType;d.sampleCount=source[i].sampleCount;d.storageMode=MTLStorageModePrivate;d.usage=source[i].usage;
        targets[i]=[command.device newTextureWithDescriptor:d];if(!targets[i])return NO;
        [owned addObject:targets[i]];[targets[i] release];
    }
    pass.colorAttachments[0].texture=targets[0];pass.colorAttachments[0].resolveTexture=nil;pass.colorAttachments[0].storeAction=MTLStoreActionStore;
    pass.depthAttachment.texture=targets[1];pass.stencilAttachment.texture=targets[2];
    id<MTLSharedEvent> barrier=[command.device newSharedEvent];if(!barrier)return NO;[owned addObject:barrier];
    [command encodeSignalEvent:barrier value:1];[command encodeWaitForEvent:barrier value:1];
    NSMutableDictionary *textures=[NSMutableDictionary dictionary];
    if(mode==3)textures[@"cut"]=entry[@"cut"];
    if(mode==8||mode==9)textures[@"state"]=entry[@"state"];
    if(mode==7||mode==20){
        const struct ff_draw_cut *cut=[entry[@"cut"] pointerValue];if(!cut){[barrier release];return NO;}
        for(size_t i=0;i<cut->draw_count;i++){
            const ff_draw_plan *plan=&cut->draws[i];if(!plan->indexed)continue;const ff_vertex_binding *b=&plan->index_binding;
            if(!b->id||b->id>cut->snapshot_count||b->generation!=1||b->offset>cut->source_length[b->id-1]||b->length>cut->source_length[b->id-1]-b->offset){[barrier release];return NO;}
            textures[[NSValue valueWithPointer:plan->command]]=@{@"buffer":cut->snapshots[b->id-1],@"offset":@(b->offset)};
        }
    }

    if(mode==2){
        id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];if(!copy){[barrier release];return NO;}
        for(id<MTLTexture> input in entry[@"textures"]){
            NSNumber *key=@(input.gpuResourceID._impl);if(textures[key])continue;
            if(input.textureType!=MTLTextureType2D||input.sampleCount!=1||input.arrayLength!=1){[copy endEncoding];[barrier release];return NO;}
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:input.pixelFormat width:input.width height:input.height mipmapped:NO];
            d.mipmapLevelCount=input.mipmapLevelCount;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
            id<MTLTexture> texture=[command.device newTextureWithDescriptor:d];if(!texture){[copy endEncoding];[barrier release];return NO;}
            [owned addObject:texture];textures[key]=texture;[texture release];[copy copyFromTexture:input toTexture:texture];
        }
        [copy endEncoding];[command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
        for(id<MTLTexture> texture in textures.allValues)if(!boundary_atlas_bytes(command,texture)){[barrier release];return NO;}
    }
    if(mode==4||(mode>=20&&mode<=22)){
        const struct ff_draw_cut *cut=[entry[@"cut"] pointerValue];
        if(!cut||cut->texture_count>FF_TEXTURE_RESOURCE_LIMIT){[barrier release];return NO;}
        id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];if(!copy){[barrier release];return NO;}
        for(size_t i=0;i<cut->texture_count;i++){
            const ff_texture_snapshot *v=&cut->textures[i];id<MTLBuffer> bytes=cut->texture_buffers[i];
            if(!bytes&&v->bytes){bytes=[command.device newBufferWithBytes:v->bytes length:v->length options:MTLResourceStorageModeShared];if(bytes){[owned addObject:bytes];[bytes release];}}
            if(!bytes||v->texture_type!=MTLTextureType2D||v->array_length!=1){[copy endEncoding];[barrier release];return NO;}
            MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:v->format width:v->width height:v->height mipmapped:NO];
            d.mipmapLevelCount=v->mip_count;d.storageMode=MTLStorageModePrivate;d.usage=MTLTextureUsageShaderRead|MTLTextureUsagePixelFormatView;
            id<MTLTexture> texture=[command.device newTextureWithDescriptor:d];if(!texture){[copy endEncoding];[barrier release];return NO;}
            [owned addObject:texture];textures[@(cut->source_texture_ids[i])]=texture;[texture release];
            for(size_t j=0;j<v->plane_count;j++){
                ff_texture_plane plane=v->planes[j];NSUInteger width=MAX((NSUInteger)1,v->width>>plane.mip),height=MAX((NSUInteger)1,v->height>>plane.mip);
                [copy copyFromBuffer:bytes sourceOffset:plane.offset sourceBytesPerRow:plane.row_bytes sourceBytesPerImage:plane.length sourceSize:MTLSizeMake(width,height,1)
                    toTexture:texture destinationSlice:plane.slice destinationLevel:plane.mip destinationOrigin:MTLOriginMake(0,0,0)];
            }
        }
        [copy endEncoding];[command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
    }
    if(mode>=20&&mode<=22){
        id tables=fullframe_boundary_native_tables?fullframe_boundary_native_tables(command.device,[entry[@"cut"] pointerValue],textures,mode):nil;
        if(!tables){[barrier release];return NO;}textures[@"native_tables"]=tables;[owned addObject:tables];
    }
    id<MTLRenderCommandEncoder> clone=[command renderCommandEncoderWithDescriptor:pass];if(!clone){[barrier release];return NO;}
    if(mode==20&&fullframe_boundary_trace_encoder)clone=fullframe_boundary_trace_encoder(clone,command,pass,root_directory,@"source",[entry[@"cut"] pointerValue]);
    id<MTLBuffer> argument=entry[@"arguments"];
    [clone setVertexBuffer:argument offset:0 atIndex:16];
    for(NSUInteger slot=29;slot<=30;slot++){[clone setVertexBuffer:argument offset:0 atIndex:slot];[clone setFragmentBuffer:argument offset:0 atIndex:slot];}
    BOOL encoded=fullframe_boundary_encode_commands(clone,commands,argument,textures,mode,owned);[clone endEncoding];
    pthread_mutex_lock(&guard);++pending;pthread_mutex_unlock(&guard);
    void (^done)(BOOL)=^(BOOL ok){
        BOOL retained=encoded&&owned.count>0&&barrier.signaledValue==((mode==2||mode==4||(mode>=20&&mode<=22))?2:1);
        pthread_mutex_lock(&guard);--pending;if(!ok||!retained)failed=1;pthread_mutex_unlock(&guard);dispatch_async(io,^{finish_if_ready();});
    };
    BOOL scheduled=boundary_pass_capture(command,targets[0],root_directory,mode>=20&&mode<=22?[NSString stringWithFormat:@"native-bindings-%d",mode]:mode==0?@"clone-original":mode==8?@"clone-state":mode==9?@"clone-depth":mode==7?@"clone-indices":mode>=1000?[NSString stringWithFormat:@"prefix-%d",mode-1000]:mode==1?@"clone-samplers":mode==2?@"clone-textures":mode==3?@"clone-buffers":@"clone-saved-textures",[entry[@"stream"] unsignedLongLongValue],
        [entry[@"frame"] unsignedLongLongValue],[entry[@"payload"] unsignedLongLongValue],done);
    if(!scheduled)done(NO);[barrier release];return scheduled;
}
void fullframe_boundary_pass_end(id encoder){
    pthread_mutex_lock(&guard);NSValue *key=[NSValue valueWithPointer:encoder];
    NSDictionary *entry=[boundary_pass_encoders[key] retain];[boundary_pass_encoders removeObjectForKey:key];
    if(entry)++pending;pthread_mutex_unlock(&guard);if(!entry)return;
    if(!boundary_buffer_bytes(entry)||!boundary_clone(entry,0)||
       (fullframe_boundary_native_tables&&(!boundary_clone(entry,20)||!boundary_clone(entry,21)||!boundary_clone(entry,22)))){
        pthread_mutex_lock(&guard);failed=1;pthread_mutex_unlock(&guard);}
    void (^done)(BOOL)=^(BOOL ok){pthread_mutex_lock(&guard);--pending;if(!ok)failed=1;pthread_mutex_unlock(&guard);dispatch_async(io,^{finish_if_ready();});};
    if(!boundary_pass_capture(entry[@"command"],entry[@"color"],root_directory,@"source",[entry[@"stream"] unsignedLongLongValue],
        [entry[@"frame"] unsignedLongLongValue],[entry[@"payload"] unsignedLongLongValue],done))done(NO);
    [entry release];
}

/* Weakly called by the pointer-free sink only after its strict collector has
 * accepted each packet. This observer never upgrades rejected coverage. */
void fullframe_frame_stream_event(const ffs_record *r){
    if(!r)return;pthread_mutex_lock(&guard);
    if(r->kind==FFS_FRAME_BEGIN&&root_directory<0){
        const char *path=getenv("BEDROCK_FULLFRAME_FRAME_STREAM_DIRECTORY");struct stat st;
        int fd=path?open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC):-1;
        if(fd>=0&&!fstat(fd,&st)&&st.st_uid==getuid()&&!(st.st_mode&077)){
            root_directory=fd;stream_id=r->stream;frame_id=r->frame;
            payloads=[[NSMutableArray alloc]init];dependencies=[[NSMutableArray alloc]init];registered_chunks=[[NSMutableSet alloc]init];dependency_keys=[[NSMutableSet alloc]init];
            io=dispatch_queue_create("bedrock.full-frame.payloads",DISPATCH_QUEUE_SERIAL);
            if(!io)failed=1;
        }else{if(fd>=0)close(fd);failed=1;}
    }
    if(r->stream!=stream_id||r->frame!=frame_id){pthread_mutex_unlock(&guard);return;}
    if((r->flags&FFS_UNSUPPORTED)||r->kind==FFS_RESOURCE_UNRESOLVED||r->kind==FFS_REJECT)coverage_failed=1;
    if(r->kind==FFS_DEPENDENCY&&(r->flags&FFS_EXTERNAL)){
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu:%llu",(unsigned long long)r->data[0],(unsigned long long)r->data[1],(unsigned long long)r->data[2],(unsigned long long)r->data[5]];
        if(![dependency_keys containsObject:key]){
            if(dependencies.count==FFS_MAX_DEPENDENCIES)failed=1;
            else{[dependency_keys addObject:key];[dependencies addObject:@{@"domain":@(r->data[0]),@"id":@(r->data[1]),@"value":@(r->data[2]),@"payload_id":@(r->data[5])}];}
        }
    }
    if(r->kind==FFS_FRAME_END){ended=1;expected_chunks=r->data[0];}
    int check=ended&&io;pthread_mutex_unlock(&guard);if(check)dispatch_async(io,^{@autoreleasepool{finish_if_ready();}});
}

#include "source_scalar_reference.h"
static NSMutableDictionary *reference_legacy(const ffs_producer_resource *r,uint64_t payload){
    if(!r->root||!r->view||!r->allocation_generation||!r->input_content_version)return nil;
    NSMutableDictionary *d=[NSMutableDictionary dictionaryWithDictionary:@{@"kind":@(r->kind),@"root":@(r->root),@"view":@(r->view),
        @"allocation_generation":@(r->allocation_generation),@"input_content_version":@(r->input_content_version),
        @"output_content_version":@(r->output_content_version),@"payload_id":@(payload),@"flags":@(r->flags),@"offset":@(r->offset),@"length":@(r->length)}];
    if(r->kind==FFS_BUFFER){
        id object=(id)r->handle;id<MTLBuffer> buffer=nil;
        if([object conformsToProtocol:@protocol(MTLBuffer)])buffer=object;
        else if([object conformsToProtocol:@protocol(MTLTexture)])buffer=((id<MTLTexture>)object).buffer;
        uint64_t capacity=r->buffer_length?:buffer.length,origin=r->buffer_base_offset;
        if(!capacity){if(r->offset>UINT64_MAX-r->length)return nil;capacity=r->offset+r->length;}
        if(r->offset<origin||r->offset-origin>capacity||r->length>capacity-(r->offset-origin))return nil;
        d[@"buffer_length"]=@(capacity);d[@"buffer_base_offset"]=@(origin);
    }
    if(r->kind==FFS_TEXTURE){
        id<MTLTexture> texture=(id<MTLTexture>)r->handle;if(!texture)return nil;
        NSUInteger base_mip=0,base_slice=0;id<MTLTexture> parent=texture;
        for(unsigned depth=0;parent.parentTexture;depth++){
            if(depth==16||base_mip>NSUIntegerMax-parent.parentRelativeLevel||base_slice>NSUIntegerMax-parent.parentRelativeSlice)return nil;
            base_mip+=parent.parentRelativeLevel;base_slice+=parent.parentRelativeSlice;parent=parent.parentTexture;
        }
        MTLTextureSwizzleChannels s=texture.swizzle;
        [d addEntriesFromDictionary:@{@"base_mip":@(base_mip),@"base_slice":@(base_slice),@"mip_count":@(texture.mipmapLevelCount),
            @"slice_count":@(texture.textureType==MTLTextureTypeCube?6:texture.arrayLength),@"format":@(texture.pixelFormat),@"type":@(texture.textureType),
            @"width":@(texture.width),@"height":@(texture.height),@"array_length":@(texture.arrayLength),@"sample_count":@(texture.sampleCount),
            @"swizzle":@[@(s.red),@(s.green),@(s.blue),@(s.alpha)]}];
    }
    return d;
}

static unsigned scalar_reference_mode(void){static unsigned mode;static dispatch_once_t once;
 dispatch_once(&once,^{const char *v=getenv("BEDROCK_SOURCE_SCALAR_REFERENCES");mode=v&&!strcmp(v,"1")?1:v&&!strcmp(v,"2")?2:0;});return mode;}
static NSDictionary *reference(const ffs_producer_resource *r,uint64_t payload){
 unsigned mode=scalar_reference_mode();if(!mode||r->kind!=FFS_BUFFER)return reference_legacy(r,payload);
 if(!r->root||!r->view||!r->allocation_generation||!r->input_content_version)return nil;
 id object=(id)r->handle;id<MTLBuffer> buffer=nil;
 if([object conformsToProtocol:@protocol(MTLBuffer)])buffer=object;
 else if([object conformsToProtocol:@protocol(MTLTexture)])buffer=((id<MTLTexture>)object).buffer;
 uint64_t capacity=r->buffer_length?:buffer.length,origin=r->buffer_base_offset;
 if(!capacity){if(r->offset>UINT64_MAX-r->length)return nil;capacity=r->offset+r->length;}
 if(r->offset<origin||r->offset-origin>capacity||r->length>capacity-(r->offset-origin))return nil;
 NSDictionary *value=[FFSourceScalarReference reference:r payload:payload origin:origin capacity:capacity];
 if(mode==1){NSDictionary *old=reference_legacy(r,payload);if(![value isEqual:old]||![old isEqual:value])abort();}
 static _Thread_local uint64_t count;count++;if(count<=2||!(count%65536))fprintf(stderr,"[source-scalar-reference] mode=%u rows=%llu\n",mode,(unsigned long long)count);
 return value;
}
static NSDictionary *reference_with_id(NSDictionary *base,uint64_t identity){
 if([base isMemberOfClass:[FFSourceScalarReference class]])return [(FFSourceScalarReference *)base withSnapshotID:identity];
 NSMutableDictionary *copy=[[base mutableCopy]autorelease];copy[@"id"]=@(identity);return copy;
}
static NSMutableDictionary *header(const ffs_producer_context *c,uint64_t payload,NSString *format){
    return [NSMutableDictionary dictionaryWithDictionary:@{@"format":format,@"version":@1,@"stream":@(c->stream),@"frame":@(c->frame),
        @"chunk":@(c->chunk),@"encoder":@(c->encoder),@"category":@(c->category),@"payload_id":@(payload)}];
}
static uint64_t memo_root(const ffs_producer_resource *reference){
    /* Immutable upload-slice ledger roots are intentionally per-chunk. Their
     * retained Metal backing is a better local lookup hint; never sent on wire.
     * Recycled addresses still require an exact comparison of fresh bytes. */
    if(reference->kind==FFS_BUFFER&&(reference->root&UINT64_C(0x8000000000000000)))
        return reference->handle?reference->handle|UINT64_C(0x8000000000000000):0;
    return reference->root;
}
static int memo_identity(int directory,const char *name,const ffs_producer_resource *reference,uint64_t offset,uint64_t length){
    if(directory>=-1||!fullframe_chunk_blob_identity)return 1;
    uint64_t root=memo_root(reference);if(!root)return 1; /* Unknown identity keeps the ordinary hint. */
    return fullframe_chunk_blob_identity(directory,name,reference->kind,root,reference->view,offset,length);
}
static FFSTAttachmentCapture attachment_state(id<MTLDevice> device){
    if(attachment_capture)return attachment_capture;
    const char *service=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_SERVICE"),*token=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_TOKEN"),*registry=getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_DEVICE");
    char *end=NULL;errno=0;uint64_t expected=registry?strtoull(registry,&end,10):0;
    if(!service||!token||!registry||!end||*end||errno||expected!=device.registryID)return NULL;
    FFSTProducer p=ffst_producer_create(@(service),@(token),device,16,FRAME_BYTES,0);if(!p)return NULL;
    attachment_capture=ffst_attachment_capture_create(p,device,16,FRAME_BYTES);
    if(!attachment_capture)ffst_producer_destroy(p);return attachment_capture;
}

#include "callback_sidecar.h"
struct ff_payload_ref_index;
struct payload_context {
    id<MTLCommandBuffer> command;
    struct WMTRenderPassInfo *info;
    const ffs_producer_context *producer;
    uint64_t payload,reservation;
    int directory,reserved,extended;
    const char *reject_reason;uint64_t reject_index,cut_id,cut_draws,cut_buffers,cut_textures,cut_snapshot_bytes;
    uint64_t budget_reserved,budget_shared,budget_memo,budget_arena,budget_requested;
    uint32_t cut_stop,cut_command,cut_detail;int filter_called,filter_accepted;
    FFSTPassRecord *record;
    NSDictionary *bindings;
    cb_sidecar_lease *callback_lease;int callback_mode;
    struct ff_payload_ref_index *range_index;int range_index_attempted;
    uint64_t buffer_memo_roots[FF_DRAW_RESOURCE_LIMIT];
    FFSTAttachmentSource loads[10];size_t load_count;
};
/* Optional lease has its own exact reservation; published payload accounting
 * remains unchanged. The existing payload reservation retires the lease charge
 * only after callback storage is actually freed. */
static unsigned callback_live;
static _Atomic uint64_t callback_seen,callback_used,callback_fallback,callback_matched,callback_mismatch;
static void callback_report(int result){
    if(result==1)atomic_fetch_add_explicit(&callback_used,1,memory_order_relaxed);
    else if(result==2)atomic_fetch_add_explicit(&callback_matched,1,memory_order_relaxed);
    else if(result==3)atomic_fetch_add_explicit(&callback_mismatch,1,memory_order_relaxed);
    else atomic_fetch_add_explicit(&callback_fallback,1,memory_order_relaxed);
    uint64_t n=atomic_fetch_add_explicit(&callback_seen,1,memory_order_relaxed)+1;
    if(n<=4||!(n%256))fprintf(stderr,"[callback-sidecar] samples=%llu used=%llu fallback=%llu matched=%llu mismatch=%llu\n",
        (unsigned long long)n,(unsigned long long)atomic_load_explicit(&callback_used,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&callback_fallback,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&callback_matched,memory_order_relaxed),
        (unsigned long long)atomic_load_explicit(&callback_mismatch,memory_order_relaxed));
}
static void callback_take_lease(struct payload_context *p,const ffs_producer_context *c,uint64_t cut,
    const uint16_t *snapshots,size_t ns,const uint16_t *textures,size_t nt){
    size_t charge=cb_lease_size(c->resource_count,ns,nt);if(!charge)return;
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();
    int ok=!failed&&p->reserved&&callback_live<4&&p->reservation<=UINT64_MAX-charge&&budget_allows_locked(charge);
    if(ok){reserved_bytes+=charge;p->reservation+=charge;callback_live++;}
    pthread_mutex_unlock(&guard);if(!ok)return;
    cb_sidecar_lease *lease=calloc(1,charge);
    if(lease&&cb_lease_init(lease,charge,c,p->payload,cut,snapshots,ns,textures,nt)){p->callback_lease=lease;return;}
    free(lease);pthread_mutex_lock(&guard);
    reserved_bytes-=charge;p->reservation-=charge;callback_live--;
    pthread_mutex_unlock(&guard);
    if(fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
}
static void callback_drop_lease(struct payload_context *p){
    if(!p->callback_lease)return;free(p->callback_lease);p->callback_lease=NULL;
    pthread_mutex_lock(&guard);if(callback_live)callback_live--;else failed=1;pthread_mutex_unlock(&guard);
}
/* Transfer part of the pre-admitted reservation to each VM owner. Metal may
 * retain its wrapper after the cut is destroyed, so only its deallocator can
 * retire this charge. This budget covers storage, not driver metadata. */
static void release_mapped_charge(void *bytes,size_t length){
    /* The budget bounds queued mappings as well as live ones. Serialize their
     * cleanup, and never acquire a source lock or guard in a Metal callback. */
    static dispatch_queue_t reaper;static dispatch_once_t once;
    dispatch_once(&once,^{reaper=dispatch_queue_create("bedrock.mapped-reaper",DISPATCH_QUEUE_SERIAL);});
    dispatch_async(reaper,^{
        int ok=munmap(bytes,length)==0;int error=errno;
        pthread_mutex_lock(&guard);
        int retired=ok&&length<=reserved_bytes;
        if(retired)reserved_bytes-=length;
        else{failed=1;fprintf(stderr,"[full-frame-mapped-release-failed] bytes=%zu errno=%d\n",length,error);}
        pthread_mutex_unlock(&guard);
        /* No later payload can register after failed is set under guard. A
         * previously ready packet can still publish until stop_source obtains
         * its publication lock; stopping cannot retract an earlier packet. */
        if(!retired&&fullframe_chunk_source_serialization_failed)fullframe_chunk_source_serialization_failed();
        else if(fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
    });
}
/* A copied Metal deallocator block retains this object under MRC. If Metal
 * returns nil without retaining the block, dealloc retires the mapping; if it
 * retained the block, the callback and eventual dealloc share one retirement.
 * A retained callback that never runs keeps both mapping and charge alive. */
@interface FFMappedLease:NSObject {
    void *bytes;size_t length;_Atomic int retired;
}
-(id)initWithBytes:(void *)storage length:(size_t)size;
-(void)retire;
@end
@implementation FFMappedLease
-(id)initWithBytes:(void *)storage length:(size_t)size{
    if((self=[super init])){bytes=storage;length=size;atomic_init(&retired,0);}return self;
}
-(void)retire{if(!atomic_exchange_explicit(&retired,1,memory_order_acq_rel))release_mapped_charge(bytes,length);}
-(void)dealloc{[self retire];[super dealloc];}
@end
static id<MTLBuffer> chunk_snapshot_allocator(id<MTLDevice> device,size_t length,
    ffsa_extent_desc *shared_extent,void *context){
    struct payload_context *p=context;
    if(shared_extent){
        id<MTLBuffer> view=fullframe_chunk_snapshot_allocate(p->directory,device,length,shared_extent);
        if(view||!p->extended)return view;
    }else if(!p->extended)return nil;
    uint64_t rounded=0;if(!ff_draw_mapped_size(length,&rounded))return nil;
    pthread_mutex_lock(&guard);
    int allowed=p->reserved&&rounded<=p->reservation;
    if(allowed)p->reservation-=rounded;
    pthread_mutex_unlock(&guard);if(!allowed)return nil;
    void *bytes=mmap(NULL,(size_t)rounded,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
    if(bytes==MAP_FAILED){pthread_mutex_lock(&guard);reserved_bytes-=rounded;pthread_mutex_unlock(&guard);return nil;}
    FFMappedLease *lease=[[FFMappedLease alloc]initWithBytes:bytes length:(size_t)rounded];
    if(!lease){release_mapped_charge(bytes,(size_t)rounded);return nil;}
    id<MTLBuffer> buffer=[device newBufferWithBytesNoCopy:bytes length:(NSUInteger)rounded
        options:MTLResourceStorageModeShared deallocator:^(void *storage,NSUInteger size){
            (void)storage;(void)size;[lease retire];
        }];
    [lease release];
    if(!buffer)return nil;
    if(buffer.contents!=bytes){[buffer release];return nil;}
    return buffer;
}
static int layout(id<MTLRenderPipelineState> p,const struct wmtcmd_base *command,ff_draw_layout *out,void *context){
    (void)command;(void)context;return fullframe_frame_capture_layout(p,out);
}
static int add_references(struct payload_context *p,NSMutableArray *resources,NSMutableArray *attachments){
    const ffs_producer_context *c=p->producer;const ffs_producer_resource *refs=c->resources.ptr;
    for(size_t i=0;i<c->resource_count;i++){
        NSDictionary *d=reference(&refs[i],p->payload);if(!d)return 0;[resources addObject:d];
        uint32_t role=refs[i].role;if(!role)continue;
        NSString *name=nil;uint32_t index=0,level=0,slice=0,depth_plane=0;
        if(role>=FFS_ROLE_COLOR&&role<FFS_ROLE_COLOR_RESOLVE){index=role-FFS_ROLE_COLOR;name=@"color";level=p->info->colors[index].level;slice=p->info->colors[index].slice;depth_plane=p->info->colors[index].depth_plane;}
        else if(role>=FFS_ROLE_COLOR_RESOLVE&&role<FFS_ROLE_DEPTH){index=role-FFS_ROLE_COLOR_RESOLVE;name=@"color_resolve";level=p->info->colors[index].resolve_level;slice=p->info->colors[index].resolve_slice;depth_plane=p->info->colors[index].resolve_depth_plane;}
        else if(role==FFS_ROLE_DEPTH){name=@"depth";level=p->info->depth.level;slice=p->info->depth.slice;depth_plane=p->info->depth.depth_plane;}
        else if(role==FFS_ROLE_STENCIL){name=@"stencil";level=p->info->stencil.level;slice=p->info->stencil.slice;depth_plane=p->info->stencil.depth_plane;}
        else return 0;
        NSMutableDictionary *attachment=[[d mutableCopy]autorelease];[attachment addEntriesFromDictionary:@{@"role":name,@"index":@(index),@"level":@(level),@"slice":@(slice),@"depth_plane":@(depth_plane)}];
        if((refs[i].flags&FFS_READ)&&refs[i].input_content_version==1){
            if(p->load_count==10||[name isEqual:@"color_resolve"])return 0;
            FFSTAttachmentRole shared_role=[name isEqual:@"color"]?FFST_COLOR:([name isEqual:@"depth"]?FFST_DEPTH:FFST_STENCIL);
            p->loads[p->load_count++]=(FFSTAttachmentSource){.texture=(id<MTLTexture>)refs[i].handle,.source_id=refs[i].root,
                .source_generation=refs[i].input_content_version,.level=level,.slice=slice,.role=shared_role,.attachment_index=index};
            [attachment addEntriesFromDictionary:@{@"shared_cut_id":@(p->payload),@"shared_role":@(shared_role),@"shared_index":@(index)}];
        }
        [attachments addObject:attachment];
    }
    return 1;
}

/* BEGIN payload reference index: bounded to one producer context. */
#define FF_PAYLOAD_REF_BUCKETS 2048u
_Static_assert(FFS_MAX_RESOURCES < UINT16_MAX &&
    (FF_PAYLOAD_REF_BUCKETS&(FF_PAYLOAD_REF_BUCKETS-1))==0,"bounded payload reference index");
typedef uint64_t (*ff_payload_texture_id)(uint64_t);
struct ff_payload_ref_index {
    uint16_t heads[FF_PAYLOAD_REF_BUCKETS],write_heads[FF_PAYLOAD_REF_BUCKETS];
    uint16_t next[FFS_MAX_RESOURCES],write_next[FFS_MAX_RESOURCES];
    uint64_t texture_ids[FFS_MAX_RESOURCES];
};
static uint64_t ff_payload_ref_mix(uint64_t x){
    x^=x>>30;x*=UINT64_C(0xbf58476d1ce4e5b9);x^=x>>27;x*=UINT64_C(0x94d049bb133111eb);return x^(x>>31);
}
static size_t ff_payload_ref_bucket(uint64_t a,uint64_t b,uint64_t tag){
    return (size_t)(ff_payload_ref_mix(ff_payload_ref_mix(a)^ff_payload_ref_mix(b)^tag)&(FF_PAYLOAD_REF_BUCKETS-1));
}
static int ff_payload_ref_build(struct ff_payload_ref_index *index,const ffs_producer_resource *refs,size_t count,
    ff_payload_texture_id texture_id,int include_textures){
    if(!index||(!refs&&count)||count>FFS_MAX_RESOURCES||(include_textures&&!texture_id))return 0;
    memset(index,0,sizeof(*index));
    /* Reverse insertion retains the original first matching reference even
     * across duplicates and hash collisions. */
    for(size_t n=count;n;n--){size_t j=n-1;const ffs_producer_resource *r=&refs[j];size_t bucket;
        if(r->kind==FFS_BUFFER&&(r->flags&FFS_READ)){
            bucket=ff_payload_ref_bucket(r->root,r->allocation_generation,FFS_BUFFER);
            index->next[j]=index->heads[bucket];index->heads[bucket]=(uint16_t)(j+1);
        }else if(include_textures&&r->kind==FFS_TEXTURE){
            index->texture_ids[j]=texture_id(r->handle);
            bucket=ff_payload_ref_bucket(index->texture_ids[j],0,FFS_TEXTURE);
            index->next[j]=index->heads[bucket];index->heads[bucket]=(uint16_t)(j+1);
            if(r->flags&FFS_WRITE){bucket=ff_payload_ref_bucket(r->root,r->allocation_generation,FFS_TEXTURE);
                index->write_next[j]=index->write_heads[bucket];index->write_heads[bucket]=(uint16_t)(j+1);}
        }
    }return 1;
}
static const ffs_producer_resource *ff_payload_ref_buffer(const struct ff_payload_ref_index *index,
    const ffs_producer_resource *refs,uint64_t root,uint64_t generation,uint64_t offset,uint64_t length){
    size_t bucket=ff_payload_ref_bucket(root,generation,FFS_BUFFER);
    for(uint16_t item=index->heads[bucket];item;item=index->next[item-1]){
        const ffs_producer_resource *r=&refs[item-1];
        if(r->kind==FFS_BUFFER&&r->root==root&&r->allocation_generation==generation&&(r->flags&FFS_READ)&&
           offset>=r->offset&&offset-r->offset<=r->length&&length<=r->length-(offset-r->offset))return r;
    }return NULL;
}
static const ffs_producer_resource *ff_payload_ref_texture(const struct ff_payload_ref_index *index,
    const ffs_producer_resource *refs,uint64_t texture_id){
    size_t bucket=ff_payload_ref_bucket(texture_id,0,FFS_TEXTURE);
    for(uint16_t item=index->heads[bucket];item;item=index->next[item-1])
        if(refs[item-1].kind==FFS_TEXTURE&&index->texture_ids[item-1]==texture_id)return &refs[item-1];
    return NULL;
}
static int ff_payload_ref_texture_written(const struct ff_payload_ref_index *index,
    const ffs_producer_resource *refs,uint64_t root,uint64_t generation){
    size_t bucket=ff_payload_ref_bucket(root,generation,FFS_TEXTURE);
    for(uint16_t item=index->write_heads[bucket];item;item=index->write_next[item-1]){
        const ffs_producer_resource *r=&refs[item-1];
        if(r->kind==FFS_TEXTURE&&r->root==root&&r->allocation_generation==generation&&(r->flags&FFS_WRITE))return 1;
    }return 0;
}
/* END payload reference index */
static uint64_t payload_texture_id(uint64_t handle){return ((id<MTLTexture>)handle).gpuResourceID._impl;}
/* Match the same first readable physical-range witness required below. The
 * planner invokes this only for a potential multi-snapshot union. */
static const ffs_producer_resource *payload_first_buffer_reference(struct payload_context *p,uint64_t root,
    uint64_t generation,uint64_t offset,uint64_t length){
    const ffs_producer_context *c=p->producer;const ffs_producer_resource *refs=c->resources.ptr;
    if(p->range_index)return ff_payload_ref_buffer(p->range_index,refs,root,generation,offset,length);
    for(size_t j=0;j<c->resource_count;j++)if(refs[j].kind==FFS_BUFFER&&refs[j].root==root&&
        refs[j].allocation_generation==generation&&(refs[j].flags&FFS_READ)&&
        offset>=refs[j].offset&&offset-refs[j].offset<=refs[j].length&&
        length<=refs[j].length-(offset-refs[j].offset))return &refs[j];
    return NULL;
}
struct ff_witness_range {uint64_t start,end;};
static int witness_range_compare(const void *left,const void *right){
    const struct ff_witness_range *a=left,*b=right;
    return a->start<b->start?-1:a->start>b->start?1:0;
}
static int payload_union_witness(uint64_t root,uint64_t generation,uint64_t offset,uint64_t length,
    const struct ff_draw_source_interval *parts,size_t part_count,void *opaque){
    struct payload_context *p=opaque;const ffs_producer_context *c=p->producer;
    if(!parts||!part_count||part_count>FF_DRAW_RESOURCE_LIMIT+1)return 0;
    if(!p->range_index_attempted){p->range_index_attempted=1;
        if(c->resource_count>=32){p->range_index=malloc(sizeof(*p->range_index));
            if(p->range_index&&!ff_payload_ref_build(p->range_index,c->resources.ptr,c->resource_count,NULL,0)){free(p->range_index);p->range_index=NULL;}}}
    const ffs_producer_resource *refs=c->resources.ptr;
    const ffs_producer_resource *first=payload_first_buffer_reference(p,root,generation,offset,length);
    if(!first)return 0;
    struct ff_witness_range ranges[FF_DRAW_RESOURCE_LIMIT+1];
    for(size_t i=0;i<part_count;i++){
        uint64_t lo=parts[i].offset,n=parts[i].length;
        if(lo<offset||lo-offset>length||n>length-(lo-offset)||n>UINT64_MAX-lo)return 0;
        ranges[i]=(struct ff_witness_range){lo,lo+n};
    }
    /* The first producer reference cannot be shadowed by any earlier one. */
    if(first==refs)return 1;
    qsort(ranges,part_count,sizeof(*ranges),witness_range_compare);
    uint64_t suffix[FF_DRAW_RESOURCE_LIMIT+1];suffix[part_count-1]=ranges[part_count-1].end;
    for(size_t i=part_count-1;i;i--)suffix[i-1]=MIN(suffix[i],ranges[i-1].end);
    /* A previous compatible reference shadows a part exactly when it starts
     * before that part and ends after it. Sorted starts + suffix minimum answer
     * that query in logarithmic time, even for a full collision bucket. */
    for(const ffs_producer_resource *r=refs;r<first;r++){
        if(r->kind!=FFS_BUFFER||r->root!=root||r->allocation_generation!=generation||!(r->flags&FFS_READ))continue;
        size_t lo=0,hi=part_count;while(lo<hi){size_t mid=lo+(hi-lo)/2;if(ranges[mid].start<r->offset)lo=mid+1;else hi=mid;}
        uint64_t end=r->length>UINT64_MAX-r->offset?UINT64_MAX:r->offset+r->length;
        if(lo<part_count&&suffix[lo]<=end)return 0;
    }
    return 1;
}
/* The paired lifetime registry provides a synchronous witness. Its positive
 * result must cover the exact context, resource generation/version and range,
 * and remain valid through native GPU use. No witness means no marker. */
extern int fullframe_native_buffer_ref_authority(const ffs_producer_context *,
    const ffs_producer_resource *) __attribute__((weak_import));
/* Conservative role test: the snapshot must be used by a vertex binding,
 * and no snapshot of its root/generation may serve an index, constant, or
 * buffer argument. Unknown IDs and out-of-bounds metadata disqualify it. */
static int reference_same_root(const struct ff_draw_cut *cut,uint64_t candidate,uint64_t other){
    if(!other)return 0;
    if(other>cut->snapshot_count)return -1;
    size_t i=(size_t)candidate-1,j=(size_t)other-1;
    return cut->source_incarnation[i]==cut->source_incarnation[j]&&
        cut->source_generation[i]==cut->source_generation[j];
}
static int reference_vertex_only(const struct ff_draw_cut *cut,size_t index){
    if(!cut||!cut->draws||!cut->draw_count||index>=cut->snapshot_count)return 0;
    uint64_t id=index+1;int used=0;
    for(size_t n=0;n<cut->draw_count;n++){
        const ff_draw_plan *d=&cut->draws[n];
        if(d->binding_count>FF_VERTEX_RESOURCE_LIMIT)return 0;
        for(size_t j=0;j<d->binding_count;j++)if(d->bindings[j].id==id&&d->bindings[j].length)used=1;
        if(reference_same_root(cut,id,d->index_binding.id)!=0)return 0;
        for(unsigned stage=0;stage<2;stage++){
            if(d->layout.constant_count[stage]>FF_CONSTANT_RESOURCE_LIMIT||
               d->layout.arguments[stage].field_count>FF_SHADER_FIELD_LIMIT)return 0;
            for(size_t j=0;j<d->layout.constant_count[stage];j++)
                if(reference_same_root(cut,id,d->constants[stage][j].id)!=0)return 0;
            for(size_t j=0;j<d->layout.arguments[stage].field_count;j++)
                if(d->arguments[stage][j].kind==FF_FIELD_BUFFER&&
                   reference_same_root(cut,id,d->arguments[stage][j].buffer.id)!=0)return 0;
        }
    }
    return used;
}
#include "vertex_role_index.h"
#include "direct_pass_journal.h"
extern int fullframe_chunk_texture_has_prior_native_write(const ffs_producer_context *,const ffs_producer_resource *);
static unsigned vertex_role_mode(void){static unsigned mode;static dispatch_once_t once;
 dispatch_once(&once,^{const char *v=getenv("BEDROCK_NATIVE_VERTEX_ROLE_INDEX");mode=v&&!strcmp(v,"1")?1:v&&!strcmp(v,"2")?2:0;});return mode;}
static int payload_filter(const struct ff_draw_cut *cut,void *opaque){
    const char *live=getenv("BEDROCK_LIVE_COMMANDS");if(live&&!strcmp(live,"1")){fprintf(stderr,"[live-command-reject] reason=forbidden-capture-entry\n");abort();}
    struct payload_context *p=opaque;const ffs_producer_context *c=p->producer;
    p->filter_called=1;p->cut_id=cut->capture_id;p->cut_draws=cut->draw_count;p->cut_buffers=cut->snapshot_count;p->cut_textures=cut->texture_count;
    p->cut_snapshot_bytes=cut->snapshot_bytes;p->cut_stop=cut->stop_reason;p->cut_command=cut->stop_command_type;p->cut_detail=cut->resource_detail;
    if(!cut->complete_pass){p->reject_reason="incomplete-cut";return 0;}
    FFSTPassRecord *record=fullframe_frame_capture_record(p->command,p->info,p->info->bedrock_cut_commands.ptr,cut);
    if(!record){p->reject_reason="capture-record";return 0;}
    const ffs_producer_resource *refs=c->resources.ptr;
    uint16_t callback_snapshots[DS_MAX_SNAPSHOTS],callback_textures[DS_MAX_TEXTURES];
    const char *callback_option=getenv("BEDROCK_PRIVATE_CALLBACK_SIDECAR");
    p->callback_mode=callback_option&&!strcmp(callback_option,"1")?1:callback_option&&!strcmp(callback_option,"2")?2:0;
    int callback_collect=p->callback_mode&&c->resource_count<=DS_MAX_RESOURCES&&
        cut->snapshot_count<=DS_MAX_SNAPSHOTS&&cut->texture_count<=DS_MAX_TEXTURES&&c->command_count<=DS_MAX_COMMANDS;
    NSMutableArray *resources=[NSMutableArray array],*buffers=[NSMutableArray array],*textures=[NSMutableArray array],*attachments=[NSMutableArray array],*commands=[NSMutableArray array];
    if(!add_references(p,resources,attachments)){p->reject_reason="resource-reference";return 0;}
    /* Small passes retain the linear path; allocation failure also falls back
     * to the original matching rules rather than rejecting the capture. */
    struct ff_payload_ref_index *index=NULL;
    if(c->resource_count>=32&&(cut->snapshot_count>=8||cut->texture_count>=4)){
        index=malloc(sizeof(*index));
        if(index&&!ff_payload_ref_build(index,refs,c->resource_count,payload_texture_id,cut->texture_count!=0)){
            free(index);index=NULL;
        }
    }
    const char *refOption=getenv("BEDROCK_NATIVE_BUFFER_REF_EXPERIMENT");
    const char *typedOption=getenv("BEDROCK_FULLFRAME_TYPED_METADATA");
    int refMode=p->directory < -1&&refOption&&!strcmp(refOption,"1")&&typedOption&&!strcmp(typedOption,"1")&&
        fullframe_chunk_buffer_has_prior_native_write&&fullframe_native_buffer_ref_authority&&
        ffmd_encode_graph&&ffmd_encode_sidecar&&
        (fullframe_write_resource_cut_to_owned_sink||fullframe_write_resource_cut_typed_to_sink)&&
        cut->snapshot_bytes<=FF_VERTEX_BYTES_LIMIT&&c->stream&&c->frame&&c->chunk&&p->payload;
    ff_vertex_role_index role_index;unsigned role_mode=refMode?vertex_role_mode():0;
    int role_ready=role_mode&&ff_vertex_roles_build(cut,&role_index);
    const char *diagnostic=getenv("BEDROCK_BOUNDARY_REFERENCE");
    NSMutableArray *debugBuffers=diagnostic&&!strcmp(diagnostic,"1")&&!chunk_mode()&&cut->draw_count>=100?[NSMutableArray array]:nil;
    RORange observed[FF_DRAW_RESOURCE_LIMIT];size_t observed_count=0;
    for(size_t i=0;i<cut->snapshot_count;i++){
        const ffs_producer_resource *match=index?ff_payload_ref_buffer(index,refs,cut->source_incarnation[i],
            cut->source_generation[i],cut->source_offset[i],cut->source_length[i]):NULL;
        if(!index)for(size_t j=0;j<c->resource_count;j++)if(refs[j].kind==FFS_BUFFER&&refs[j].root==cut->source_incarnation[i]&&
            refs[j].allocation_generation==cut->source_generation[i]&&(refs[j].flags&FFS_READ)&&
            cut->source_offset[i]>=refs[j].offset&&cut->source_offset[i]-refs[j].offset<=refs[j].length&&
            cut->source_length[i]<=refs[j].length-(cut->source_offset[i]-refs[j].offset)){match=&refs[j];break;}
        if(!match){free(index);p->reject_reason="buffer-reference";p->reject_index=i;return 0;}
        /* Only a version-one read can use a sealed CPU preimage. Any ordered
         * GPU mutation, unknown identity, or later writer keeps GPU acquisition. */
        if(match->input_content_version==1&&match->output_content_version==1&&!(match->flags&FFS_WRITE))
            ((struct ff_draw_cut *)cut)->direct_eligible[i]=1;
        int vertex_only=0;
        if(refMode&&match->handle&&match->input_content_version){
            vertex_only=ffjp_enabled()?1:role_ready?ff_vertex_role_only(&role_index,cut->snapshot_count,i):reference_vertex_only(cut,i);
            if(!ffjp_enabled()&&role_mode==1&&vertex_only!=reference_vertex_only(cut,i)){
                free(index);p->reject_reason="vertex-role-parity";p->reject_index=i;return 0;}
        }
        if(vertex_only){
            ffs_producer_resource exact=*match;exact.offset=cut->source_offset[i];exact.length=cut->source_length[i];
            if(fullframe_chunk_buffer_has_prior_native_write(c,&exact)&&fullframe_native_buffer_ref_authority(c,&exact)==1){
                struct ff_draw_cut *mutableCut=(struct ff_draw_cut *)cut;
                mutableCut->reference_input_version[i]=match->input_content_version;
                mutableCut->reference_source_handle[i]=match->handle;
                mutableCut->reference_stream=c->stream;mutableCut->reference_frame=c->frame;
                mutableCut->reference_chunk=c->chunk;mutableCut->reference_payload=p->payload;
            }
        }
        if(callback_collect)callback_snapshots[i]=(uint16_t)(match-refs);
        NSDictionary *d=reference_with_id(resources[(NSUInteger)(match-refs)],i+1);if(!d){free(index);p->reject_reason="buffer-reference";return 0;}[buffers addObject:d];
        if(debugBuffers)[debugBuffers addObject:@{@"buffer":(id)match->handle,@"id":@(i+1),@"source_offset":@(cut->source_offset[i]),@"length":@(cut->source_length[i])}];
        if(observed_count<FF_DRAW_RESOURCE_LIMIT)observed[observed_count++]=(RORange){match->root,match->allocation_generation,(uint64_t)match->handle,cut->source_offset[i],cut->source_length[i]};
        p->buffer_memo_roots[i]=memo_root(match);
    }
    if(role_ready){static _Thread_local uint64_t passes,snapshots;passes++;snapshots+=cut->snapshot_count;
        if(passes<=2||!(passes%256))fprintf(stderr,"[vertex-role-index] mode=%u passes=%llu snapshots=%llu\n",role_mode,(unsigned long long)passes,(unsigned long long)snapshots);}
    retained_observer_pass(observed,observed_count);
    uint64_t reused_texture_bytes=0;
    for(size_t i=0;i<cut->texture_count;i++){
        const ffs_producer_resource *match=index?ff_payload_ref_texture(index,refs,cut->source_texture_ids[i]):NULL;
        if(!index)for(size_t j=0;j<c->resource_count;j++)if(refs[j].kind==FFS_TEXTURE&&((id<MTLTexture>)refs[j].handle).gpuResourceID._impl==cut->source_texture_ids[i]){match=&refs[j];break;}
        if(!match){free(index);p->reject_reason="texture-reference";p->reject_index=i;return 0;}
        if(ffjp_enabled()&&fullframe_chunk_texture_has_prior_native_write(c,match))
            ((struct ff_draw_cut *)cut)->direct_texture_versions[i]=match->input_content_version;
        if(callback_collect)callback_textures[i]=(uint16_t)(match-refs);
        int texture_written=index?ff_payload_ref_texture_written(index,refs,match->root,match->allocation_generation):0;
        if(!index)for(size_t j=0;j<c->resource_count;j++)if(refs[j].kind==FFS_TEXTURE&&refs[j].root==match->root&&
            refs[j].allocation_generation==match->allocation_generation&&(refs[j].flags&FFS_WRITE)){
                texture_written=1;break;}
        if(texture_written){free(index);p->reject_reason="texture-read-write";p->reject_index=i;return 0;}
        NSDictionary *d=reference_with_id(resources[(NSUInteger)(match-refs)],i+1);if(!d){free(index);p->reject_reason="texture-reference";return 0;}[textures addObject:d];
        char name[64];snprintf(name,sizeof(name),"cut-texture-%02zu.bin",i+1);
        if(!memo_identity(p->directory,name,match,0,cut->textures[i].length)){free(index);p->reject_reason="texture-memo";p->reject_index=i;return 0;}
        if(cut->texture_reuse&&fullframe_chunk_private_texture){
            id owner=fullframe_chunk_private_texture(p->directory,name,match,&cut->textures[i]);
            if(owner){cut->texture_reuse[@(i)]=owner;
                if(fullframe_chunk_retain_texture_budget&&fullframe_chunk_release_texture_budget&&
                   fullframe_chunk_retain_texture_budget(p->directory,name,owner))reused_texture_bytes+=cut->textures[i].length;
                [owner release];}}
    }
    free(index);
    const struct wmtcmd_base *command=p->info->bedrock_cut_commands.ptr;
    for(size_t i=0;i<c->command_count;i++){if(!command){p->reject_reason="command-count";p->reject_index=i;return 0;}[commands addObject:@(command->type)];command=command->next.ptr;}
    if(command){p->reject_reason="command-count";p->reject_index=c->command_count;return 0;}
    NSMutableDictionary *bindings=header(c,p->payload,@"bedrock-native-frame-pass");
    [bindings addEntriesFromDictionary:@{@"pass_manifest":@"replay.json",@"resource_manifest":@"draw-resource-cut.json",@"resources":resources,
        @"snapshots":buffers,@"textures":textures,@"attachments":attachments,@"command_types":commands}];
    uint64_t bytes=cut->snapshot_bytes+24u*1024u*1024u;
    p->extended=p->directory < -1&&cut->snapshot_bytes>FF_VERTEX_BYTES_LIMIT;
    /* Reserve the full page-rounded backing even if the arena supplies a view.
     * Extended cuts copy on transport and do not credit those arena views. */
    if(p->extended)for(size_t i=0;i<cut->snapshot_count;i++){
        uint64_t length=cut->source_length[i],rounded=0;
        if(!ff_draw_mapped_size(length,&rounded)||rounded-length>UINT64_MAX-bytes){p->reject_reason="buffer-allocation-estimate";return 0;}
        bytes+=rounded-length;
    }
    for(size_t i=0;i<cut->texture_count;i++){
        uint64_t length=cut->textures[i].length;
        if(length>UINT64_MAX-bytes){p->reject_reason="texture-allocation-estimate";return 0;}bytes+=length;
        if(p->extended&&!cut->texture_reuse[@(i)]){
            uint64_t rounded=0;
            if(!ff_draw_mapped_size(length,&rounded)||rounded-length>UINT64_MAX-bytes){p->reject_reason="texture-allocation-estimate";return 0;}
            bytes+=rounded-length;
        }
    }
    bytes-=reused_texture_bytes; /* Exact owners remain charged as memo through transport. */
    /* During fallback transport the source staging and its copied immutable
     * compacted blobs coexist. Reserve their maximum wire-sized overlap before
     * allocating extended staging, including copied texture payloads. */
    if(p->extended){
        uint64_t overlap=FF_VERTEX_BYTES_LIMIT;
        for(size_t i=0;i<cut->texture_count;i++){
            if(cut->textures[i].length>UINT64_MAX-overlap){p->reject_reason="staging-overlap";return 0;}
            overlap+=cut->textures[i].length;
        }
        if(overlap>UINT64_MAX-bytes){p->reject_reason="staging-overlap";return 0;}bytes+=overlap;
    }
    for(NSData *data in record.libraries.allValues)bytes+=data.length;
    for(size_t i=0;i<p->load_count;i++)bytes+=p->loads[i].texture.allocatedSize;
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();int allowed=!failed&&budget_allows_locked(bytes);
    if(allowed){reserved_bytes+=bytes;pending++;p->reserved=1;p->reservation=bytes;}
    else{p->reject_reason=failed?"source-failed":"budget";p->budget_requested=bytes;p->budget_reserved=reserved_bytes;
        p->budget_shared=shared_bytes;p->budget_memo=memo_bytes;p->budget_arena=snapshot_arena_bytes;}
    pthread_mutex_unlock(&guard);if(!allowed)return 0;
    if(debugBuffers){[boundary_pass_buffers release];boundary_pass_buffers=[debugBuffers copy];}
    if(debugBuffers){[boundary_pass_state release];boundary_pass_state=[record.manifest copy];}
    p->record=[record retain];p->bindings=[bindings copy];p->filter_accepted=1;
    if(callback_collect&&p->bindings)callback_take_lease(p,c,cut->capture_id,callback_snapshots,cut->snapshot_count,callback_textures,cut->texture_count);
    return 1;
}
extern int fullframe_boundary_inprocess(int,int,NSDictionary *,uint64_t,const void *) __attribute__((weak_import));
static void payload_complete(struct ff_draw_cut *cut,int ok,void *opaque){
    struct payload_context *p=opaque;uint64_t queued=payload_profile_now();
    uint64_t workload=0;
    for(size_t i=0;i<cut->snapshot_count;i++)workload=MAX(workload,cut->source_length[i]);
    for(size_t i=0;i<cut->texture_count;i++)workload=MAX(workload,cut->textures[i].length);
    dispatch_async(payload_io(p->directory,workload),^{@autoreleasepool{
        int permit=p->directory < -1&&fullframe_chunk_serializer_enter&&fullframe_chunk_serializer_leave;
        if(permit)fullframe_chunk_serializer_enter();payload_test_event(p->directory,0);
        payload_profile_token(p->directory,FFSC_PROFILE_IO_WAIT,payload_profile_elapsed(queued),0,1);
        uint64_t started=payload_profile_now();
        uint64_t compact_started=payload_profile_now();
        int prepared=ff_draw_cut_compact_for_wire(cut,ok);
        if(ok)payload_profile_token(p->directory,FFSC_PROFILE_COMPACT,payload_profile_elapsed(compact_started),0,1);
        for(size_t i=0;prepared&&p->directory < -1&&fullframe_chunk_blob_identity&&i<cut->snapshot_count;i++){
            if(cut->direct_pass||cut->reference_input_version[i]||!p->buffer_memo_roots[i])continue;
            char name[64];snprintf(name,sizeof(name),"cut-buffer-%02zu.bin",i+1);
            uint64_t length=cut->compacted?cut->serialized_length[i]:cut->source_length[i];
            prepared=fullframe_chunk_blob_identity(p->directory,name,FFS_BUFFER,p->buffer_memo_roots[i],0,cut->source_offset[i],length);
        }
        int owned=!p->extended&&p->directory< -1&&fullframe_write_resource_cut_to_owned_sink&&
            fullframe_chunk_blob_write_completed_snapshot&&fullframe_chunk_payload_retained_limit;
        if(prepared&&owned)prepared=fullframe_chunk_payload_retained_limit(p->directory,p->reservation);
        const char *typedOption=getenv("BEDROCK_FULLFRAME_TYPED_METADATA");
        int typed=p->directory< -1&&typedOption&&!strcmp(typedOption,"1")&&
            (owned||fullframe_write_resource_cut_typed_to_sink)&&ffmd_encode_graph&&ffmd_encode_sidecar;NSData *plan=nil;
        int success=prepared&&(p->directory< -1?
            (owned?fullframe_write_resource_cut_to_owned_sink(cut,p->record,typed?p->bindings:nil,typed?&plan:NULL,
                ok,chunk_sink,chunk_snapshot_sink,(void *)(intptr_t)p->directory):
             typed?fullframe_write_resource_cut_typed_to_sink(cut,p->record,p->bindings,&plan,ok,chunk_sink,(void *)(intptr_t)p->directory):
                fullframe_write_resource_cut_to_sink(cut,p->record,ok,chunk_sink,(void *)(intptr_t)p->directory)):
            fullframe_write_resource_cut(p->directory,cut,p->record,ok));
        uint64_t sidecar_started=payload_profile_now();
        if(success&&plan){
            NSData *wire=nil;
            if(p->callback_mode){
                NSData *candidate=nil;
                @autoreleasepool{candidate=[cb_encode(p->callback_lease,p->bindings,cut->capture_id,plan) retain];}
                if(p->callback_mode==2&&candidate){wire=[[candidate retain] autorelease];success=1;callback_report(1);}
                else{
                    success=ffmd_encode_sidecar(p->bindings,cut->capture_id,plan,&wire);
                    if(p->callback_mode==1&&candidate){
                        if(success&&[candidate isEqualToData:wire])callback_report(2);else callback_report(3);
                    }else callback_report(0);
                }
                [candidate release];
            }else success=ffmd_encode_sidecar(p->bindings,cut->capture_id,plan,&wire);
            if(success){
                NSDictionary *envelope=@{@"format":@"bedrock-native-frame-pass",@"version":@2,
                    @"stream":p->bindings[@"stream"],@"frame":p->bindings[@"frame"],@"chunk":p->bindings[@"chunk"],
                    @"encoder":p->bindings[@"encoder"],@"category":p->bindings[@"category"],
                    @"payload_id":p->bindings[@"payload_id"],@"pass_manifest":@"replay.json",
                    @"resource_manifest":@"draw-resource-cut.json",@"wire_blob":@"bindings.bin",
                    @"wire_sha256":metadata_digest(wire),@"plan_sha256":metadata_digest(plan)};
                success=write_bytes(p->directory,"bindings.bin",wire.bytes,wire.length)&&
                    write_json(p->directory,"bindings.json",envelope);
            }
        }else if(success)success=write_json(p->directory,"bindings.json",p->bindings);
        if(success)payload_profile_token(p->directory,FFSC_PROFILE_SIDECAR,payload_profile_elapsed(sidecar_started),0,1);
        uint64_t bytes=success?directory_bytes(p->directory):UINT64_MAX;
        payload_profile_token(p->directory,FFSC_PROFILE_SERIALIZE,payload_profile_elapsed(started),bytes==UINT64_MAX?0:bytes,1);
        /* The original GPU staging remains charged until it is actually freed;
         * the chunk retains only the serialized immutable prefixes after this. */
        if(!success||bytes==UINT64_MAX||bytes>p->reservation)payload_fail_fast(p->directory);
        const char *boundary=getenv("BEDROCK_BOUNDARY_REFERENCE");
        if(success&&p->directory>=0&&boundary&&!strcmp(boundary,"1")&&fullframe_boundary_inprocess&&cut->draw_count>=100&&
           [p->record.manifest[@"attachments"][@"color_load"] unsignedIntegerValue]==MTLLoadActionClear)
            success=fullframe_boundary_inprocess(root_directory,p->directory,p->record.manifest,p->payload,cut)&&success;
        ff_draw_cut_destroy(cut);
        callback_drop_lease(p);
        if(!success&&fullframe_chunk_release_texture_budget)fullframe_chunk_release_texture_budget(p->directory);
        pthread_mutex_lock(&guard);
        int rejected=!payload_fits_locked(success,bytes,p->reservation);
        if(rejected){
            fprintf(stderr,"[full-frame-payload-complete-reject] payload=%llu stream=%llu frame=%llu chunk=%llu encoder=%llu gpu_ok=%d write_ok=%d bytes=%llu reservation=%llu stored=%llu\n",
                (unsigned long long)p->payload,[p->bindings[@"stream"] unsignedLongLongValue],[p->bindings[@"frame"] unsignedLongLongValue],
                [p->bindings[@"chunk"] unsignedLongLongValue],[p->bindings[@"encoder"] unsignedLongLongValue],ok,success,
                (unsigned long long)bytes,(unsigned long long)p->reservation,(unsigned long long)stored_bytes);failed=1;
        }
        else{stored_bytes+=bytes;register_payload(p->directory,p->payload,"render");}
        if(!rejected){reserved_bytes-=p->reservation;reserved_bytes+=bytes;}
        /* Failed payloads can retain partially written snapshot owners until
         * source shutdown, so keep their remaining reservation charged. */
        if(pending)pending--;pthread_mutex_unlock(&guard);
        if(rejected&&p->directory < -1&&fullframe_chunk_source_serialization_failed)
            fullframe_chunk_source_serialization_failed();
        else if(fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
        payload_test_event(p->directory,1);if(permit)fullframe_chunk_serializer_leave();
        payload_close(p->directory);[p->record release];[p->bindings release];free(p);finish_if_ready();
    }});
}

static uint64_t utility_payload(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info,
    const ffs_producer_context *c,uint64_t payload,int directory){
    if(!info||c->command_count||info->visibility_buffer||info->render_target_array_length>1||
       info->tile_width||info->tile_height||info->bedrock_cut_fence_count>FF_DRAW_FENCE_LIMIT){payload_close(directory);return 0;}
    id<MTLTexture> color=(id<MTLTexture>)info->colors[0].texture,depth=(id<MTLTexture>)info->depth.texture,stencil=(id<MTLTexture>)info->stencil.texture;
    id<MTLTexture> target=color?:depth?:stencil;
    if(!target||!target.width||!target.height||target.width>8192||target.height>8192||
       (c->category==FFS_RESOLVE&&(!color||!info->colors[0].resolve_texture))){payload_close(directory);return 0;}
    struct payload_context p={.command=command,.info=info,.producer=c,.payload=payload,.directory=directory};
    NSMutableArray *resources=[NSMutableArray array],*attachments=[NSMutableArray array];
    if(!add_references(&p,resources,attachments)){payload_close(directory);return 0;}
    NSString *cut=[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)payload];
    NSDictionary *attachment=@{@"width":@(target.width),@"height":@(target.height),@"device_id":@(target.device.registryID),
        @"pixel_format":@(color.pixelFormat),@"samples":@(target.sampleCount),@"color_load":@(info->colors[0].load_action),
        @"color_store":@(info->colors[0].store_action),@"clear":color?@[@(info->colors[0].clear_color.r),@(info->colors[0].clear_color.g),@(info->colors[0].clear_color.b),@(info->colors[0].clear_color.a)]:@[@0,@0,@0,@0],
        @"depth_format":@(depth.pixelFormat),@"depth_load":@(info->depth.load_action),@"depth_store":@(info->depth.store_action),
        @"depth_clear":@(depth?info->depth.clear_depth:1),@"stencil_format":@(stencil.pixelFormat),@"stencil_load":@(info->stencil.load_action),
        @"stencil_store":@(info->stencil.store_action),@"stencil_clear":@(info->stencil.clear_stencil),@"depth_stencil_alias":@(depth&&depth==stencil)};
    NSDictionary *manifest=@{@"format":@"bedrock-native-pass-replay",@"version":@2,@"cut_id":@(payload),@"resource_cut_id":cut,
        @"attachments":attachment,@"pipelines":@[],@"draws":@[],@"complete_pass":@YES,@"contains_geometry_candidate":@NO,
        @"material_draw_count":@0,@"material_geometry_draw_count":@0,@"vertex_invocations":@0,@"captured_prefix_draws":@0};
    NSDictionary *graph=@{@"format":@"bedrock-draw-resource-cut",@"version":@2,@"cut_id":cut,@"snapshots":@[],@"textures":@[],
        @"samplers":@[],@"draws":@[],@"draw_count":@0,@"complete_pass":@YES,@"stop_reason":@0,@"stop_command_type":@(UINT32_MAX),@"resource_detail":@0};
    NSMutableDictionary *bindings=header(c,payload,@"bedrock-native-frame-pass");
    [bindings addEntriesFromDictionary:@{@"resources":resources,@"attachments":attachments,@"snapshots":@[],@"textures":@[],
        @"command_types":@[],@"pass_manifest":@"replay.json",@"resource_manifest":@"draw-resource-cut.json"}];
    uint64_t started=payload_profile_now();
    int ok=write_json(directory,"draw-resource-cut.json",graph)&&write_json(directory,"replay.json",manifest)&&write_json(directory,"bindings.json",bindings);
    uint64_t bytes=ok?directory_bytes(directory):UINT64_MAX,estimated=bytes;
    payload_profile_token(directory,FFSC_PROFILE_SERIALIZE,payload_profile_elapsed(started),bytes==UINT64_MAX?0:bytes,1);payload_close(directory);
    if(ok)for(size_t i=0;i<p.load_count;i++){
        uint64_t available=FRAME_BYTES-snapshot_arena_bytes;
        if(estimated>available||p.loads[i].texture.allocatedSize>available-estimated){ok=0;break;}estimated+=p.loads[i].texture.allocatedSize;
    }
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();ok=ok&&!failed&&budget_allows_locked(estimated);
    if(ok)reserved_bytes+=estimated;pthread_mutex_unlock(&guard);if(!ok)return 0;
    if(p.load_count){
        FFSTAttachmentCapture capture=attachment_state(command.device);id<MTLFence> ready=nil;
        id<MTLFence> fences[FF_DRAW_FENCE_LIMIT];for(size_t i=0;i<info->bedrock_cut_fence_count;i++)fences[i]=(id<MTLFence>)info->bedrock_cut_fences[i];
        if(!capture||!ffst_attachment_capture_schedule(capture,command,payload,p.loads,p.load_count,fences,info->bedrock_cut_fence_count,&ready,
            ^(uint64_t cut_id,FFSTResult result){if(result!=FFST_OK)fprintf(stderr,"[full-frame-utility-load] cut=%llu result=%u\n",(unsigned long long)cut_id,(unsigned)result);}))return 0;
        info->bedrock_cut_magic=UINT64_C(0x4244464355543033);info->bedrock_cut_ready_fence=(obj_handle_t)ready;
        pthread_mutex_lock(&guard);refresh_shared_bytes_locked();pthread_mutex_unlock(&guard);
    }
    pthread_mutex_lock(&guard);reserved_bytes-=estimated;
    if(!failed){stored_bytes+=bytes;reserved_bytes+=bytes;register_payload(directory,payload,"render");}
    else ok=0;
    pthread_mutex_unlock(&guard);
    return ok?payload:0;
}

struct operation_capture {
    uint64_t payload,reservation,serialization_bytes;
    int directory;
    NSDictionary *bindings;
    NSArray *imports;
    size_t count;
    id<MTLBuffer> *snapshots;
    ffsa_extent_desc *shared_extents;
    id<MTLFence> ready;
    int gpu_callback;
};
static void operation_complete(struct operation_capture *p,int gpu_ok){
    uint64_t queued=payload_profile_now();
    dispatch_async(payload_io(p->directory,p->serialization_bytes),^{@autoreleasepool{
        int permit=p->directory < -1&&fullframe_chunk_serializer_enter&&fullframe_chunk_serializer_leave;
        if(permit)fullframe_chunk_serializer_enter();payload_test_event(p->directory,0);
        if(p->gpu_callback)payload_profile_token(p->directory,FFSC_PROFILE_IO_WAIT,payload_profile_elapsed(queued),0,1);
        uint64_t started=payload_profile_now();
        int ok=gpu_ok;
        /* GPU-completed operation buffer snapshots can own their immutable
         * bytes through packet consumption, under the existing retained cap. */
        int owned=ok&&p->count&&p->directory < -1&&fullframe_chunk_blob_write_completed_snapshot&&
            fullframe_chunk_payload_retained_limit&&fullframe_chunk_payload_retained_limit(p->directory,p->reservation);
        for(size_t i=0;ok&&i<p->count;i++){
            NSDictionary *entry=p->imports[i];const char *file=[entry[@"file"] UTF8String];
            size_t bytes=[entry[@"bytes"] unsignedLongLongValue];
            ok=p->snapshots[i].contents&&
                (p->shared_extents[i].lease.generation?
                    fullframe_chunk_blob_write_shared_snapshot(p->directory,file,p->snapshots[i],bytes,p->shared_extents[i]):
                    owned&&!strncmp(file,"operation-buffer-",17)?
                        fullframe_chunk_blob_write_completed_snapshot(p->directory,file,p->snapshots[i],bytes):
                        write_bytes(p->directory,file,p->snapshots[i].contents,bytes));
        }
        if(ok)ok=write_json(p->directory,"bindings.json",p->bindings);
        uint64_t bytes=ok?directory_bytes(p->directory):UINT64_MAX;
        payload_profile_token(p->directory,FFSC_PROFILE_SERIALIZE,payload_profile_elapsed(started),bytes==UINT64_MAX?0:bytes,1);
        if(!ok||bytes==UINT64_MAX||bytes>p->reservation)payload_fail_fast(p->directory);
        /* Borrowed owners remain retained and charged through transport. */
        if(p->snapshots)for(size_t i=0;i<p->count;i++)[p->snapshots[i] release];
        free(p->snapshots);p->snapshots=NULL;free(p->shared_extents);p->shared_extents=NULL;[p->ready release];p->ready=nil;
        pthread_mutex_lock(&guard);
        int rejected=!payload_fits_locked(ok,bytes,p->reservation);
        if(rejected){
            fprintf(stderr,"[full-frame-operation-complete-reject] payload=%llu stream=%llu frame=%llu chunk=%llu encoder=%llu gpu_ok=%d write_ok=%d bytes=%llu reservation=%llu stored=%llu\n",
                (unsigned long long)p->payload,[p->bindings[@"stream"] unsignedLongLongValue],[p->bindings[@"frame"] unsignedLongLongValue],
                [p->bindings[@"chunk"] unsignedLongLongValue],[p->bindings[@"encoder"] unsignedLongLongValue],gpu_ok,ok,
                (unsigned long long)bytes,(unsigned long long)p->reservation,(unsigned long long)stored_bytes);failed=1;
        }
        else{stored_bytes+=bytes;register_payload(p->directory,p->payload,"operation");}
        if(!rejected){reserved_bytes-=p->reservation;reserved_bytes+=bytes;}
        /* On terminal failure, keep the reservation covering any partially
         * published payload owners until source shutdown. */
        if(pending)pending--;pthread_mutex_unlock(&guard);
        if(rejected&&p->directory < -1&&fullframe_chunk_source_serialization_failed)fullframe_chunk_source_serialization_failed();
        else if(fullframe_chunk_source_budget_changed)fullframe_chunk_source_budget_changed();
        payload_test_event(p->directory,1);if(permit)fullframe_chunk_serializer_leave();
        [p->bindings release];[p->imports release];payload_close(p->directory);free(p);finish_if_ready();
    }});
}
static uint64_t operation_reject(const ffs_producer_context *c,uint64_t payload,int directory,
    const char *reason,uint64_t command_index,uint32_t command_type,uint64_t resource){
    pthread_mutex_lock(&guard);uint64_t reserved=reserved_bytes,stored=stored_bytes,shared=shared_bytes;int failure=failed;pthread_mutex_unlock(&guard);
    fprintf(stderr,"[full-frame-operation-reject] reason=%s payload=%llu category=%u stream=%llu frame=%llu chunk=%llu encoder=%u commands=%llu resources=%llu dependencies=%llu command=%llu type=%u resource=%llu reserved=%llu stored=%llu shared=%llu failed=%d types=",
        reason,(unsigned long long)payload,c->category,(unsigned long long)c->stream,(unsigned long long)c->frame,(unsigned long long)c->chunk,c->encoder,
        (unsigned long long)c->command_count,(unsigned long long)c->resource_count,(unsigned long long)c->dependency_count,
        (unsigned long long)command_index,command_type,(unsigned long long)resource,(unsigned long long)reserved,(unsigned long long)stored,(unsigned long long)shared,failure);
    const struct wmtcmd_base *next=c->commands.ptr;
    for(uint64_t i=0;next&&i<c->command_count&&i<32;i++,next=next->next.ptr)fprintf(stderr,"%s%u",i?",":"",next->type);
    if(c->command_count>32)fputs(",...",stderr);fputc('\n',stderr);
    if(resource<c->resource_count){
        const ffs_producer_resource *r=&((const ffs_producer_resource *)c->resources.ptr)[resource];
        fprintf(stderr,"[full-frame-operation-reject-resource] resource=%llu kind=%llu root=%llu view=%llu generation=%llu input=%llu output=%llu flags=%u offset=%llu length=%llu origin=%llu capacity=%llu\n",
            (unsigned long long)resource,(unsigned long long)r->kind,(unsigned long long)r->root,(unsigned long long)r->view,
            (unsigned long long)r->allocation_generation,(unsigned long long)r->input_content_version,(unsigned long long)r->output_content_version,r->flags,
            (unsigned long long)r->offset,(unsigned long long)r->length,(unsigned long long)r->buffer_base_offset,(unsigned long long)r->buffer_length);
        if(r->kind==FFS_BUFFER&&[(id)r->handle conformsToProtocol:@protocol(MTLBuffer)]){
            id<MTLBuffer> buffer=(id<MTLBuffer>)r->handle;
            fprintf(stderr,"[full-frame-operation-reject-buffer] resource=%llu actual_length=%llu storage=%lu cpu_visible=%d\n",
                (unsigned long long)resource,(unsigned long long)buffer.length,(unsigned long)buffer.storageMode,
                buffer.storageMode!=MTLStorageModePrivate&&buffer.contents!=NULL);
        }
    }
    if(command_type==WMTBlitCommandCopyFromBufferToBuffer&&command_index<c->command_count){
        const struct wmtcmd_base *next=c->commands.ptr;
        for(uint64_t i=0;next&&i<command_index;i++)next=next->next.ptr;
        if(next&&next->type==WMTBlitCommandCopyFromBufferToBuffer){
            const struct wmtcmd_blit_copy_from_buffer_to_buffer *copy=(const void *)next;
            fprintf(stderr,"[full-frame-operation-reject-copy] command=%llu source_offset=%llu destination_offset=%llu length=%llu",
                (unsigned long long)command_index,(unsigned long long)copy->src_offset,(unsigned long long)copy->dst_offset,(unsigned long long)copy->copy_length);
            if(resource+1<c->resource_count){const ffs_producer_resource *r=&((const ffs_producer_resource *)c->resources.ptr)[resource+1];
                fprintf(stderr," destination_root=%llu generation=%llu offset=%llu length=%llu origin=%llu capacity=%llu",
                    (unsigned long long)r->root,(unsigned long long)r->allocation_generation,(unsigned long long)r->offset,(unsigned long long)r->length,
                    (unsigned long long)r->buffer_base_offset,(unsigned long long)r->buffer_length);
            }fputc('\n',stderr);
        }
    }
    uint64_t texture_command=command_index;uint32_t texture_type=command_type;
    if(texture_type==UINT32_MAX&&resource<c->resource_count){
        const ffs_producer_resource *ref=&((const ffs_producer_resource *)c->resources.ptr)[resource];
        const struct wmtcmd_base *entry=c->commands.ptr;
        if(ref->kind==FFS_TEXTURE)for(uint64_t i=0;entry&&i<c->command_count;i++,entry=entry->next.ptr){
            if(entry->type==WMTBlitCommandCopyFromBufferToTexture&&((const struct wmtcmd_blit_copy_from_buffer_to_texture *)entry)->dst==ref->handle){
                texture_command=i;texture_type=entry->type;break;
            }
            if(entry->type==WMTBlitCommandCopyFromTextureToBuffer&&((const struct wmtcmd_blit_copy_from_texture_to_buffer *)entry)->src==ref->handle){
                texture_command=i;texture_type=entry->type;break;
            }
            if(entry->type==WMTBlitCommandCopyFromTextureToTexture){
                const struct wmtcmd_blit_copy_from_texture_to_texture *copy=(const void *)entry;
                if(copy->src==ref->handle||copy->dst==ref->handle){texture_command=i;texture_type=entry->type;break;}}
        }
    }
    if(texture_type==WMTBlitCommandCopyFromBufferToTexture&&texture_command<c->command_count){
        const struct wmtcmd_base *next=c->commands.ptr;
        for(uint64_t i=0;next&&i<texture_command;i++)next=next->next.ptr;
        if(next&&next->type==WMTBlitCommandCopyFromBufferToTexture){
            const struct wmtcmd_blit_copy_from_buffer_to_texture *copy=(const void *)next;
            fprintf(stderr,"[full-frame-operation-reject-buffer-texture] command=%llu source_offset=%llu row=%u image=%u size=%llux%llux%llu destination_slice=%u level=%u origin=%llux%llux%llu",
                (unsigned long long)texture_command,(unsigned long long)copy->src_offset,copy->bytes_per_row,copy->bytes_per_image,
                (unsigned long long)copy->size.width,(unsigned long long)copy->size.height,(unsigned long long)copy->size.depth,copy->slice,copy->level,
                (unsigned long long)copy->origin.x,(unsigned long long)copy->origin.y,(unsigned long long)copy->origin.z);
            id<MTLTexture> texture=(id<MTLTexture>)copy->dst;
            if([texture conformsToProtocol:@protocol(MTLTexture)]){
                MTLTextureSwizzleChannels s=texture.swizzle;
                fprintf(stderr," format=%lu type=%lu width=%lu height=%lu depth=%lu mips=%lu array=%lu samples=%lu storage=%lu framebuffer_only=%d parent=%d buffer_backed=%d base_mip=%lu base_slice=%lu swizzle=%u,%u,%u,%u",
                    (unsigned long)texture.pixelFormat,(unsigned long)texture.textureType,(unsigned long)texture.width,(unsigned long)texture.height,
                    (unsigned long)texture.depth,(unsigned long)texture.mipmapLevelCount,(unsigned long)texture.arrayLength,(unsigned long)texture.sampleCount,
                    (unsigned long)texture.storageMode,(int)texture.framebufferOnly,texture.parentTexture!=nil,texture.buffer!=nil,
                    (unsigned long)texture.parentRelativeLevel,(unsigned long)texture.parentRelativeSlice,(unsigned)s.red,(unsigned)s.green,(unsigned)s.blue,(unsigned)s.alpha);
            }else fputs(" destination_texture=invalid",stderr);
            fputc('\n',stderr);
        }
    }
    if(texture_type==WMTBlitCommandCopyFromTextureToBuffer&&texture_command<c->command_count){
        const struct wmtcmd_base *next=c->commands.ptr;
        for(uint64_t i=0;next&&i<texture_command;i++)next=next->next.ptr;
        if(next&&next->type==WMTBlitCommandCopyFromTextureToBuffer){
            const struct wmtcmd_blit_copy_from_texture_to_buffer *copy=(const void *)next;
            fprintf(stderr,"[full-frame-operation-reject-texture-buffer] command=%llu destination_offset=%llu row=%u image=%u size=%llux%llux%llu source_slice=%u level=%u origin=%llux%llux%llu",
                (unsigned long long)texture_command,(unsigned long long)copy->offset,copy->bytes_per_row,copy->bytes_per_image,
                (unsigned long long)copy->size.width,(unsigned long long)copy->size.height,(unsigned long long)copy->size.depth,copy->slice,copy->level,
                (unsigned long long)copy->origin.x,(unsigned long long)copy->origin.y,(unsigned long long)copy->origin.z);
            id<MTLTexture> texture=(id<MTLTexture>)copy->src;
            if([texture conformsToProtocol:@protocol(MTLTexture)]){
                MTLTextureSwizzleChannels s=texture.swizzle;
                fprintf(stderr," format=%lu type=%lu width=%lu height=%lu depth=%lu mips=%lu array=%lu samples=%lu storage=%lu framebuffer_only=%d parent=%d buffer_backed=%d base_mip=%lu base_slice=%lu swizzle=%u,%u,%u,%u",
                    (unsigned long)texture.pixelFormat,(unsigned long)texture.textureType,(unsigned long)texture.width,(unsigned long)texture.height,
                    (unsigned long)texture.depth,(unsigned long)texture.mipmapLevelCount,(unsigned long)texture.arrayLength,(unsigned long)texture.sampleCount,
                    (unsigned long)texture.storageMode,(int)texture.framebufferOnly,texture.parentTexture!=nil,texture.buffer!=nil,
                    (unsigned long)texture.parentRelativeLevel,(unsigned long)texture.parentRelativeSlice,(unsigned)s.red,(unsigned)s.green,(unsigned)s.blue,(unsigned)s.alpha);
            }else fputs(" source_texture=invalid",stderr);
            fputc('\n',stderr);
        }
    }
    if(texture_type==WMTBlitCommandCopyFromTextureToTexture&&texture_command<c->command_count){
        const struct wmtcmd_base *next=c->commands.ptr;for(uint64_t i=0;next&&i<texture_command;i++)next=next->next.ptr;
        if(next&&next->type==WMTBlitCommandCopyFromTextureToTexture){
            const struct wmtcmd_blit_copy_from_texture_to_texture *copy=(const void *)next;
            fprintf(stderr,"[full-frame-operation-reject-texture-texture] command=%llu source_slice=%u level=%u origin=%llux%llux%llu size=%llux%llux%llu destination_slice=%u level=%u origin=%llux%llux%llu\n",
                (unsigned long long)texture_command,copy->src_slice,copy->src_level,(unsigned long long)copy->src_origin.x,
                (unsigned long long)copy->src_origin.y,(unsigned long long)copy->src_origin.z,(unsigned long long)copy->src_size.width,
                (unsigned long long)copy->src_size.height,(unsigned long long)copy->src_size.depth,copy->dst_slice,copy->dst_level,
                (unsigned long long)copy->dst_origin.x,(unsigned long long)copy->dst_origin.y,(unsigned long long)copy->dst_origin.z);
            id<MTLTexture> textures[2]={(id<MTLTexture>)copy->src,(id<MTLTexture>)copy->dst};
            for(unsigned side=0;side<2;side++){id<MTLTexture> texture=textures[side];
                if(![texture conformsToProtocol:@protocol(MTLTexture)])continue;MTLTextureSwizzleChannels s=texture.swizzle;
                fprintf(stderr,"[full-frame-operation-reject-copy-texture-profile] side=%s format=%lu type=%lu width=%lu height=%lu depth=%lu mips=%lu array=%lu samples=%lu storage=%lu parent=%d buffer_backed=%d base_mip=%lu base_slice=%lu swizzle=%u,%u,%u,%u\n",
                    side?"destination":"source",(unsigned long)texture.pixelFormat,(unsigned long)texture.textureType,(unsigned long)texture.width,
                    (unsigned long)texture.height,(unsigned long)texture.depth,(unsigned long)texture.mipmapLevelCount,(unsigned long)texture.arrayLength,
                    (unsigned long)texture.sampleCount,(unsigned long)texture.storageMode,texture.parentTexture!=nil,texture.buffer!=nil,
                    (unsigned long)texture.parentRelativeLevel,(unsigned long)texture.parentRelativeSlice,s.red,s.green,s.blue,s.alpha);
            }
        }
    }
    payload_close(directory);return 0;
}
static int operation_texture_profile(id<MTLDevice> device,id<MTLTexture> texture){
    if(![texture conformsToProtocol:@protocol(MTLTexture)])return 0;
    MTLTextureSwizzleChannels s=texture.swizzle;
    int shape=texture.textureType==MTLTextureType2D||(texture.textureType==MTLTextureTypeCube&&texture.width==texture.height);
    return texture.device==device&&shape&&texture.arrayLength==1&&texture.sampleCount==1&&
        texture.depth==1&&texture.width&&texture.height&&texture.width<=4096&&texture.height<=4096&&
        texture.mipmapLevelCount&&texture.mipmapLevelCount<=13&&texture.storageMode!=MTLStorageModeMemoryless&&!texture.framebufferOnly&&
        !texture.parentTexture&&!texture.buffer&&!texture.parentRelativeLevel&&!texture.parentRelativeSlice&&ff_texture_pixel_size(texture.pixelFormat)&&
        s.red==MTLTextureSwizzleRed&&s.green==MTLTextureSwizzleGreen&&s.blue==MTLTextureSwizzleBlue&&s.alpha==MTLTextureSwizzleAlpha;
}
static NSUInteger operation_texture_slices(id<MTLTexture> texture){return texture.textureType==MTLTextureTypeCube?6:1;}
static int operation_texture_profile_2d(id<MTLDevice> device,id<MTLTexture> texture){
    return operation_texture_profile(device,texture)&&texture.textureType==MTLTextureType2D;
}
static NSString *operation_texture_key(const ffs_producer_resource *r){
    return [NSString stringWithFormat:@"%llu:%llu:%llu:%llu",(unsigned long long)r->root,
        (unsigned long long)r->allocation_generation,(unsigned long long)r->input_content_version,(unsigned long long)r->view];
}
static NSMutableDictionary *operation_texture_state(NSMutableDictionary *states,const ffs_producer_resource *refs,NSUInteger index){
    const ffs_producer_resource *r=&refs[index];NSString *key=operation_texture_key(r);NSMutableDictionary *state=states[key];
    if(!state){id<MTLTexture> texture=(id<MTLTexture>)r->handle;
        state=[NSMutableDictionary dictionaryWithDictionary:@{@"defined":[NSMutableIndexSet indexSet],
            @"planes":@(operation_texture_slices(texture)*texture.mipmapLevelCount),@"required":@NO}];states[key]=state;}
    return state;
}
/* Omit only a complete initial texture that the actual ordered type4 commands
 * prove unnecessary. A later full write cannot erase an earlier initial read
 * or partial write. Missing faces/mips remain required for future consumers.
 * Other texture operations deliberately keep their existing capture policy. */
static NSSet *operation_overwritten_textures(NSArray *operations,const ffs_producer_resource *refs){
    NSMutableDictionary *states=[NSMutableDictionary dictionary];
    for(NSDictionary *op in operations){NSString *name=op[@"op"];
        if([name isEqual:@"copy_texture_to_texture"]){
            NSUInteger source=[op[@"source_resource"]unsignedIntegerValue],destination=[op[@"destination_resource"]unsignedIntegerValue];
            id<MTLTexture> src=(id<MTLTexture>)refs[source].handle,dst=(id<MTLTexture>)refs[destination].handle;
            NSMutableDictionary *read=operation_texture_state(states,refs,source),*write=operation_texture_state(states,refs,destination);
            NSMutableIndexSet *sourceDefined=read[@"defined"],*destinationDefined=write[@"defined"];
            NSUInteger sourceMip=[op[@"source_level"]unsignedIntegerValue],destinationMip=[op[@"destination_level"]unsignedIntegerValue];
            NSUInteger sourcePlane=[op[@"source_slice"]unsignedIntegerValue]*src.mipmapLevelCount+sourceMip;
            NSUInteger destinationPlane=[op[@"destination_slice"]unsignedIntegerValue]*dst.mipmapLevelCount+destinationMip;
            if(![sourceDefined containsIndex:sourcePlane])read[@"required"]=@YES;
            NSArray *origin=op[@"destination_origin"],*size=op[@"source_size"];
            int full=![origin[0]unsignedLongLongValue]&&![origin[1]unsignedLongLongValue]&&![origin[2]unsignedLongLongValue]&&
                [size[0]unsignedLongLongValue]==MAX((NSUInteger)1,dst.width>>destinationMip)&&
                [size[1]unsignedLongLongValue]==MAX((NSUInteger)1,dst.height>>destinationMip)&&[size[2]unsignedLongLongValue]==1;
            if(full)[destinationDefined addIndex:destinationPlane];
            else if(![destinationDefined containsIndex:destinationPlane])write[@"required"]=@YES;
        }else if([name isEqual:@"copy_buffer_to_texture"]){
            operation_texture_state(states,refs,[op[@"destination_resource"]unsignedIntegerValue])[@"required"]=@YES;
        }else if([name isEqual:@"copy_texture_to_buffer"]){
            operation_texture_state(states,refs,[op[@"source_resource"]unsignedIntegerValue])[@"required"]=@YES;
        }
    }
    NSMutableSet *omitted=[NSMutableSet set];
    for(NSString *key in states){NSDictionary *state=states[key];NSMutableIndexSet *defined=state[@"defined"];NSUInteger planes=[state[@"planes"]unsignedIntegerValue];
        if(![state[@"required"]boolValue]&&planes&&[defined containsIndexesInRange:NSMakeRange(0,planes)])[omitted addObject:key];}
    return omitted;
}
static NSDictionary *operation_texture_import(id<MTLDevice> device,id<MTLTexture> texture,size_t resource,
    NSUInteger ordinal,uint64_t *total){
    if(!operation_texture_profile(device,texture)||ordinal>=FF_TEXTURE_RESOURCE_LIMIT)return nil;
    unsigned bpp=ff_texture_pixel_size(texture.pixelFormat);uint64_t length=0;NSMutableArray *planes=[NSMutableArray array];
    for(NSUInteger slice=0;slice<operation_texture_slices(texture);slice++)for(NSUInteger mip=0;mip<texture.mipmapLevelCount;mip++){
        NSUInteger width=MAX((NSUInteger)1,texture.width>>mip),height=MAX((NSUInteger)1,texture.height>>mip);
        uint64_t row=(width*bpp+255)&~UINT64_C(255),bytes=row*height;
        if(bytes>FF_TEXTURE_BYTES_LIMIT-length||bytes>FF_TEXTURE_BYTES_LIMIT-*total-length)return nil;
        [planes addObject:@{@"mip":@(mip),@"slice":@(slice),@"offset":@(length),@"row_bytes":@(row),@"length":@(bytes)}];length+=bytes;
    }
    *total+=length;
    return @{@"resource":@(resource),@"file":[NSString stringWithFormat:@"operation-texture-%02lu.bin",(unsigned long)ordinal+1],
        @"length":@(length),@"format":@(texture.pixelFormat),@"texture_type":@(texture.textureType),@"width":@(texture.width),@"height":@(texture.height),
        @"mip_count":@(texture.mipmapLevelCount),@"array_length":@1,@"swizzle":@[@(MTLTextureSwizzleRed),@(MTLTextureSwizzleGreen),@(MTLTextureSwizzleBlue),@(MTLTextureSwizzleAlpha)],@"planes":planes};
}
static uint64_t operation_payload(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info,
    const ffs_producer_context *c,uint64_t payload,int directory){
    NSMutableDictionary *bindings=header(c,payload,@"bedrock-native-frame-operation");bindings[@"device_id"]=@(command.device.registryID);
    NSMutableArray *resources=[NSMutableArray array],*types=[NSMutableArray array],*operations=[NSMutableArray array],*imports=[NSMutableArray array],*texture_imports=[NSMutableArray array],*readbacks=[NSMutableArray array];
    const ffs_producer_resource *refs=c->resources.ptr;
    for(size_t i=0;i<c->resource_count;i++){NSDictionary *r=reference(&refs[i],payload);if(!r)return operation_reject(c,payload,directory,"resource-reference",UINT64_MAX,UINT32_MAX,i);[resources addObject:r];}
    if(c->category==FFS_TIMESTAMP){
        if(c->resource_count||c->command_count||!c->query_count||c->query_count>1000000||c->readback_index>=1000000)return operation_reject(c,payload,directory,"timestamp-shape",UINT64_MAX,UINT32_MAX,UINT64_MAX);
        [operations addObject:@{@"op":@"timestamp",@"mode":@"command-buffer-end-ns",@"readback_index":@(c->readback_index),@"query_count":@(c->query_count)}];
    }else if(c->category==FFS_SIGNAL_EVENT){
        const ffs_producer_dependency *deps=c->dependencies.ptr;const ffs_producer_dependency *signal=NULL;
        for(size_t i=0;i<c->dependency_count;i++)if(deps[i].domain==FFS_EVENT&&deps[i].action==FFS_SIGNAL){if(signal)return operation_reject(c,payload,directory,"duplicate-event-signal",UINT64_MAX,UINT32_MAX,UINT64_MAX);signal=&deps[i];}
        if(c->resource_count||c->command_count||!signal||!signal->id||!signal->value)return operation_reject(c,payload,directory,"event-shape",UINT64_MAX,UINT32_MAX,UINT64_MAX);
        [operations addObject:@{@"op":@"signal_event",@"domain":@(signal->domain),@"id":@(signal->id),@"value":@(signal->value)}];
    }else{
        if(!info||info->bedrock_cut_fence_count>FF_DRAW_FENCE_LIMIT||!c->commands.ptr)return operation_reject(c,payload,directory,"blit-shape",UINT64_MAX,UINT32_MAX,UINT64_MAX);
        const struct wmtcmd_base *next=c->commands.ptr;size_t resource=0;
        for(size_t i=0;i<c->command_count;i++){
            if(!next)return operation_reject(c,payload,directory,"command-missing",i,UINT32_MAX,resource);[types addObject:@(next->type)];
            if(next->type==WMTBlitCommandNop)[operations addObject:@{@"op":@"nop"}];
            else if(next->type==WMTBlitCommandCopyFromBufferToBuffer){
                const struct wmtcmd_blit_copy_from_buffer_to_buffer *copy=(const void *)next;
                if(resource+1>=c->resource_count||refs[resource].kind!=FFS_BUFFER||refs[resource+1].kind!=FFS_BUFFER||
                   copy->src!=refs[resource].handle||copy->dst!=refs[resource+1].handle||
                   copy->src_offset<refs[resource].offset||copy->dst_offset<refs[resource+1].offset)return operation_reject(c,payload,directory,"copy-identity",i,next->type,resource);
                uint64_t src=copy->src_offset-refs[resource].offset,dst=copy->dst_offset-refs[resource+1].offset;
                if(src>refs[resource].length||dst>refs[resource+1].length||!copy->copy_length||
                   copy->copy_length>refs[resource].length-src||copy->copy_length>refs[resource+1].length-dst)return operation_reject(c,payload,directory,"copy-range",i,next->type,resource);
                [operations addObject:@{@"op":@"copy_buffer",@"source_resource":@(resource),@"destination_resource":@(resource+1),
                    @"source_offset":@(src),@"destination_offset":@(dst),@"length":@(copy->copy_length)}];resource+=2;
            }else if(next->type==WMTBlitCommandCopyFromBufferToTexture){
                const struct wmtcmd_blit_copy_from_buffer_to_texture *copy=(const void *)next;
                if(resource+1>=c->resource_count||refs[resource].kind!=FFS_BUFFER||refs[resource+1].kind!=FFS_TEXTURE||
                   copy->src!=refs[resource].handle||copy->dst!=refs[resource+1].handle||copy->src_offset<refs[resource].offset||
                   (refs[resource].flags&(FFS_READ|FFS_WRITE))!=FFS_READ||
                   (refs[resource+1].flags&(FFS_READ|FFS_WRITE))!=(FFS_READ|FFS_WRITE))
                    return operation_reject(c,payload,directory,"copy-buffer-texture-identity",i,next->type,resource);
                id<MTLTexture> texture=(id<MTLTexture>)copy->dst;
                if(!operation_texture_profile_2d(command.device,texture))return operation_reject(c,payload,directory,"copy-buffer-texture-profile",i,next->type,resource+1);
                unsigned bpp=ff_texture_pixel_size(texture.pixelFormat);uint64_t width=copy->size.width,height=copy->size.height;
                uint64_t row=copy->bytes_per_row,image=copy->bytes_per_image,offset=copy->src_offset-refs[resource].offset;
                uint64_t mip_width=copy->level<texture.mipmapLevelCount?MAX((NSUInteger)1,texture.width>>copy->level):0;
                uint64_t mip_height=copy->level<texture.mipmapLevelCount?MAX((NSUInteger)1,texture.height>>copy->level):0;
                if(!width||!height||copy->size.depth!=1||copy->slice||copy->origin.z||!mip_width||
                   width>mip_width||height>mip_height||copy->origin.x>mip_width-width||copy->origin.y>mip_height-height||
                   copy->src_offset%bpp||row<width*bpp||row%bpp||row>UINT64_MAX/height||
                   (image&&image<row*height)||offset>refs[resource].length||
                   (height-1)*row+width*bpp>refs[resource].length-offset)
                    return operation_reject(c,payload,directory,"copy-buffer-texture-range",i,next->type,resource);
                [operations addObject:@{@"op":@"copy_buffer_to_texture",@"source_resource":@(resource),@"destination_resource":@(resource+1),
                    @"source_offset":@(offset),@"source_bytes_per_row":@(row),@"source_bytes_per_image":@(image),
                    @"source_size":@[@(width),@(height),@1],@"destination_slice":@(copy->slice),@"destination_level":@(copy->level),
                    @"destination_origin":@[@(copy->origin.x),@(copy->origin.y),@0]}];resource+=2;
            }else if(next->type==WMTBlitCommandCopyFromTextureToBuffer){
                const struct wmtcmd_blit_copy_from_texture_to_buffer *copy=(const void *)next;
                if(resource+1>=c->resource_count||refs[resource].kind!=FFS_TEXTURE||refs[resource+1].kind!=FFS_BUFFER||
                   copy->src!=refs[resource].handle||copy->dst!=refs[resource+1].handle||copy->offset<refs[resource+1].offset||
                   (refs[resource].flags&(FFS_READ|FFS_WRITE))!=FFS_READ||
                   (refs[resource+1].flags&(FFS_READ|FFS_WRITE))!=(FFS_READ|FFS_WRITE))
                    return operation_reject(c,payload,directory,"copy-texture-buffer-identity",i,next->type,resource);
                id<MTLTexture> texture=(id<MTLTexture>)copy->src;
                if(!operation_texture_profile_2d(command.device,texture))return operation_reject(c,payload,directory,"copy-texture-buffer-profile",i,next->type,resource);
                unsigned bpp=ff_texture_pixel_size(texture.pixelFormat);uint64_t width=copy->size.width,height=copy->size.height;
                uint64_t row=copy->bytes_per_row,image=copy->bytes_per_image,offset=copy->offset-refs[resource+1].offset;
                uint64_t mip_width=copy->level<texture.mipmapLevelCount?MAX((NSUInteger)1,texture.width>>copy->level):0;
                uint64_t mip_height=copy->level<texture.mipmapLevelCount?MAX((NSUInteger)1,texture.height>>copy->level):0;
                if(!width||!height||copy->size.depth!=1||copy->slice||copy->origin.z||!mip_width||
                   width>mip_width||height>mip_height||copy->origin.x>mip_width-width||copy->origin.y>mip_height-height||
                   (copy->offset&3)||(row&3)||((width*bpp)&3)||row<width*bpp||row>UINT64_MAX/height||
                   (image&&image<row*height)||offset>refs[resource+1].length||
                   (height-1)*row+width*bpp>refs[resource+1].length-offset)
                    return operation_reject(c,payload,directory,"copy-texture-buffer-range",i,next->type,resource+1);
                [operations addObject:@{@"op":@"copy_texture_to_buffer",@"source_resource":@(resource),@"destination_resource":@(resource+1),
                    @"source_slice":@(copy->slice),@"source_level":@(copy->level),@"source_origin":@[@(copy->origin.x),@(copy->origin.y),@0],
                    @"source_size":@[@(width),@(height),@1],@"destination_offset":@(offset),
                    @"destination_bytes_per_row":@(row),@"destination_bytes_per_image":@(image)}];
                [readbacks addObject:@{@"command":@(i),@"resource":@(resource+1),@"offset":@(copy->offset),@"row_bytes":@(row),
                    @"row_length":@(width*bpp),@"row_count":@(height)}];resource+=2;
            }else if(next->type==WMTBlitCommandCopyFromTextureToTexture){
                const struct wmtcmd_blit_copy_from_texture_to_texture *copy=(const void *)next;
                if(resource+1>=c->resource_count||refs[resource].kind!=FFS_TEXTURE||refs[resource+1].kind!=FFS_TEXTURE||
                   copy->bedrock_copy_magic!=0x46545431||copy->bedrock_copy_reserved||
                   copy->bedrock_src_root!=refs[resource].root||copy->bedrock_src_view!=refs[resource].view||
                   copy->bedrock_src_generation!=refs[resource].allocation_generation||copy->bedrock_dst_root!=refs[resource+1].root||
                   copy->bedrock_dst_view!=refs[resource+1].view||copy->bedrock_dst_generation!=refs[resource+1].allocation_generation||
                   copy->src!=refs[resource].handle||copy->dst!=refs[resource+1].handle||
                   (refs[resource].flags&(FFS_READ|FFS_WRITE))!=FFS_READ||
                   (refs[resource+1].flags&(FFS_READ|FFS_WRITE))!=(FFS_READ|FFS_WRITE)||
                   refs[resource].input_content_version!=refs[resource].output_content_version||
                   refs[resource+1].input_content_version==UINT64_MAX||
                   refs[resource+1].output_content_version!=refs[resource+1].input_content_version+1)
                    return operation_reject(c,payload,directory,"copy-texture-identity",i,next->type,resource);
                id<MTLTexture> source=(id<MTLTexture>)copy->src,destination=(id<MTLTexture>)copy->dst;
                if(!operation_texture_profile(command.device,source)||!operation_texture_profile(command.device,destination)||source.pixelFormat!=destination.pixelFormat)
                    return operation_reject(c,payload,directory,"copy-texture-profile",i,next->type,resource);
                uint64_t width=copy->src_size.width,height=copy->src_size.height;
                uint64_t sw=copy->src_level<source.mipmapLevelCount?MAX((NSUInteger)1,source.width>>copy->src_level):0;
                uint64_t sh=copy->src_level<source.mipmapLevelCount?MAX((NSUInteger)1,source.height>>copy->src_level):0;
                uint64_t dw=copy->dst_level<destination.mipmapLevelCount?MAX((NSUInteger)1,destination.width>>copy->dst_level):0;
                uint64_t dh=copy->dst_level<destination.mipmapLevelCount?MAX((NSUInteger)1,destination.height>>copy->dst_level):0;
                if(!width||!height||copy->src_size.depth!=1||copy->src_slice>=operation_texture_slices(source)||
                   copy->dst_slice>=operation_texture_slices(destination)||copy->src_origin.z||copy->dst_origin.z||
                   !sw||!dw||width>sw||height>sh||width>dw||height>dh||copy->src_origin.x>sw-width||copy->src_origin.y>sh-height||
                   copy->dst_origin.x>dw-width||copy->dst_origin.y>dh-height)
                    return operation_reject(c,payload,directory,"copy-texture-range",i,next->type,resource);
                int same=refs[resource].root==refs[resource+1].root&&refs[resource].allocation_generation==refs[resource+1].allocation_generation;
                if(same||source==destination)return operation_reject(c,payload,directory,"copy-texture-alias",i,next->type,resource);
                [operations addObject:@{@"op":@"copy_texture_to_texture",@"source_resource":@(resource),@"destination_resource":@(resource+1),
                    @"source_slice":@(copy->src_slice),@"source_level":@(copy->src_level),
                    @"source_origin":@[@(copy->src_origin.x),@(copy->src_origin.y),@(copy->src_origin.z)],
                    @"source_size":@[@(width),@(height),@(copy->src_size.depth)],
                    @"destination_slice":@(copy->dst_slice),@"destination_level":@(copy->dst_level),
                    @"destination_origin":@[@(copy->dst_origin.x),@(copy->dst_origin.y),@(copy->dst_origin.z)]}];resource+=2;
            }else return operation_reject(c,payload,directory,"unsupported-command",i,next->type,resource);next=next->next.ptr;
        }
        if(next||resource!=c->resource_count)return operation_reject(c,payload,directory,"command-resource-count",c->command_count,next?next->type:UINT32_MAX,resource);
    }
    NSSet *overwritten=c->category==FFS_BLIT?operation_overwritten_textures(operations,refs):[NSSet set];
    uint64_t snapshot_bytes=0,texture_bytes=0,native_buffer_reuse=0,native_buffer_bytes=0;NSMutableSet *seen=[NSMutableSet set],*seen_textures=[NSMutableSet set];
    if(c->category==FFS_BLIT)for(size_t i=0;i<c->resource_count;i++)if(refs[i].flags&FFS_READ){
        if(refs[i].kind==FFS_TEXTURE){
            if(!operation_texture_profile(command.device,(id<MTLTexture>)refs[i].handle))
                return operation_reject(c,payload,directory,"texture-import-profile",UINT64_MAX,UINT32_MAX,i);
            NSString *key=operation_texture_key(&refs[i]);if([overwritten containsObject:key])continue;
            if([seen_textures containsObject:key])continue;[seen_textures addObject:key];
            NSDictionary *entry=operation_texture_import(command.device,(id<MTLTexture>)refs[i].handle,i,texture_imports.count,&texture_bytes);
            if(!entry)return operation_reject(c,payload,directory,"texture-import-budget",UINT64_MAX,UINT32_MAX,i);
            [texture_imports addObject:entry];continue;
        }
        if(refs[i].kind!=FFS_BUFFER)return operation_reject(c,payload,directory,"import-kind",UINT64_MAX,UINT32_MAX,i);
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu:%llu:%llu:%llu",(unsigned long long)refs[i].root,
            (unsigned long long)refs[i].allocation_generation,(unsigned long long)refs[i].input_content_version,
            (unsigned long long)refs[i].view,(unsigned long long)refs[i].offset,(unsigned long long)refs[i].length];
        if([seen containsObject:key])continue;[seen addObject:key];
        id<MTLBuffer> source=(id<MTLBuffer>)refs[i].handle;
        /* Rounding a byte copy can cross the backing allocation's final byte. */
        uint64_t length=refs[i].length;
        if(![source conformsToProtocol:@protocol(MTLBuffer)]||source.device!=command.device||!length||
           refs[i].offset>source.length||length>source.length-refs[i].offset)
            return operation_reject(c,payload,directory,"import-range",UINT64_MAX,UINT32_MAX,i);
        if(fullframe_chunk_buffer_has_prior_native_write&&fullframe_chunk_buffer_has_prior_native_write(c,&refs[i])){
            ++native_buffer_reuse;native_buffer_bytes+=length;continue;
        }
        if(length>FF_VERTEX_BYTES_LIMIT-snapshot_bytes)
            return operation_reject(c,payload,directory,"import-budget",UINT64_MAX,UINT32_MAX,i);
        snapshot_bytes+=length;NSString *file=[NSString stringWithFormat:@"operation-buffer-%02lu.bin",(unsigned long)imports.count+1];
        [imports addObject:@{@"resource":@(i),@"file":file,@"bytes":@(refs[i].length)}];
    }
    for(NSDictionary *readback in readbacks)if(fullframe_chunk_readback_register&&
        !fullframe_chunk_readback_register(c,payload,[readback[@"command"] unsignedIntValue],[readback[@"resource"] unsignedIntValue],
            [readback[@"offset"] unsignedLongLongValue],[readback[@"row_bytes"] unsignedLongLongValue],
            [readback[@"row_length"] unsignedLongLongValue],[readback[@"row_count"] unsignedLongLongValue]))
        return operation_reject(c,payload,directory,"readback-register",[readback[@"command"] unsignedLongLongValue],
            WMTBlitCommandCopyFromTextureToBuffer,[readback[@"resource"] unsignedLongLongValue]);
    [bindings addEntriesFromDictionary:@{@"resources":resources,@"command_types":types,@"operations":operations,@"buffers":imports}];
    if(texture_imports.count)bindings[@"textures"]=texture_imports;
    NSMutableArray *capture_imports=[NSMutableArray arrayWithArray:imports];
    for(NSDictionary *texture in texture_imports){NSMutableDictionary *entry=[[texture mutableCopy]autorelease];entry[@"bytes"]=texture[@"length"];[capture_imports addObject:entry];}
    for(NSDictionary *entry in capture_imports){const ffs_producer_resource *reference=&refs[[entry[@"resource"] unsignedIntegerValue]];
        uint64_t offset=reference->kind==FFS_BUFFER?reference->offset:0;
        if(!memo_identity(directory,[entry[@"file"] UTF8String],reference,offset,[entry[@"bytes"] unsignedLongLongValue]))
            return operation_reject(c,payload,directory,"memo-identity",UINT64_MAX,UINT32_MAX,[entry[@"resource"] unsignedLongLongValue]);
    }
    uint64_t reservation=snapshot_bytes+texture_bytes+8u*1024u*1024u;
    pthread_mutex_lock(&guard);refresh_shared_bytes_locked();int allowed=!failed&&budget_allows_locked(reservation);
    if(allowed){reserved_bytes+=reservation;pending++;}pthread_mutex_unlock(&guard);if(!allowed)return operation_reject(c,payload,directory,"budget",UINT64_MAX,UINT32_MAX,UINT64_MAX);
    struct operation_capture *p=calloc(1,sizeof(*p));
    if(!p){pthread_mutex_lock(&guard);reserved_bytes-=reservation;pending--;failed=1;pthread_mutex_unlock(&guard);return operation_reject(c,payload,directory,"capture-allocation",UINT64_MAX,UINT32_MAX,UINT64_MAX);}
    p->payload=payload;p->reservation=reservation;p->directory=directory;p->bindings=[bindings copy];p->imports=[capture_imports copy];p->count=capture_imports.count;
    for(NSDictionary *entry in capture_imports)p->serialization_bytes=MAX(p->serialization_bytes,[entry[@"bytes"] unsignedLongLongValue]);
    p->snapshots=calloc(MAX((size_t)1,p->count),sizeof(*p->snapshots));
    p->shared_extents=calloc(MAX((size_t)1,p->count),sizeof(*p->shared_extents));
    int allocated=p->snapshots!=NULL&&p->shared_extents!=NULL;
    for(size_t i=0;allocated&&i<p->count;i++){
        uint64_t bytes=[capture_imports[i][@"bytes"] unsignedLongLongValue];
        if(!capture_imports[i][@"planes"]&&directory< -1&&fullframe_chunk_snapshot_allocate&&
           fullframe_chunk_blob_write_shared_snapshot)
            p->snapshots[i]=fullframe_chunk_snapshot_allocate(directory,command.device,(size_t)bytes,&p->shared_extents[i]);
        if(!p->snapshots[i])p->snapshots[i]=[command.device newBufferWithLength:(NSUInteger)bytes options:MTLResourceStorageModeShared];
        if(!p->snapshots[i])allocated=0;
    }
    if(!allocated){operation_reject(c,payload,-1,"snapshot-allocation",UINT64_MAX,UINT32_MAX,UINT64_MAX);operation_complete(p,0);return 0;}
    if(directory < -1&&fullframe_chunk_blob_write_shared_snapshot)
        (void)credit_shared_extents(&p->reservation,p->shared_extents,p->count);
    if(p->count){
        p->ready=[command.device newFence];id<MTLBlitCommandEncoder> blit=p->ready?[command blitCommandEncoder]:nil;
        if(!blit){operation_reject(c,payload,-1,"snapshot-encoder",UINT64_MAX,UINT32_MAX,UINT64_MAX);operation_complete(p,0);return 0;}
        for(size_t i=0;i<info->bedrock_cut_fence_count;i++)[blit waitForFence:(id<MTLFence>)info->bedrock_cut_fences[i]];
        uint64_t buffer_ns=0,texture_ns=0,texture_copies=0;
        for(size_t i=0;i<p->count;i++){
            NSDictionary *entry=capture_imports[i];size_t resource=[entry[@"resource"] unsignedLongLongValue];uint64_t bytes=[entry[@"bytes"] unsignedLongLongValue];
            uint64_t started=payload_profile_now();
            if(entry[@"planes"]){
                id<MTLTexture> texture=(id<MTLTexture>)refs[resource].handle;
                for(NSDictionary *plane in entry[@"planes"]){NSUInteger mip=[plane[@"mip"] unsignedIntegerValue];
                    [blit copyFromTexture:texture sourceSlice:[plane[@"slice"]unsignedIntegerValue] sourceLevel:mip sourceOrigin:MTLOriginMake(0,0,0)
                        sourceSize:MTLSizeMake(MAX((NSUInteger)1,texture.width>>mip),MAX((NSUInteger)1,texture.height>>mip),1)
                        toBuffer:p->snapshots[i] destinationOffset:[plane[@"offset"] unsignedIntegerValue]
                        destinationBytesPerRow:[plane[@"row_bytes"] unsignedIntegerValue] destinationBytesPerImage:[plane[@"length"] unsignedIntegerValue]];
                    texture_copies++;
                }
                texture_ns+=payload_profile_elapsed(started);
            }else{
                [blit copyFromBuffer:(id<MTLBuffer>)refs[resource].handle sourceOffset:refs[resource].offset toBuffer:p->snapshots[i]
                    destinationOffset:0 size:(NSUInteger)bytes];
                buffer_ns+=payload_profile_elapsed(started);
            }
        }
        [blit updateFence:p->ready];[blit endEncoding];info->bedrock_cut_ready_fence=(obj_handle_t)p->ready;
        payload_profile_token(directory,FFSC_PROFILE_SNAPSHOT_BUFFER,buffer_ns,snapshot_bytes,imports.count);
        payload_profile_token(directory,FFSC_PROFILE_SNAPSHOT_TEXTURE,texture_ns,texture_bytes,texture_copies);
    }
    p->gpu_callback=1;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){operation_complete(p,completed.status==MTLCommandBufferStatusCompleted);}];
    if(log_payload_success(directory))fprintf(stderr,"[full-frame-operation] scheduled payload=%llu category=%u commands=%llu imports=%zu bytes=%llu initial_textures_overwritten=%lu native_buffers_reused=%llu native_buffer_bytes_reused=%llu\n",(unsigned long long)payload,c->category,
        (unsigned long long)c->command_count,p->count,(unsigned long long)(snapshot_bytes+texture_bytes),(unsigned long)overwritten.count,(unsigned long long)native_buffer_reuse,(unsigned long long)native_buffer_bytes);return payload;
}

static void render_reject(const ffs_producer_context *c,uint64_t payload,const char *reason,const struct payload_context *p){
    uint64_t thread_id=0;(void)pthread_threadid_np(NULL,&thread_id);
    fprintf(stderr,"[full-frame-render-reject] reason=%s thread_id=%llu stream=%llu frame=%llu chunk=%llu encoder=%u payload=%llu commands=%llu resources=%llu dependencies=%llu filter_called=%d filter_accepted=%d index=%llu cut_id=%llu draws=%llu buffers=%llu textures=%llu snapshot_bytes=%llu stop=%u stop_command=%u detail=%u budget_requested=%llu budget_reserved=%llu budget_shared=%llu budget_memo=%llu budget_arena=%llu\n",
        reason,(unsigned long long)thread_id,(unsigned long long)c->stream,(unsigned long long)c->frame,(unsigned long long)c->chunk,c->encoder,
        (unsigned long long)payload,(unsigned long long)c->command_count,(unsigned long long)c->resource_count,(unsigned long long)c->dependency_count,
        p?p->filter_called:0,p?p->filter_accepted:0,(unsigned long long)(p?p->reject_index:0),(unsigned long long)(p?p->cut_id:0),
        (unsigned long long)(p?p->cut_draws:0),(unsigned long long)(p?p->cut_buffers:0),(unsigned long long)(p?p->cut_textures:0),
        (unsigned long long)(p?p->cut_snapshot_bytes:0),p?p->cut_stop:0,p?p->cut_command:0,p?p->cut_detail:0,
        (unsigned long long)(p?p->budget_requested:0),(unsigned long long)(p?p->budget_reserved:0),
        (unsigned long long)(p?p->budget_shared:0),(unsigned long long)(p?p->budget_memo:0),(unsigned long long)(p?p->budget_arena:0));
}
#include "direct_pass_journal.h"
#include "library_hash_name.h"
#include "live_command_source.inc"
static uint64_t frame_stream_prepare_impl(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info,const ffs_producer_context *c){@autoreleasepool{
    if(!command||!c||c->magic!=FFS_PREPARE_MAGIC||c->version!=FFS_PREPARE_VERSION||c->bytes!=sizeof(*c)||
       c->resource_count>FFS_MAX_RESOURCES||(c->resource_count&&!c->resources.ptr)||c->command_count>FFS_MAX_COMMANDS||
       c->dependency_count>FFS_MAX_DEPENDENCIES||(c->dependency_count&&!c->dependencies.ptr)){
        if(c&&c->magic==FFS_PREPARE_MAGIC&&c->version==FFS_PREPARE_VERSION&&c->bytes==sizeof(*c)&&c->category==FFS_RENDER)
            render_reject(c,0,"invalid-prepare-input",NULL);
        return 0;
    }
    if(live_enabled()&&!c->stream)return live_warm_prepare(info,c);
    int continuous=chunk_mode();
    pthread_mutex_lock(&guard);
    if(continuous&&!io){io=dispatch_queue_create("bedrock.native-chunk.payloads.0",DISPATCH_QUEUE_SERIAL);
        io_second=dispatch_queue_create("bedrock.native-chunk.payloads.1",DISPATCH_QUEUE_SERIAL);
        unsigned mode=private_io_mode();
        if(mode>=3)io_third=dispatch_queue_create("bedrock.native-chunk.payloads.2",DISPATCH_QUEUE_SERIAL);
        if(mode==4)io_fourth=dispatch_queue_create("bedrock.native-chunk.payloads.3",DISPATCH_QUEUE_SERIAL);
        if(!io||!io_second||(mode>=3&&!io_third)||(mode==4&&!io_fourth))failed=1;}
    int active=continuous?!failed:root_directory>=0&&!ended&&!failed&&c->stream==stream_id&&c->frame==frame_id;
    pthread_mutex_unlock(&guard);if(!active){
        if(c->category==FFS_BLIT||c->category==FFS_TIMESTAMP||c->category==FFS_SIGNAL_EVENT)return operation_reject(c,0,-1,"inactive",UINT64_MAX,UINT32_MAX,UINT64_MAX);
        if(c->category==FFS_RENDER)render_reject(c,0,"inactive",NULL);return 0;
    }
    if(c->category==FFS_PREPARE_CHUNK){
        if(continuous)return fullframe_chunk_source_completion(command,c);
        pthread_mutex_lock(&guard);NSNumber *key=@(c->chunk);int duplicate=[registered_chunks containsObject:key];
        if(!duplicate)[registered_chunks addObject:key];pthread_mutex_unlock(&guard);if(duplicate)return 0;
        [command addCompletedHandler:^(id<MTLCommandBuffer> completed){
            dispatch_async(io,^{@autoreleasepool{pthread_mutex_lock(&guard);completed_chunks++;if(completed.status!=MTLCommandBufferStatusCompleted)failed=1;
                pthread_mutex_unlock(&guard);finish_if_ready();}});
        }];return 1;
    }
    if(c->category!=FFS_RENDER&&c->category!=FFS_PRESENT_ENCODER&&c->category!=FFS_CLEAR&&c->category!=FFS_RESOLVE&&
       c->category!=FFS_BLIT&&c->category!=FFS_TIMESTAMP&&c->category!=FFS_SIGNAL_EVENT)return 0;
    pthread_mutex_lock(&guard);uint64_t payload=(continuous?next_payload<UINT64_MAX:next_payload<FRAME_PAYLOADS+2)?next_payload++:0;pthread_mutex_unlock(&guard);if(!payload){if(c->category==FFS_RENDER)render_reject(c,0,"payload-id-exhausted",NULL);return 0;}
    char name[64];snprintf(name,sizeof(name),"payload-%llu",(unsigned long long)payload);
    int directory;
    if(continuous){directory=fullframe_chunk_payload_open(c,payload);if(directory>=-1){
        if(c->category==FFS_BLIT||c->category==FFS_TIMESTAMP||c->category==FFS_SIGNAL_EVENT)return operation_reject(c,payload,-1,"payload-open",UINT64_MAX,UINT32_MAX,UINT64_MAX);
        if(c->category==FFS_RENDER)render_reject(c,payload,"payload-open",NULL);return 0;
    }}
    else{if(mkdirat(root_directory,name,0700)){if(c->category==FFS_RENDER)render_reject(c,payload,"directory-create",NULL);return 0;}
        directory=openat(root_directory,name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(directory<0){if(c->category==FFS_RENDER)render_reject(c,payload,"directory-open",NULL);return 0;}}
    if(live_enabled()&&c->category!=FFS_PRESENT_ENCODER)return live_prepare(command,info,c,payload,directory);
    if(c->category==FFS_BLIT||c->category==FFS_TIMESTAMP||c->category==FFS_SIGNAL_EVENT)return operation_payload(command,info,c,payload,directory);
    if(c->category==FFS_CLEAR||c->category==FFS_RESOLVE)return utility_payload(command,info,c,payload,directory);
    if(c->category==FFS_PRESENT_ENCODER){
        const ffs_producer_resource *r=c->resources.ptr;
        NSDictionary *ref=c->resource_count==1&&r->role==FFS_ROLE_PRESENT&&r->input_content_version>1?reference(r,payload):nil;
        const ffs_present_info *state=c->present.ptr;
        id<MTLTexture> texture=ref?(id<MTLTexture>)r->handle:nil;
        /* Presenter samples logical channels before writing the drawable. Its
         * declared format can be BGRA while DXMT's actual backbuffer is RGBA;
         * both non-sRGB unorm8 formats preserve those sampled color values. */
        if(!state||!texture||(state->source_format!=WMTPixelFormatRGBA8Unorm&&state->source_format!=WMTPixelFormatBGRA8Unorm)||
           (texture.pixelFormat!=MTLPixelFormatRGBA8Unorm&&texture.pixelFormat!=MTLPixelFormatBGRA8Unorm)||
           state->effective_colorspace!=WMTColorSpaceSRGB||state->gamma_version||state->sample_count!=1||
           texture.sampleCount!=1||state->hdr_metadata_enabled||state->edr_scale!=1||state->drawable_width!=texture.width||
           state->drawable_height!=texture.height||!isfinite(state->max_content_luminance)||!isfinite(state->max_display_luminance)){
            fprintf(stderr,"[full-frame-present] unsupported presenter_format=%llu source_format=%lu space=%llu gamma=%llu samples=%llu edr=%g drawable=%gx%g source=%lux%lu\n",
                (unsigned long long)(state?state->source_format:0),(unsigned long)texture.pixelFormat,(unsigned long long)(state?state->effective_colorspace:0),
                (unsigned long long)(state?state->gamma_version:0),(unsigned long long)(state?state->sample_count:0),
                state?state->edr_scale:0,state?state->drawable_width:0,state?state->drawable_height:0,(unsigned long)texture.width,(unsigned long)texture.height);
            payload_close(directory);return 0;
        }
        if(!boundary_reference(command,texture,c)){payload_close(directory);return 0;}
        NSMutableDictionary *record=header(c,payload,@"bedrock-native-frame-present");
        if(ref)[record addEntriesFromDictionary:@{@"reference":ref,@"resources":@[ref],@"command_types":@[],
            @"presentation":@{@"mode":@"identity-sdr",@"source_format":@(texture.pixelFormat),@"presenter_format":@(state->source_format),@"effective_colorspace":@(state->effective_colorspace),
                @"gamma_version":@(state->gamma_version),@"sample_count":@(state->sample_count),@"drawable_width":@(state->drawable_width),
                @"drawable_height":@(state->drawable_height),@"edr_scale":@(state->edr_scale),@"max_content_luminance":@(state->max_content_luminance),
                @"max_display_luminance":@(state->max_display_luminance),@"hdr_metadata_enabled":@(state->hdr_metadata_enabled)}}];
        uint64_t started=payload_profile_now();
        int ok=ref&&write_json(directory,"bindings.json",record);uint64_t bytes=ok?directory_bytes(directory):UINT64_MAX;
        payload_profile_token(directory,FFSC_PROFILE_SERIALIZE,payload_profile_elapsed(started),bytes==UINT64_MAX?0:bytes,1);payload_close(directory);
        pthread_mutex_lock(&guard);refresh_shared_bytes_locked();if(ok&&!failed&&budget_allows_locked(bytes)){stored_bytes+=bytes;reserved_bytes+=bytes;
            register_payload(directory,payload,"present");}else{failed=1;ok=0;}
        pthread_mutex_unlock(&guard);return ok?payload:0;
    }
    if(!info||info->bedrock_cut_magic!=UINT64_C(0x4244464355543033)||!info->bedrock_cut_ordinary||
       info->bedrock_cut_fence_count>FF_DRAW_FENCE_LIMIT||!info->bedrock_cut_commands.ptr||!info->bedrock_cut_argbuffer){
        const char *reason=!info?"cut-info-missing":info->bedrock_cut_magic!=UINT64_C(0x4244464355543033)?"cut-magic":
            !info->bedrock_cut_ordinary?"cut-nonordinary":info->bedrock_cut_fence_count>FF_DRAW_FENCE_LIMIT?"cut-fence-count":
            !info->bedrock_cut_commands.ptr?"cut-command-list":"cut-argument-buffer";
        render_reject(c,payload,reason,NULL);payload_close(directory);return 0;}
    struct payload_context *p=calloc(1,sizeof(*p));if(!p){render_reject(c,payload,"context-allocation",NULL);payload_close(directory);return 0;}
    *p=(struct payload_context){.command=command,.info=info,.producer=c,.payload=payload,.directory=directory};
    id<MTLFence> fences[FF_DRAW_FENCE_LIMIT];for(size_t i=0;i<info->bedrock_cut_fence_count;i++)fences[i]=(id<MTLFence>)info->bedrock_cut_fences[i];
    struct ff_draw_cut *cut=NULL;
    int scheduled=(directory < -1 ? ff_draw_pass_cut_schedule_bounded_staging_witness :
        ff_draw_pass_cut_schedule_checked_with_allocator_witness)(command,info->bedrock_cut_commands.ptr,
        (id<MTLBuffer>)info->bedrock_cut_argbuffer,layout,NULL,fences,info->bedrock_cut_fence_count,
        FF_DRAW_PASS_LIMIT,payload_filter,p,chunk_snapshot_allocator,p,payload_union_witness,p,payload_complete,p,&cut);
    free(p->range_index);p->range_index=NULL;
    if(!scheduled){
        render_reject(c,payload,p->reject_reason?p->reject_reason:(p->filter_accepted?"post-filter-scheduling":"cut-scheduling"),p);
        callback_drop_lease(p);
        pthread_mutex_lock(&guard);if(p->reserved){reserved_bytes-=p->reservation;if(pending)pending--;failed=1;}else coverage_failed=1;pthread_mutex_unlock(&guard);
        if(fullframe_chunk_release_texture_budget)fullframe_chunk_release_texture_budget(directory);
        [p->record release];[p->bindings release];payload_close(directory);free(p);return 0;
    }
    /* Shared extents remain covered by the permanent arena reservation, and
     * owned transport exports them without an additional snapshot allocation. */
    if(p->reserved&&!p->extended&&p->directory < -1&&fullframe_write_resource_cut_to_owned_sink&&
       fullframe_chunk_blob_write_completed_snapshot&&fullframe_chunk_payload_retained_limit&&
       fullframe_chunk_blob_write_shared_snapshot)
        (void)credit_shared_extents(&p->reservation,cut->shared_snapshot_extents,cut->snapshot_count);
    uint64_t texture_bytes=0,texture_copies=0;
    for(size_t i=0;i<cut->texture_count;i++)if(cut->texture_buffers[i]){texture_bytes+=cut->textures[i].length;texture_copies+=cut->textures[i].plane_count;}
    /* Mixed cut scheduling remains part of PREPARE. Only accepted fresh copy
     * counts/bytes are attributed here; neither counter is a GPU duration. */
    uint64_t copiedBufferBytes=0,copiedBuffers=0,referenceBytes=0,referenceBuffers=0;
    for(size_t i=0;i<cut->snapshot_count;i++)if(cut->reference_input_version[i]){
        referenceBytes+=cut->source_length[i];referenceBuffers++;
    }else{copiedBufferBytes+=cut->source_length[i];copiedBuffers++;}
    payload_profile_token(p->directory,FFSC_PROFILE_SNAPSHOT_BUFFER,0,copiedBufferBytes,copiedBuffers);
    if(referenceBuffers&&retained_observer_diagnostics())fprintf(stderr,"[native-buffer-ref] stream=%llu frame=%llu chunk=%llu payload=%llu references=%llu logical_bytes=%llu\n",
        (unsigned long long)c->stream,(unsigned long long)c->frame,(unsigned long long)c->chunk,
        (unsigned long long)payload,(unsigned long long)referenceBuffers,(unsigned long long)referenceBytes);
    payload_profile_token(p->directory,FFSC_PROFILE_SNAPSHOT_TEXTURE,0,texture_bytes,texture_copies);
    boundary_pass_cut=cut;
    info->bedrock_cut_ready_fence=(obj_handle_t)cut->ready_fence;
    if(p->load_count){
        FFSTAttachmentCapture capture=attachment_state(command.device);id<MTLFence> ready=nil;
        if(!capture||!ffst_attachment_capture_schedule(capture,command,p->payload,p->loads,p->load_count,fences,info->bedrock_cut_fence_count,&ready,
            ^(uint64_t cut_id,FFSTResult result){if(result!=FFST_OK)fprintf(stderr,"[full-frame-initial-load] cut=%llu result=%u\n",(unsigned long long)cut_id,(unsigned)result);})){render_reject(c,payload,"initial-load-scheduling",p);pthread_mutex_lock(&guard);failed=1;pthread_mutex_unlock(&guard);return 0;}
        fullframe_draw_cut_add_load_fence(cut->ready_fence,ready);
        pthread_mutex_lock(&guard);refresh_shared_bytes_locked();pthread_mutex_unlock(&guard);
    }
    if(log_payload_success(directory))fprintf(stderr,"[full-frame-payload] scheduled payload=%llu draws=%zu buffers=%zu textures=%zu loads=%zu\n",(unsigned long long)payload,cut->draw_count,cut->snapshot_count,cut->texture_count,p->load_count);
    if(cut->direct_cpu_ready){
        /* Nothing in this cut reads source GPU output. Keep the borrowed
         * fence alive until its source command completes, but serialize owned
         * CPU bytes now. Source completion/query publication stays independent. */
        id<MTLFence> held=[cut->ready_fence retain];
        [command addCompletedHandler:^(id<MTLCommandBuffer> finished){(void)finished;[held release];}];
        boundary_pass_cut=NULL;payload_complete(cut,1,p);
    }
    return payload;
}}
uint64_t fullframe_frame_stream_prepare(id<MTLCommandBuffer> command,struct WMTRenderPassInfo *info,const ffs_producer_context *c){
    [boundary_pass_buffers release];boundary_pass_buffers=nil;boundary_pass_cut=NULL;[boundary_pass_state release];boundary_pass_state=nil;
    uint64_t started=payload_profile_now();uint64_t result=frame_stream_prepare_impl(command,info,c);
    if(c&&c->magic==FFS_PREPARE_MAGIC&&c->version==FFS_PREPARE_VERSION&&c->bytes==sizeof(*c)&&fullframe_chunk_profile_context)
        fullframe_chunk_profile_context(c,FFSC_PROFILE_PREPARE,payload_profile_elapsed(started),0,1);
    const char *reference=getenv("BEDROCK_BOUNDARY_REFERENCE");
    if(result&&info&&reference&&!strcmp(reference,"1")&&!chunk_mode()&&
       (c->category==FFS_RENDER||c->category==FFS_CLEAR||c->category==FFS_RESOLVE)){
        boundary_pass_payload=result;boundary_pass_stream=c->stream;boundary_pass_frame=c->frame;boundary_pass_command=command;
        boundary_pass_commands=c->category==FFS_RENDER?info->bedrock_cut_commands.ptr:NULL;
        boundary_pass_arguments=c->category==FFS_RENDER?(id<MTLBuffer>)info->bedrock_cut_argbuffer:nil;
        [boundary_pass_textures release];boundary_pass_textures=[[NSMutableArray alloc]init];
        const ffs_producer_resource *r=c->resources.ptr;
        for(uint64_t i=0;i<c->resource_count;i++)if(r[i].kind==FFS_TEXTURE&&r[i].role==FFS_ROLE_SHADER&&r[i].handle)[boundary_pass_textures addObject:(id)r[i].handle];
    }
    return result;
}
