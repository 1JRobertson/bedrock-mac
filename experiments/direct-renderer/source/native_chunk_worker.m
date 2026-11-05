#import "native_chunk_worker.h"
#import <AppKit/AppKit.h>
#import "native_chunk_payloads.h"
#import "native_presenter.h"
#import "native_receipt_mailbox.h"
#include "chunk_stream.h"
#include "readback_stream.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error native_chunk_worker.m requires ARC
#endif

static double chunk_now(void) {struct timespec t;clock_gettime(CLOCK_MONOTONIC,&t);return t.tv_sec+t.tv_nsec/1e9;}
/* AppKit permits posting from a worker thread. This private application event
 * wakes the main event pump when a newly completed frame becomes available;
 * it carries no keyboard, mouse or window input. */
static void chunk_wake_presenter(NSApplication *application) {
    if(!application)return;
    NSEvent *event=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint
        modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:0x4646 data1:0 data2:0];
    if(event)[application postEvent:event atStart:NO];
}
/* Opt-in events use the same monotonic clock and identity as the producer. */
static void chunk_timeline(const char *event,ffsc_packet_header h) {
    const char *enabled=getenv("BEDROCK_NATIVE_SOURCE_TIMELINE");
    if(!enabled||strcmp(enabled,"1"))return;
    struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return;
    uint64_t ns=(uint64_t)t.tv_sec*1000000000u+(uint64_t)t.tv_nsec;
    char line[384];int n=snprintf(line,sizeof(line),
        "[native-worker-timeline] clock=CLOCK_MONOTONIC event=%s at_ns=%llu stream=%llu frame=%llu chunk=%llu serial=%llu queue_completion=%llu\n",
        event,(unsigned long long)ns,(unsigned long long)h.stream,(unsigned long long)h.frame,
        (unsigned long long)h.chunk,(unsigned long long)h.serial,(unsigned long long)h.queue_completion);
    if(n>0&&(size_t)n<sizeof(line))(void)write(STDERR_FILENO,line,(size_t)n);
}
static BOOL chunk_write(int directory,const char *name,NSData *data) {
    if(!data)return NO;
    int fd=openat(directory,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;
    const uint8_t *p=data.bytes;size_t left=data.length;
    while(left){ssize_t n=write(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=n;}
    BOOL ok=!left&&!fsync(fd);if(close(fd))ok=NO;if(!ok)unlinkat(directory,name,0);return ok;
}
static BOOL chunk_json(int directory,const char *name,NSDictionary *value) {
    return chunk_write(directory,name,[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]);
}
/* This is an experiment identity, not the overlay authentication secret. */
static NSString *chunk_frame_age_run_id(void) {
    const char *value=getenv("BEDROCK_NATIVE_FRAME_AGE_RUN_ID");
    if(!value||strnlen(value,33)!=32)return nil;
    for(size_t i=0;i<32;i++)if(!((value[i]>='0'&&value[i]<='9')||(value[i]>='a'&&value[i]<='f')))return nil;
    return [NSString stringWithUTF8String:value];
}
static BOOL chunk_write_present_samples(int directory,ff_native_presenter *presenter,ff_present_stats *stats,NSString *runID) {
    const char *enabled=getenv("BEDROCK_NATIVE_PRESENT_SAMPLES");
    BOOL ageEnabled=runID!=nil;
    if(!ageEnabled&&(!enabled||strcmp(enabled,"1")))return YES;
    const size_t capacity=16384;
    ff_present_sample *samples=calloc(capacity,sizeof(*samples));if(!samples)return NO;
    uint64_t overflow=0;size_t count=ff_presenter_copy_samples(presenter,samples,capacity,&overflow,stats);
    NSMutableArray *records=[NSMutableArray arrayWithCapacity:count];
    uint64_t identityPresent=0,identityMissing=0;
    for(size_t i=0;i<count&&i<capacity;++i){double value=samples[i].presented_time;
        id timestamp=isfinite(value)?(id)@(value):(id)[NSNull null];
        NSString *special=isnan(value)?@"nan":isinf(value)?(value<0?@"-inf":@"+inf"):@"";
        NSMutableDictionary *record=[@{@"presented_time":timestamp,@"nonfinite":special,
            @"callback_monotonic_ns":@(samples[i].callback_monotonic_ns)} mutableCopy];
        if(ageEnabled){
            BOOL hasIdentity=samples[i].identity_present!=0;
            ff_present_identity identity=hasIdentity?samples[i].identity:(ff_present_identity){0};
            if(hasIdentity)++identityPresent;else ++identityMissing;
            [record addEntriesFromDictionary:@{@"identity_present":@(hasIdentity),@"stream":@(identity.stream),
                @"frame":@(identity.frame),@"chunk":@(identity.chunk),@"serial":@(identity.serial),
                @"queue_completion":@(identity.queue_completion)}];
        }
        [records addObject:record];}
    free(samples);
    uint64_t outstanding=stats->display_scheduled>=stats->display_callbacks?stats->display_scheduled-stats->display_callbacks:0;
    NSMutableDictionary *output=[@{@"format":@"bedrock-present-samples",@"version":@1,
        @"presented_time_clock":@"Metal presentedTime seconds",@"callback_clock":@"CLOCK_MONOTONIC nanoseconds",
        @"capacity":@(capacity),@"retained":@(count),@"overflow":@(overflow),@"sample_window":@"tail",@"scheduled":@(stats->display_scheduled),
        @"callbacks":@(stats->display_callbacks),@"unsupported":@(stats->display_unsupported),@"outstanding_at_snapshot":@(outstanding),
        @"positive":@(stats->display_positive),@"zero":@(stats->display_zero),@"invalid":@(stats->display_invalid),
        @"out_of_order":@(stats->display_out_of_order),@"counter_overflow":@(stats->display_counter_overflow),@"samples":records} mutableCopy];
    if(ageEnabled)[output addEntriesFromDictionary:@{@"run_id":runID,@"identity_present_retained":@(identityPresent),
        @"identity_missing_retained":@(identityMissing)}];
    return chunk_json(directory,"presentation-samples.json",output);
}
static NSData *chunk_snapshot_png(const void *bytes,uint32_t width,uint32_t height,uint32_t rowBytes) {
    if(!bytes||!width||!height||rowBytes<(uint64_t)width*4||height>SIZE_MAX/rowBytes)return nil;
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    CGDataProviderRef provider=CGDataProviderCreateWithData(NULL,bytes,(size_t)rowBytes*height,NULL);
    CGImageRef image=space&&provider?CGImageCreate(width,height,8,32,rowBytes,space,
        kCGBitmapByteOrder32Little|kCGImageAlphaPremultipliedFirst,provider,NULL,false,kCGRenderingIntentDefault):NULL;
    NSData *png=nil;
    if(image){NSBitmapImageRep *rep=[[NSBitmapImageRep alloc] initWithCGImage:image];
        png=[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}];}
    if(image)CGImageRelease(image);if(provider)CGDataProviderRelease(provider);if(space)CGColorSpaceRelease(space);
    return png;
}
static BOOL chunk_stop_file(int directory) {
    int fd=openat(directory,"presentation.stop",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return NO;struct stat s;char bytes[6]={0};
    BOOL stop=!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==getuid()&&!(s.st_mode&077)&&
        s.st_size==5&&read(fd,bytes,sizeof(bytes))==5&&!memcmp(bytes,"stop\n",5);close(fd);return stop;
}
static BOOL chunk_arm_token(int directory,const char *name) {
    int fd=openat(directory,name,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);
    if(fd<0)return NO;struct stat s;char bytes[5]={0};
    BOOL armed=!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==getuid()&&!(s.st_mode&077)&&
        s.st_size==4&&read(fd,bytes,sizeof(bytes))==4&&!memcmp(bytes,"arm\n",4);close(fd);return armed;
}
static BOOL chunk_arm_file(int directory) {return chunk_arm_token(directory,"frame.arm");}
static BOOL chunk_u64(id object,uint64_t *value) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType],*s=[[object stringValue] UTF8String];
    if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0])||!s||!*s)return NO;
    uint64_t result=0;for(;*s;s++){if(*s<'0'||*s>'9'||result>(UINT64_MAX-(unsigned)(*s-'0'))/10)return NO;result=result*10+(unsigned)(*s-'0');}
    *value=result;return YES;
}
static BOOL chunk_true(id object) {return object&&CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID()&&[object boolValue];}
static ffsc_receipt chunk_receipt(ffsc_packet_header h,uint32_t kind,uint32_t status) {
    return (ffsc_receipt){.version=FFSC_VERSION,.kind=kind,.status=status,.serial=h.serial,
        .stream=h.stream,.frame=h.frame,.chunk=h.chunk,.record_digest=h.record_digest,.queue_completion=h.queue_completion};
}

@interface FFSTChunkWorkerState : NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *outputs;
@property(nonatomic,strong) FFSTNativeReceiptMailbox *mailbox;
@property(nonatomic,readonly) NSArray<NSData *> *receipts;
@property(nonatomic,copy) NSString *failure;
@property(nonatomic,strong) NSDictionary *cacheStats,*sessionStats,*lastFrame;
@property(nonatomic,strong) NSDictionary *snapshot;
@property(nonatomic,copy) NSString *frameAgeRunID;
@property(nonatomic,strong) NSApplication *wakeApplication;
@property(nonatomic,strong) NSMutableDictionary<NSString *,NSNumber *> *renderProfile;
@property(nonatomic) BOOL stopping,finished,presentationClosed,orderlySourceClosed;
@property(nonatomic) BOOL offscreen,frameAgeEnabled;
@property(nonatomic) uint64_t chunks,frames,submitted,pending,mainOwned,presented,superseded,cancelled,presentationErrors;
@property(nonatomic) uint64_t offscreenGPUCompleted;
@property(nonatomic) uint32_t offscreenSnapshotsCompleted;
@property(nonatomic) uint64_t textureUploadBytes;
@property(nonatomic) uint64_t textureReadbackBytes,readbackRanges;
@property(nonatomic) uint64_t packetBytes;
@property(nonatomic) uint32_t preparedCount,maxPreparedCount;
@property(nonatomic) uint32_t preparedLimit;
@property(nonatomic) uint64_t preparedBytes,maxPreparedBytes;
@property(nonatomic) double decodeSeconds,executeSeconds,completionSeconds;
@property(nonatomic) double nextSessionStatsAt;
@property(nonatomic) ff_present_stats displayStats;
- (void)fail:(NSString *)reason;
- (BOOL)enqueue:(ffsc_receipt)receipt;
- (BOOL)enqueueBatch:(NSArray<NSData *> *)receipts;
- (BOOL)isStopping;
- (void)markOrderlySourceClosed;
- (BOOL)isOrderlySourceClosed;
@end
@implementation FFSTChunkWorkerState
- (instancetype)init {self=[super init];if(self){_lock=[NSLock new];_outputs=[NSMutableArray new];_mailbox=[FFSTNativeReceiptMailbox new];_renderProfile=[NSMutableDictionary new];
    const char *depth=getenv("BEDROCK_NATIVE_PIPELINE_DEPTH");_preparedLimit=depth&&!strcmp(depth,"8")?8u:4u;}return self;}
- (void)setStopping:(BOOL)value {_stopping=value;if(value)[_mailbox stop];}
- (NSArray<NSData *> *)receipts {return [_mailbox snapshot];}
- (void)fail:(NSString *)reason {[_lock lock];if(!_failure)_failure=[reason copy];_stopping=YES;[_lock unlock];[_mailbox stop];}
- (void)markOrderlySourceClosed {[_lock lock];_orderlySourceClosed=YES;_stopping=YES;[_lock unlock];
    [_mailbox stop];[_mailbox discardAll];}
- (BOOL)isOrderlySourceClosed {[_lock lock];BOOL result=_orderlySourceClosed;[_lock unlock];return result;}
- (BOOL)enqueue:(ffsc_receipt)receipt {
    if([self isOrderlySourceClosed])return YES;
    BOOL ok=[_mailbox enqueuePriority:[NSData dataWithBytes:&receipt length:sizeof(receipt)]];
    if(!ok)[self fail:@"Native priority completion mailbox exceeded its bound"];
    return ok;
}
- (BOOL)enqueueBatch:(NSArray<NSData *> *)receipts {
    if([self isOrderlySourceClosed])return NO;
    BOOL ok=[_mailbox enqueueBatch:receipts timeoutSeconds:30];
    if(!ok&&![self isOrderlySourceClosed])[self fail:@"Native completion mailbox admission stopped or timed out"];
    return ok;
}
- (BOOL)isStopping {[_lock lock];BOOL value=_stopping;[_lock unlock];return value;}
@end

static NSDictionary *chunk_display_stats(ff_present_stats value) {
    return @{@"enabled":@(value.display_trace_enabled != 0),
        @"scheduled":@(value.display_scheduled),@"callbacks":@(value.display_callbacks),
        @"positive":@(value.display_positive),@"zero":@(value.display_zero),
        @"invalid":@(value.display_invalid),@"unsupported":@(value.display_unsupported),
        @"out_of_order":@(value.display_out_of_order),@"counter_overflow":@(value.display_counter_overflow),
        @"first_presented_time":@(value.first_presented_time),@"last_presented_time":@(value.last_presented_time),
        @"intervals":@(value.display_intervals),@"interval_sum_seconds":@(value.display_interval_sum),
        @"lifetime_interval_max_seconds":@(value.lifetime_interval_max),
        @"intervals_over_25ms":@(value.display_over_25ms),@"intervals_over_50ms":@(value.display_over_50ms)};
}

/* Opt-in QA observation: actual completion counters, never readiness evidence.
 * Replace one private file at most once a second, outside the state lock. */
static BOOL chunk_progress(int directory,FFSTChunkWorkerState *s) {
    [s.lock lock];
    NSDictionary *value=@{@"format":@"bedrock-native-chunk-progress",@"version":@1,
        @"worker_pid":@(getpid()),@"monotonic_seconds":@(chunk_now()),
        @"chunks":@(s.chunks),@"frames":@(s.frames),@"presentation_completed":@(s.presented),
        @"render_mode":s.offscreen?@"offscreen_gpu":@"drawable",@"offscreen_gpu_completed":@(s.offscreenGPUCompleted),
        @"offscreen_snapshot":s.snapshot?:@{ @"status":@"not_requested" },
        @"offscreen_snapshots_completed":@(s.offscreenSnapshotsCompleted),
        @"presentation_submitted":@(s.submitted),@"presentation_pending":@(s.pending),
        @"presentation_errors":@(s.presentationErrors),@"presentation_cancelled":@(s.cancelled),
        @"presentation_superseded":@(s.superseded),@"decode_seconds":@(s.decodeSeconds),
        @"execute_seconds":@(s.executeSeconds),@"completion_publish_seconds":@(s.completionSeconds),
        @"packet_bytes":@(s.packetBytes),@"error":s.failure?:@"",@"last_frame":s.lastFrame?:@{},
        @"orderly_source_closed":@(s.orderlySourceClosed),
        @"prepared_limit":@(s.preparedLimit),@"prepared_chunks":@(s.preparedCount),@"prepared_bytes":@(s.preparedBytes),
        @"max_prepared_chunks":@(s.maxPreparedCount),@"max_prepared_bytes":@(s.maxPreparedBytes),
        @"native_render_profile":[s.renderProfile copy],@"cache":s.cacheStats?:@{},
        @"native_prepare_seconds":s.sessionStats[@"native_prepare_seconds"]?:@0,
        @"native_encode_seconds":s.sessionStats[@"native_encode_seconds"]?:@0,
        @"native_gpu_retire_seconds":s.sessionStats[@"native_gpu_retire_seconds"]?:@0,
        @"shared_snapshot_buffers":s.sessionStats[@"shared_snapshot_buffers"]?:@0,
        @"shared_snapshot_buffer_bytes":s.sessionStats[@"shared_snapshot_buffer_bytes"]?:@0,
        @"asset_cache":s.sessionStats[@"asset_cache"]?:@{},
        @"receipt_mailbox_queued":@([s.mailbox count]),@"receipt_mailbox_max_queued":@([s.mailbox maximumCount]),
        @"actual_display":chunk_display_stats(s.displayStats)};
    [s.lock unlock];
    const char *temporary=".chunk-worker-progress.tmp";
    if(!chunk_json(directory,temporary,value))return NO;
    if(!renameat(directory,temporary,directory,"chunk-worker-progress.json"))return YES;
    unlinkat(directory,temporary,0);return NO;
}

@interface FFSTChunkPresentation : NSObject
@property(nonatomic,strong) FFSTChunkWorkerState *state;
@property(nonatomic) ffsc_packet_header header;
@property(nonatomic) uint64_t frameDigest;
@end
@implementation FFSTChunkPresentation
@end
@interface FFSTChunkSnapshot : NSObject
@property(nonatomic,strong) FFSTChunkWorkerState *state;
@property(nonatomic) ffsc_packet_header header;
@property(nonatomic) uint64_t frameDigest;
@property(nonatomic) int directory;
@end
@implementation FFSTChunkSnapshot
@end
static void chunk_snapshot_completed(void *opaque,const void *bytes,uint32_t width,uint32_t height,
    uint32_t rowBytes,ff_present_result result) {
    FFSTChunkSnapshot *context=(__bridge_transfer FFSTChunkSnapshot *)opaque;
    FFSTChunkWorkerState *s=context.state;
    BOOL ok=context.directory>=0&&result==FF_PRESENT_COMPLETED&&bytes&&width&&height;
    NSData *png=ok?chunk_snapshot_png(bytes,width,height,rowBytes):nil;
    if(!png)ok=NO;
    NSDictionary *record=@{ @"format":@"bedrock-native-offscreen-snapshot",@"version":@1,
        @"status":ok?@"captured":@"failed",@"gpu_completed":@(result==FF_PRESENT_COMPLETED),
        @"serial":@(context.header.serial),@"stream":@(context.header.stream),
        @"frame":@(context.header.frame),@"chunk":@(context.header.chunk),
        @"record_digest":@(context.header.record_digest),@"queue_completion":@(context.header.queue_completion),
        @"ledger_digest":@(context.frameDigest),
        @"width":@(width),@"height":@(height),@"row_bytes":@(rowBytes),
        @"pixel_format":@"BGRA8Unorm",@"png":@"offscreen-snapshot.png" };
    if(ok){
        ok=chunk_write(context.directory,".offscreen-snapshot.png.tmp",png)&&
            !renameat(context.directory,".offscreen-snapshot.png.tmp",context.directory,"offscreen-snapshot.png");
        if(!ok)unlinkat(context.directory,".offscreen-snapshot.png.tmp",0);
    }
    if(ok){
        ok=chunk_json(context.directory,".offscreen-snapshot.json.tmp",record)&&
            !renameat(context.directory,".offscreen-snapshot.json.tmp",context.directory,"offscreen-snapshot.json");
        if(!ok)unlinkat(context.directory,".offscreen-snapshot.json.tmp",0);
    }
    if(!ok)record=@{ @"format":@"bedrock-native-offscreen-snapshot",@"version":@1,
        @"status":@"failed",@"serial":@(context.header.serial),@"frame":@(context.header.frame) };
    [s.lock lock];s.snapshot=record;if(ok)++s.offscreenSnapshotsCompleted;[s.lock unlock];
    if(!ok)[s fail:@"Offscreen snapshot GPU readback or PNG write failed"];
    if(context.directory>=0)close(context.directory);
}
static void chunk_presented(void *opaque,ff_present_result result) {
    /* Callback owns only its mailbox/context, never the mmap endpoint or FD.
     * Late callbacks after shutdown cannot access recycled transport storage. */
    FFSTChunkPresentation *context=(__bridge_transfer FFSTChunkPresentation *)opaque;
    FFSTChunkWorkerState *s=context.state;
    chunk_timeline(result==FF_PRESENT_COMPLETED?(s.offscreen?"offscreen_completed":"present_completed"):"present_failed",context.header);
    uint32_t status=result==FF_PRESENT_COMPLETED?FFSC_COMPLETED:
        result==FF_PRESENT_SUPERSEDED?FFSC_SUPERSEDED:result==FF_PRESENT_CLOSED?FFSC_CANCELLED:FFSC_FAILED;
    ffsc_receipt receipt=chunk_receipt(context.header,s.offscreen?FFSC_OFFSCREEN_COMPLETED:FFSC_PRESENTED,status);receipt.value=context.frameDigest;
    [s enqueue:receipt];
    [s.lock lock];if(s.pending)--s.pending;
    if(result==FF_PRESENT_COMPLETED){if(s.offscreen)++s.offscreenGPUCompleted;else ++s.presented;}
    else if(result==FF_PRESENT_SUPERSEDED){++s.superseded;if(!s.failure)s.failure=@"Continuous native frame was superseded";s.stopping=YES;}
    else if(result==FF_PRESENT_CLOSED)++s.cancelled;else {++s.presentationErrors;if(!s.failure)s.failure=@"Native presentation failed";s.stopping=YES;}
    [s.lock unlock];
}

static BOOL chunk_flush_receipts(ffsc_endpoint *endpoint,FFSTChunkWorkerState *s) {
    double blocked=0;
    for(;;){
        if([s isOrderlySourceClosed]){enum ffsc_result state=ffsc_wait(endpoint,0);
            if(state!=FFSC_SOURCE_CLOSED){[s fail:@"Orderly source close changed to transport failure"];return NO;}
            [s.mailbox discardAll];return YES;}
        NSData *data=[s.mailbox first];if(!data)return YES;
        enum ffsc_result code=ffsc_send_receipt(endpoint,data.bytes);
        if(code==FFSC_OK){if(![s.mailbox removeFirst:data]){[s fail:@"Native completion mailbox lost its head"];return NO;}blocked=0;continue;}
        if(code==FFSC_SOURCE_CLOSED){[s markOrderlySourceClosed];return YES;}
        if(code!=FFSC_BACKPRESSURE){[s fail:@"Native completion receiver closed or rejected a receipt"];return NO;}
        if(!blocked)blocked=chunk_now();
        if(chunk_now()-blocked>([s isStopping]?1.0:5.0)){[s fail:@"Native completion receiver stopped draining"];return NO;}
        (void)ffsc_wait(endpoint,10);usleep(1000);
    }
}
/* Match completed native event thresholds to the original SignalEvent encoders.
 * A higher observed watermark proves this threshold, not any other identity. */
static BOOL chunk_event_receipts(NSArray *signals,NSData *records,ffsc_packet_header h,NSMutableArray<NSData *> *receipts) {
    if(![signals isKindOfClass:[NSArray class]]||signals.count>=FFSC_RECEIPT_CAPACITY||
       !records.length||records.length%sizeof(ffs_record))return NO;
    NSUInteger next=0;BOOL signalEncoder=NO,matched=NO;
    const uint8_t *bytes=records.bytes;
    for(NSUInteger i=0;i<records.length/sizeof(ffs_record);i++){
        ffs_record r;memcpy(&r,bytes+i*sizeof(r),sizeof(r));
        if(r.kind==FFS_ENCODER_BEGIN){
            if(signalEncoder)return NO;
            signalEncoder=r.data[0]==FFS_SIGNAL_EVENT;matched=NO;
        }else if(r.kind==FFS_DEPENDENCY&&r.data[0]==FFS_EVENT&&r.data[4]==FFS_SIGNAL){
            if(!signalEncoder||matched||next>=signals.count||r.stream!=h.stream||r.frame!=h.frame||r.chunk!=h.chunk||
               !r.data[1]||!r.data[2])return NO;
            id signal=signals[next++];if(![signal isKindOfClass:[NSDictionary class]])return NO;
            uint64_t domain,identifier,threshold,observed;
            if(!chunk_u64(signal[@"domain"],&domain)||domain!=FFS_EVENT||
               !chunk_u64(signal[@"id"],&identifier)||identifier!=r.data[1]||
               !chunk_u64(signal[@"value"],&threshold)||threshold!=r.data[2]||
               !chunk_u64(signal[@"signaled_value"],&observed)||observed<threshold)return NO;
            ffsc_receipt receipt=chunk_receipt(h,FFSC_QUERY_READY,FFSC_COMPLETED);
            receipt.query_kind=FFSC_EVENT_QUERY;receipt.id=identifier;receipt.count=1;receipt.value=threshold;
            [receipts addObject:[NSData dataWithBytes:&receipt length:sizeof(receipt)]];matched=YES;
        }else if(r.kind==FFS_ENCODER_END){
            if(signalEncoder&&!matched)return NO;
            signalEncoder=NO;
        }
    }
    return !signalEncoder&&next==signals.count;
}
static NSArray<NSData *> *chunk_completion_batch(FFSTNativeChunkExecution *output,ffsc_packet_header h,NSData *records) {
    NSDictionary *m=output.metrics;
    const uint64_t values[]={h.serial,h.stream,h.frame,h.chunk,h.record_digest,h.queue_completion};
    NSArray *keys=@[@"serial",@"stream",@"frame",@"chunk",@"record_digest",@"queue_completion"];
    for(unsigned i=0;i<keys.count;i++){uint64_t value;if(!chunk_u64(m[keys[i]],&value)||value!=values[i])return nil;}
    if(!chunk_true(m[@"gpu_completed"])||!chunk_true(m[@"imports_retired"]))return nil;
    if(output.frameOutput){
        uint64_t stream,frame,digest;NSDictionary *f=output.frameOutput.metrics;ffs_record end;
        if(!(h.flags&FFSC_FRAME_END)||records.length<sizeof(end))return nil;
        memcpy(&end,(const uint8_t *)records.bytes+records.length-sizeof(end),sizeof(end));
        if(end.kind!=FFS_FRAME_END||!chunk_u64(f[@"stream"],&stream)||stream!=h.stream||
           !chunk_u64(f[@"frame"],&frame)||frame!=h.frame||!chunk_u64(f[@"ledger_digest"],&digest)||digest!=end.data[4])return nil;
    }
    NSArray *timestamps=m[@"timestamps"],*signals=m[@"signals"];
    if(![timestamps isKindOfClass:[NSArray class]]||! [signals isKindOfClass:[NSArray class]]||
       timestamps.count>=FFSC_RECEIPT_CAPACITY||signals.count>=FFSC_RECEIPT_CAPACITY-timestamps.count)return nil;
    /* Validate all query evidence before admitting any completion receipt. */
    ffsc_receipt gpu=chunk_receipt(h,FFSC_NATIVE_GPU_COMPLETED,FFSC_COMPLETED);
    NSMutableArray<NSData *> *queries=[NSMutableArray arrayWithObject:[NSData dataWithBytes:&gpu length:sizeof(gpu)]];
    for(NSDictionary *t in timestamps){
        if(![t isKindOfClass:[NSDictionary class]])return nil;
        uint64_t chunk,index,count,value;
        if(!chunk_u64(t[@"chunk"],&chunk)||chunk!=h.chunk||!chunk_u64(t[@"readback_index"],&index)||index>1048576||
           !chunk_u64(t[@"query_count"],&count)||!count||count>1048576||!chunk_u64(t[@"value_ns"],&value)||!value)return nil;
        ffsc_receipt r=chunk_receipt(h,FFSC_QUERY_READY,FFSC_COMPLETED);r.query_kind=FFSC_TIMESTAMP;
        r.id=chunk;r.index=index;r.count=count;r.value=value;
        [queries addObject:[NSData dataWithBytes:&r length:sizeof(r)]];
    }
    if(!chunk_event_receipts(signals,records,h,queries))return nil;
    return queries;
}
static BOOL chunk_completion(FFSTNativeChunkExecution *output,ffsc_packet_header h,NSData *records,FFSTChunkWorkerState *s) {
    NSArray *batch=chunk_completion_batch(output,h,records);
    return batch&&[s enqueueBatch:batch];
}

/* Publish owned native bytes before admitting the chunk's GPU/query receipts.
 * Source additionally matches its original target and scatters these rows. */
static BOOL chunk_publish_readbacks(FFSTNativeChunkExecution *output,ffsc_packet_header h,NSData *records,
    ffrb_endpoint *returns,FFSTChunkWorkerState *state) {
    NSArray *ranges=output.bufferReadbacks?:@[];
    if(![ranges isKindOfClass:[NSArray class]]||ranges.count>FFST_NATIVE_READBACK_MAX_RANGES||
        !records.length||records.length%sizeof(ffs_record))return NO;
    const ffs_record *wire=records.bytes;NSUInteger count=records.length/sizeof(*wire);BOOL blit=NO;
    NSMutableSet<NSString *> *expected=[NSMutableSet set];
    for(NSUInteger i=0;i<count;++i){ffs_record r=wire[i];
        if(r.kind==FFS_ENCODER_BEGIN)blit=r.data[0]==FFS_BLIT;
        else if(r.kind==FFS_ENCODER_END)blit=NO;
        else if(blit&&r.kind==FFS_COMMAND&&r.data[0]==3)
            [expected addObject:[NSString stringWithFormat:@"%u:%u",r.encoder,r.item]];
    }
    if(ranges.count!=expected.count||(!returns&&ranges.count))return NO;
    NSMutableArray<NSData *> *metadata=[NSMutableArray arrayWithCapacity:ranges.count];uint64_t bytes=0;
    for(FFSTNativeBufferReadback *range in ranges){
        if(![range isKindOfClass:[FFSTNativeBufferReadback class]]||range.chunk!=h.chunk||!range.root||!range.generation||
            !range.contentVersion||!range.rowLength||range.rowBytes<range.rowLength||!range.rowCount||range.rowCount>8192||
            ((range.rowBytes|range.rowLength)&3)||
            range.rowLength>FFRB_MAX_BYTES/range.rowCount)return NO;
        uint64_t length=range.rowLength*range.rowCount;
        if(![range.bytes isKindOfClass:[NSData class]]||range.bytes.length!=length||length>FFST_NATIVE_READBACK_MAX_BYTES-bytes||
            (range.rowCount>1&&range.rowBytes>(UINT64_MAX-range.rowLength)/(range.rowCount-1)))return NO;
        uint64_t footprint=(range.rowCount-1)*range.rowBytes+range.rowLength;
        if(range.offset>UINT64_MAX-footprint)return NO;
        NSString *key=[NSString stringWithFormat:@"%u:%u",range.encoder,range.command];
        if(![expected containsObject:key])return NO;[expected removeObject:key];
        BOOL target=NO;uint64_t version=0;
        for(NSUInteger i=0;i<count;++i){ffs_record r=wire[i];
            if(r.kind!=FFS_RESOURCE||r.data[0]!=FFS_BUFFER||r.data[1]!=range.root||r.data[3]!=range.generation)continue;
            if(r.flags&FFS_WRITE)version=r.data[8];
            if(r.encoder==range.encoder&&(r.flags&(FFS_READ|FFS_WRITE))==(FFS_READ|FFS_WRITE)&&range.offset>=r.data[5]&&
                range.offset-r.data[5]<=r.data[6]&&footprint<=r.data[6]-(range.offset-r.data[5]))target=YES;
        }
        if(!target||version!=range.contentVersion)return NO;
        ffrb_record r={.serial=h.serial,.stream=h.stream,.frame=h.frame,.chunk=h.chunk,.record_digest=h.record_digest,
            .queue_completion=h.queue_completion,.encoder=range.encoder,.command=range.command,.root=range.root,
            .generation=range.generation,.content_version=range.contentVersion,.offset=range.offset,
            .row_bytes=range.rowBytes,.row_length=range.rowLength,.row_count=range.rowCount};
        [metadata addObject:[NSData dataWithBytes:&r length:sizeof(r)]];bytes+=length;
    }
    if(expected.count)return NO;
    for(NSUInteger i=0;i<ranges.count;++i){ffrb_record record;memcpy(&record,[metadata[i] bytes],sizeof(record));
        FFSTNativeBufferReadback *range=ranges[i];double start=chunk_now();
        for(;;){if([state isStopping])return NO;
            enum ffrb_result code=ffrb_publish(returns,&record,range.bytes.bytes,range.bytes.length);
            if(code==FFRB_OK)break;
            if(code!=FFRB_BACKPRESSURE||chunk_now()-start>5.0)return NO;
            (void)ffrb_wait(returns,10);usleep(1000);
        }
    }
    return YES;
}

static uint64_t chunk_prepared_upper_bound(const void *bytes) {
    /* ffsc_peek has already validated this exact slot, including every table
     * extent. Reconstructed segmented originals cannot exceed their pages. */
    ffsc_packet_header h;memcpy(&h,bytes,sizeof(h));
    uint64_t total=(uint64_t)h.record_count*sizeof(ffs_record)+(uint64_t)h.retirement_count*sizeof(ffsc_retirement);
    if(total>FFST_NATIVE_FRAME_MAX_BYTES)return FFST_NATIVE_FRAME_MAX_BYTES+1;
    for(uint32_t i=0;i<h.blob_count;++i){ffsc_blob_entry blob;
        memcpy(&blob,(const uint8_t *)bytes+h.blobs_offset+(size_t)i*sizeof(blob),sizeof(blob));
        if(blob.length>(FFST_NATIVE_FRAME_MAX_BYTES-total)/2)return FFST_NATIVE_FRAME_MAX_BYTES+1;
        total+=2*blob.length;
    }
    return total;
}
static void chunk_execute_prepared(FFSTNativeSession *session,FFSTDecodedNativeChunk *decoded,
    ffsc_packet_header header,ffrb_endpoint *returns,FFSTChunkWorkerState *s) {
    @autoreleasepool {
        /* The serial Metal session has one executor; decoding may continue on
         * the transport owner while this thread encodes or waits for the GPU. */
        for(;;){[s.lock lock];BOOL stopping=s.stopping;
            BOOL full=s.pending+s.mainOwned+s.outputs.count>=2;[s.lock unlock];
            if(stopping||!full)break;usleep(1000);}
        NSString *failure=nil;FFSTNativeChunkExecution *output=nil;
        __block BOOL consumed=NO,releaseFailed=NO;BOOL completed=NO;
        double started=chunk_now(),executeSeconds=0,completionSeconds=0;
        chunk_timeline("executor_start",header);
        @try {
            if(![s isStopping])output=[session executeChunk:decoded.request consumed:^{
                if(consumed||releaseFailed){releaseFailed=YES;[s fail:@"Native chunk consumed callback repeated"];return;}
                consumed=YES;
            } cancelled:^BOOL{return [s isStopping];} failure:&failure];
            executeSeconds=chunk_now()-started;started=chunk_now();
            chunk_timeline(output?"gpu_retired":"executor_failed",header);
            if(output&&consumed&&!releaseFailed&&chunk_completion_batch(output,header,decoded.request.records)&&
                chunk_publish_readbacks(output,header,decoded.request.records,returns,s)&&
                chunk_completion(output,header,decoded.request.records,s))completed=YES;
            completionSeconds=chunk_now()-started;
            chunk_timeline(completed?"completion_published":"completion_failed",header);
        } @catch(__unused NSException *exception){failure=@"Native chunk execution or return publication raised an exception";}
        [s.lock lock];s.executeSeconds+=executeSeconds;s.completionSeconds+=completionSeconds;[s.lock unlock];
        if(!completed){BOOL orderly=[s isOrderlySourceClosed];
            if(!orderly||(failure&&[failure rangeOfString:@"cancel" options:NSCaseInsensitiveSearch].location==NSNotFound)){
                [s enqueue:chunk_receipt(header,FFSC_ERROR,FFSC_FAILED)];
                [s fail:failure?:@"Native chunk completion evidence is incomplete"];}
        }else{
            uint64_t uploadBytes=0,readbackBytes=0;
            (void)chunk_u64(output.metrics[@"texture_upload_bytes"],&uploadBytes);
            (void)chunk_u64(output.metrics[@"texture_readback_bytes"],&readbackBytes);
            NSApplication *wakeApplication=nil;
            [s.lock lock];++s.chunks;
            for(NSString *key in @[@"coverage_seconds",@"decode_seconds",@"assets_seconds",@"pipeline_draw_seconds",
                                  @"tables_seconds",@"attachments_seconds",@"commands_seconds"]){
                id number=output.metrics[@"native_render_profile"][key];
                if([number isKindOfClass:[NSNumber class]]){double value=[number doubleValue];
                    if(isfinite(value)&&value>=0)s.renderProfile[key]=@([s.renderProfile[key] doubleValue]+value);}}
            for(NSString *key in @[@"native_operation_seconds",@"native_retirement_seconds",@"native_cleanup_seconds"]){
                id number=output.metrics[key];
                if([number isKindOfClass:[NSNumber class]]){double value=[number doubleValue];
                    if(isfinite(value)&&value>=0)s.renderProfile[key]=@([s.renderProfile[key] doubleValue]+value);}}
            s.textureUploadBytes=uploadBytes>UINT64_MAX-s.textureUploadBytes?UINT64_MAX:s.textureUploadBytes+uploadBytes;
            s.textureReadbackBytes=readbackBytes>UINT64_MAX-s.textureReadbackBytes?UINT64_MAX:s.textureReadbackBytes+readbackBytes;
            s.readbackRanges+=output.bufferReadbacks.count;
            if(output.frameOutput){++s.frames;s.lastFrame=output.frameOutput.metrics;
                [s.outputs addObject:@{@"output":output.frameOutput,@"header":[NSData dataWithBytes:&header length:sizeof(header)]}];
                wakeApplication=s.wakeApplication;}
            [s.lock unlock];
            chunk_wake_presenter(wakeApplication);
        }
        [decoded releasePreparedPayloads];
        [s.lock lock];--s.preparedCount;s.preparedBytes-=decoded.ownedBytes;[s.lock unlock];
        double sampleAt=chunk_now();
        if(sampleAt>=s.nextSessionStatsAt){NSDictionary *stats=[session stats];
            [s.lock lock];s.sessionStats=stats;[s.lock unlock];s.nextSessionStatsAt=sampleAt+1.0;}
    }
}
static void chunk_run(ffsc_endpoint *endpoint,ffrb_endpoint *returns,FFSTChunkWorkerState *s,BOOL diagnostic,int directory) {
    const char *arenaPath=getenv("BEDROCK_NATIVE_SNAPSHOT_ARENA");
    FFSTNativeSnapshotArena *arena=arenaPath?[[FFSTNativeSnapshotArena alloc] initWithPath:arenaPath]:nil;
    /* The mapped two-slot pool is external to the session allocator. Reserve
     * its full capacity inside the same 512-MiB native ownership ceiling. */
    const uint64_t capacity=arenaPath?FFST_NATIVE_FRAME_MAX_BYTES-FFSA_SLOT_COUNT*FFSA_MAX_SLOT_BYTES:
        FFST_NATIVE_FRAME_MAX_BYTES;
    FFSTNativeChunkPayloadCache *cache=arenaPath?(arena?[[FFSTNativeChunkPayloadCache alloc] initWithSnapshotArena:arena]:nil):
        [FFSTNativeChunkPayloadCache new];
    FFSTNativeSession *session=[[FFSTNativeSession alloc] initWithMaxRetainedBytes:capacity diagnosticReadback:diagnostic];
    dispatch_queue_t executor=dispatch_queue_create("bedrock.native-chunk.execute",DISPATCH_QUEUE_SERIAL);
    if(!cache||!session)[s fail:arenaPath?@"Cannot attach shared snapshot arena or create native session":@"Cannot create bounded native session"];
    if(session){[s.lock lock];s.sessionStats=[session stats];[s.lock unlock];}
    BOOL armed=NO;
    while(cache&&session){@autoreleasepool {
        if(!armed&&chunk_arm_file(directory)){
            if(ffsc_arm(endpoint)==FFSC_OK)armed=YES;else [s fail:@"Cannot arm native chunk source"];
        }
        if(!chunk_flush_receipts(endpoint,s))break;
        [s.lock lock];BOOL stopping=s.stopping,closed=s.presentationClosed;
        BOOL pending=s.pending||s.mainOwned||s.outputs.count||s.preparedCount;
        BOOL receiptsPending=[s.mailbox count]!=0;
        BOOL full=s.preparedCount>=s.preparedLimit;[s.lock unlock];
        if(stopping){if(closed&&!pending&&!receiptsPending)break;usleep(1000);continue;}
        if(full){usleep(1000);continue;}
        const void *bytes=NULL;size_t length=0;enum ffsc_result code=ffsc_peek(endpoint,&bytes,&length);
        /* Incoming packets cannot wake this wait for an outgoing presentation
         * receipt. Recheck that mailbox promptly when the source awaits it. */
        if(code==FFSC_EMPTY){(void)ffsc_wait(endpoint,1);continue;}
        if(code==FFSC_SOURCE_CLOSED){[s markOrderlySourceClosed];continue;}
        if(code!=FFSC_OK){[s fail:[NSString stringWithFormat:
            @"Native chunk source transport failed (ffsc_peek=%d, %@)",(int)code,
            code==FFSC_PEER_DEAD?@"peer exited without orderly close":
            code==FFSC_ORDER?@"packet ordering":code==FFSC_INVALID?@"packet/ring validation":@"other"]];continue;}
        ffsc_packet_header timelineHeader;memcpy(&timelineHeader,bytes,sizeof(timelineHeader));
        chunk_timeline("transport_peek",timelineHeader);
        uint64_t reservation=chunk_prepared_upper_bound(bytes);
        for(;;){[s.lock lock];BOOL stop=s.stopping;uint64_t held=s.preparedBytes;uint32_t count=s.preparedCount;[s.lock unlock];
            if(stop||!count||reservation<=capacity-held)break;
            if(!chunk_flush_receipts(endpoint,s))break;usleep(1000);}
        if([s isStopping])continue;
        NSString *failure=nil;FFSTDecodedNativeChunk *decoded=nil;ffsc_packet_header header={0};
        double decodeSeconds=0;BOOL orderlyCancelled=NO;
        @try {
            /* ffsc_peek validated the exact slot while transport credit is
             * owned. Decoder copies every retained record/blob before credit
             * release; avoid copying and validating the whole packet again. */
            NSData *packet=[NSData dataWithBytesNoCopy:(void *)bytes length:length freeWhenDone:NO];
            double started=chunk_now();
            chunk_timeline("decode_start",timelineHeader);
            decoded=[cache decodePeekedPacket:packet failure:&failure];
            chunk_timeline(decoded?"decode_end":"decode_failed",timelineHeader);
            decodeSeconds=chunk_now()-started;
            if(decoded&&!failure&&decoded.request){header=decoded.header;
                if([s isStopping])failure=@"Native chunk cancelled after decode";
                else {enum ffsc_result release=ffsc_consume(endpoint,header.serial);
                    if(release==FFSC_OK)chunk_timeline("transport_consumed",header);
                    if(release==FFSC_SOURCE_CLOSED){[s markOrderlySourceClosed];orderlyCancelled=YES;}
                    else if(release!=FFSC_OK){[s fail:[NSString stringWithFormat:@"Native chunk transport release failed (%d)",(int)release]];
                        failure=@"Native chunk transport release failed";}}
            }
        } @catch(__unused NSException *exception){failure=@"Native chunk decode or transport release raised an exception";}
        NSDictionary *cacheStats=[cache stats];
        [s.lock lock];s.cacheStats=cacheStats;s.decodeSeconds+=decodeSeconds;
        s.packetBytes=length>UINT64_MAX-s.packetBytes?UINT64_MAX:s.packetBytes+length;[s.lock unlock];
        if(orderlyCancelled){[decoded releasePreparedPayloads];continue;}
        if(failure||!decoded||!decoded.request){
            [decoded releasePreparedPayloads];
            /* Source closes the transport before stopping its arena. This
             * exact observation distinguishes orderly shutdown from an arena
             * failure while the source is still publishing packets. */
            if([failure isEqualToString:@"Shared snapshot lease acquisition failed (STOPPED)"]&&
               ffsc_wait(endpoint,0)==FFSC_SOURCE_CLOSED){[s markOrderlySourceClosed];continue;}
            if(header.serial)[s enqueue:chunk_receipt(header,FFSC_ERROR,FFSC_FAILED)];
            [s fail:failure?:@"Native chunk decode evidence is incomplete"];continue;
        }
        [s.lock lock];if(s.preparedCount>=s.preparedLimit||s.preparedBytes>capacity||
            decoded.ownedBytes>capacity-s.preparedBytes){[s.lock unlock];
            [decoded releasePreparedPayloads];
            [s enqueue:chunk_receipt(header,FFSC_ERROR,FFSC_FAILED)];
            [s fail:@"Prepared native ownership exceeds shared 512 MiB cap"];continue;}
        ++s.preparedCount;s.preparedBytes+=decoded.ownedBytes;
        s.maxPreparedCount=MAX(s.maxPreparedCount,s.preparedCount);s.maxPreparedBytes=MAX(s.maxPreparedBytes,s.preparedBytes);
        [s.lock unlock];
        dispatch_async(executor,^{chunk_execute_prepared(session,decoded,header,returns,s);});
    }}
    dispatch_sync(executor,^{[session close];});
    [s.lock lock];s.cacheStats=[cache stats];s.sessionStats=[session stats];[s.lock unlock];
    [cache close];if(returns){ffrb_stop(returns);ffrb_destroy(returns);}ffsc_stop(endpoint);ffsc_destroy(endpoint);
    [s.lock lock];s.finished=YES;[s.lock unlock];
}

int ffst_native_chunk_initialize(const char *path) {
    if(!path||path[0]!='/')return 2;
    int fd=open(path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 2;
    enum ffsc_result code=ffsc_create(fd,FFSC_MAX_SLOTS,FFSC_MAX_PACKET_BYTES);
    BOOL ok=code==FFSC_OK&&!fsync(fd);close(fd);if(!ok)unlink(path);return ok?0:1;
}
int ffst_native_chunk_worker(int directory,const char *path,long timeout,int present) {
    if(![NSThread isMainThread]||!path||path[0]!='/'||timeout<0||timeout>600)return 2;
    const char *age=getenv("BEDROCK_NATIVE_FRAME_AGE");BOOL ageEnabled=age&&!strcmp(age,"1");
    NSString *runID=ageEnabled?chunk_frame_age_run_id():nil;
    if(ageEnabled&&!runID)return 2;
    const char *offscreenMode=getenv("BEDROCK_NATIVE_OFFSCREEN");
    BOOL offscreen=offscreenMode&&!strcmp(offscreenMode,"1");
    if(offscreen&&!present)return 2;
    pid_t sessionParent=0;
    if(!timeout){
        const char *session=getenv("BEDROCK_FULLFRAME_SESSION_UNTIL_QUIT");
        const char *render=getenv("BEDROCK_FULLFRAME_NATIVE_RENDER_SESSION");
        const char *parent=getenv("BEDROCK_FULLFRAME_SESSION_PARENT_PID");
        char *end=NULL;long value=parent?strtol(parent,&end,10):0;
        if(!present||!session||strcmp(session,"1")||!render||strcmp(render,"1")||
            !parent||!*parent||!end||*end||value<=1||value>INT32_MAX||getppid()!=(pid_t)value)return 2;
        const char *readback=getenv(FFRB_ENDPOINT_ENV);
        if(!readback||!*readback)return 2;
        sessionParent=(pid_t)value;
    }
    int fd=open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);ffsc_endpoint *endpoint=NULL;
    enum ffsc_result code=fd>=0?ffsc_attach(fd,FFSC_NATIVE,&endpoint):FFSC_INVALID;if(fd>=0)close(fd);
    if(code!=FFSC_OK)return 2;
    ffrb_endpoint *returns=NULL;const char *returnPath=getenv(FFRB_ENDPOINT_ENV);
    if(returnPath&&*returnPath){
        int returnFD=returnPath[0]=='/'?open(returnPath,O_RDWR|O_NOFOLLOW|O_CLOEXEC):-1;
        enum ffrb_result result=returnFD>=0?ffrb_attach(returnFD,FFRB_NATIVE,&returns):FFRB_INVALID;
        if(returnFD>=0)close(returnFD);
        if(result!=FFRB_OK){ffsc_destroy(endpoint);return 2;}
    }
    FFSTChunkWorkerState *s=[FFSTChunkWorkerState new];ff_native_presenter *presenter=NULL;
    s.offscreen=offscreen;s.frameAgeEnabled=ageEnabled;s.frameAgeRunID=runID;
    uint32_t snapshotsAccepted=0;
    const char *value=getenv("BEDROCK_FULLFRAME_CHUNK_DIAGNOSTIC");BOOL diagnostic=value&&!strcmp(value,"1"),wrotePixels=NO;
    dispatch_queue_t worker=dispatch_queue_create("bedrock.native-chunk.worker",DISPATCH_QUEUE_SERIAL);
    dispatch_async(worker,^{@autoreleasepool {chunk_run(endpoint,returns,s,diagnostic,directory);}});
    double start=chunk_now(),closedAt=0,nextProgress=start;
    for(;;){@autoreleasepool {
        double now=chunk_now();
        if(now>=nextProgress){nextProgress=now+1.0;
            if(chunk_arm_token(directory,"qa-progress.arm")&&!chunk_progress(directory,s))
                [s fail:@"Cannot publish requested QA progress"];}
        if(chunk_stop_file(directory)||(timeout&&chunk_now()-start>=timeout)||(sessionParent&&getppid()!=sessionParent)){[s.lock lock];s.stopping=YES;[s.lock unlock];}
        ff_present_stats beforePump={0};if(presenter)ff_presenter_get_stats(presenter,&beforePump);
        [s.lock lock];BOOL outputReady=s.outputs.count&&(!present||!beforePump.pending||s.stopping);[s.lock unlock];
        if(presenter&&!ff_presenter_pump(presenter,outputReady?0:0.01)){[s.lock lock];s.stopping=YES;[s.lock unlock];}
        ff_present_stats presenterStats={0};if(presenter)ff_presenter_get_stats(presenter,&presenterStats);
        [s.lock lock];s.displayStats=presenterStats;[s.lock unlock];
        [s.lock lock];BOOL finished=s.finished;NSArray *outputs=@[];
        /* A hidden/new presenter may keep its pending frame across pumps.
         * Preserve following frames in the bounded queue until that slot is
         * free. Stopping still owns/cancels queued frames normally. */
        if(s.outputs.count&&(!present||!presenter||!presenterStats.pending||s.stopping)){
            outputs=@[s.outputs.firstObject];++s.mainOwned;[s.outputs removeObjectAtIndex:0];
        }
        [s.lock unlock];
        BOOL submittedNow=NO;
        for(NSDictionary *item in outputs){
          @try {
            FFSTNativeFrameExecution *output=item[@"output"];ffsc_packet_header header;memcpy(&header,[item[@"header"] bytes],sizeof(header));
            if(diagnostic&&!wrotePixels&&output.pixels){wrotePixels=chunk_write(directory,"chunk-first-frame.bgra",output.pixels);
                if(!wrotePixels||!chunk_json(directory,"chunk-first-frame.json",output.metrics))[s fail:@"Cannot save native diagnostic frame"];
            }
            if(!present)continue;
            uint64_t digest=0;
            if(!chunk_u64(output.metrics[@"ledger_digest"],&digest)){[s fail:@"Native Present lacks frame digest"];continue;}
            if([s isStopping]){ffsc_receipt r=chunk_receipt(header,s.offscreen?FFSC_OFFSCREEN_COMPLETED:FFSC_PRESENTED,FFSC_CANCELLED);r.value=digest;[s enqueue:r];continue;}
            if(!presenter){char error[256]={0};
                uint32_t width=(uint32_t)MIN(output.texture.width,1200),height=(uint32_t)MIN(output.texture.height,800);
                presenter=s.offscreen?ff_presenter_create_offscreen((__bridge void *)output.texture.device,width,height,error,sizeof(error)):
                    ff_presenter_create_with_activation((__bridge void *)output.texture.device,"ARM64 Metal continuous output",width,height,0,error,sizeof(error));
                if(presenter&&!s.offscreen){[s.lock lock];s.wakeApplication=NSApp;[s.lock unlock];}}
            if(!presenter){ffsc_receipt r=chunk_receipt(header,s.offscreen?FFSC_OFFSCREEN_COMPLETED:FFSC_PRESENTED,FFSC_FAILED);r.value=digest;[s enqueue:r];[s fail:@"Cannot create native presenter"];continue;}
            BOOL snapshotNow=NO;
            if(s.offscreen&&snapshotsAccepted<32&&chunk_arm_token(directory,"offscreen-snapshot.request")){
                BOOL snapshotIdle=NO;
                [s.lock lock];snapshotIdle=![s.snapshot[@"status"] isEqual:@"pending"];[s.lock unlock];
                /* The caller archives both fixed outputs before requesting again.
                 * Do not overwrite evidence or allocate a second readback. */
                BOOL outputsArchived=faccessat(directory,"offscreen-snapshot.png",F_OK,0)!=0&&
                    faccessat(directory,"offscreen-snapshot.json",F_OK,0)!=0;
                if(snapshotIdle&&outputsArchived){
                if(unlinkat(directory,"offscreen-snapshot.request",0)){[s fail:@"Cannot consume offscreen snapshot request"];continue;}
                snapshotNow=YES;++snapshotsAccepted;
                [s.lock lock];s.snapshot=@{ @"status":@"pending",@"serial":@(header.serial),@"frame":@(header.frame) };[s.lock unlock];
                }
            }
            FFSTChunkPresentation *context=[FFSTChunkPresentation new];context.state=s;context.header=header;context.frameDigest=digest;
            FFSTChunkSnapshot *snapshotContext=snapshotNow?[FFSTChunkSnapshot new]:nil;
            if(snapshotContext){snapshotContext.state=s;snapshotContext.header=header;snapshotContext.frameDigest=digest;
                snapshotContext.directory=fcntl(directory,F_DUPFD_CLOEXEC,0);}
            [s.lock lock];++s.pending;++s.submitted;[s.lock unlock];
            void *owned=(__bridge_retained void *)context;
            void *ownedSnapshot=snapshotContext?(__bridge_retained void *)snapshotContext:NULL;
            chunk_timeline("present_submit",header);
            ff_present_identity identity={.stream=header.stream,.frame=header.frame,.chunk=header.chunk,
                .serial=header.serial,.queue_completion=header.queue_completion};
            if(!ff_presenter_submit_snapshot_tagged(presenter,(__bridge void *)output.texture,chunk_presented,owned,
                snapshotNow?chunk_snapshot_completed:NULL,ownedSnapshot,s.frameAgeEnabled?&identity:NULL)){
                if(ownedSnapshot)chunk_snapshot_completed(ownedSnapshot,NULL,0,0,0,FF_PRESENT_GPU_ERROR);
                chunk_presented(owned,FF_PRESENT_GPU_ERROR);
            }
            else submittedNow=YES;
          } @finally {[s.lock lock];--s.mainOwned;[s.lock unlock];}
        }
        /* Submit queues a frame; draw it once without another event deadline.
         * Release mainOwned first. Hidden/GPU-blocked pending frames retain the
         * ordinary timed pump on later iterations, never a zero-wait spin. */
        if(submittedNow&&![s isStopping]&&!ff_presenter_pump(presenter,0)){
            [s.lock lock];s.stopping=YES;[s.lock unlock];}
        if([s isStopping]&&!closedAt){if(presenter)ff_presenter_close(presenter);closedAt=chunk_now();
            [s.lock lock];s.presentationClosed=YES;[s.lock unlock];}
        /* A late callback retains its mailbox, never the destroyed endpoint. */
        if(closedAt&&chunk_now()-closedAt>5){[s.lock lock];if(s.pending){if(!s.failure)s.failure=@"Native presentation shutdown timed out";s.pending=0;}[s.lock unlock];}
        if(finished)break;if(!presenter)usleep(1000);
    }}
    if(presenter){ff_present_stats finalStats={0};ff_presenter_get_stats(presenter,&finalStats);
        if(!chunk_write_present_samples(directory,presenter,&finalStats,s.frameAgeRunID))[s fail:@"Cannot write presentation samples"];
        [s.lock lock];s.displayStats=finalStats;[s.lock unlock];ff_presenter_destroy(presenter);}
    if(chunk_arm_token(directory,"qa-progress.arm")&&!chunk_progress(directory,s))
        [s fail:@"Cannot publish final QA progress"];
    [s.lock lock];BOOL ok=s.chunks&&!s.failure&&(!present||(s.offscreen?s.offscreenGPUCompleted:s.presented));
    NSMutableDictionary *result=[@{@"format":@"bedrock-native-chunk-worker",@"version":@1,@"status":ok?@"completed":@"failed",
        @"chunks":@(s.chunks),@"frames":@(s.frames),@"presentation_submitted":@(s.submitted),@"presentation_completed":@(s.presented),
        @"render_mode":s.offscreen?@"offscreen_gpu":@"drawable",@"offscreen_gpu_completed":@(s.offscreenGPUCompleted),
        @"offscreen_snapshot":s.snapshot?:@{ @"status":@"not_requested" },
        @"offscreen_snapshots_completed":@(s.offscreenSnapshotsCompleted),
        @"texture_upload_bytes":@(s.textureUploadBytes),
        @"texture_readback_bytes":@(s.textureReadbackBytes),@"readback_ranges":@(s.readbackRanges),
        @"packet_bytes":@(s.packetBytes),@"decode_seconds":@(s.decodeSeconds),
        @"execute_seconds":@(s.executeSeconds),@"completion_publish_seconds":@(s.completionSeconds),
        @"prepared_limit":@(s.preparedLimit),@"prepared_chunks":@(s.preparedCount),@"prepared_bytes":@(s.preparedBytes),
        @"max_prepared_chunks":@(s.maxPreparedCount),@"max_prepared_bytes":@(s.maxPreparedBytes),
        @"presentation_superseded":@(s.superseded),@"presentation_cancelled":@(s.cancelled),@"presentation_errors":@(s.presentationErrors),
        @"error":s.failure?:@"",@"cache":s.cacheStats?:@{},@"session":s.sessionStats?:@{},@"last_frame":s.lastFrame?:@{},
        @"orderly_source_closed":@(s.orderlySourceClosed),
        @"native_render_profile":[s.renderProfile copy],@"actual_display":chunk_display_stats(s.displayStats)} mutableCopy];
    if(s.frameAgeRunID)result[@"run_id"]=s.frameAgeRunID;
    [s.lock unlock];
    if(!chunk_json(directory,"chunk-worker-result.json",result))ok=NO;return ok?0:1;
}
