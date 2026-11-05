#import "native_frame_worker.h"
#import "native_frame_files.h"
#import "native_presenter.h"
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error native_frame_worker.m requires ARC
#endif
static BOOL worker_write(int directory,NSString *name,NSData *data) {
    if(!data)return NO;
    int fd=openat(directory,name.fileSystemRepresentation,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;size_t left=data.length;const uint8_t *bytes=data.bytes;
    while(left){ssize_t n=write(fd,bytes,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;left-=n;bytes+=n;}
    BOOL ok=!left&&!fsync(fd);if(close(fd))ok=NO;if(!ok)unlinkat(directory,name.fileSystemRepresentation,0);return ok;
}
static BOOL worker_json(int directory,NSString *name,NSDictionary *value) {
    return worker_write(directory,name,[NSJSONSerialization dataWithJSONObject:value options:0 error:nil]);
}
#ifndef FFST_WORKER_RECEIPT_WAIT_MILLISECONDS
#define FFST_WORKER_RECEIPT_WAIT_MILLISECONDS 5000
#endif
@class FFSTWorkerPresentation;
@interface FFSTWorkerReceipts : NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) dispatch_queue_t writer;
@property(nonatomic) uint64_t submitted,pending,completed,superseded,closed,gpuErrors,writeErrors,rejected;
- (NSDictionary *)snapshot;
- (void)settle:(FFSTWorkerPresentation *)context result:(ff_present_result)result;
@end
@interface FFSTWorkerPresentation : NSObject
@property(nonatomic) int directory;
@property(nonatomic) uint64_t stream,frame,digest;
@property(nonatomic,strong) NSDictionary *renderEvidence;
@property(nonatomic,strong) FFSTWorkerReceipts *receipts;
@end
@implementation FFSTWorkerPresentation
- (instancetype)init {self=[super init];if(self)_directory=-1;return self;}
- (void)dealloc {if(_directory>=0)close(_directory);}
@end
@implementation FFSTWorkerReceipts
- (instancetype)init {
    self=[super init];if(self){_lock=[NSLock new];_writer=dispatch_queue_create("bedrock.native-frame.receipts",DISPATCH_QUEUE_SERIAL);}return self;
}
- (NSDictionary *)snapshot {
    [_lock lock];NSDictionary *value=@{@"submitted":@(_submitted),@"pending":@(_pending),@"completed":@(_completed),
        @"superseded":@(_superseded),@"closed":@(_closed),@"gpu_errors":@(_gpuErrors),@"write_errors":@(_writeErrors),@"rejected":@(_rejected)};
    [_lock unlock];return value;
}
- (void)settle:(FFSTWorkerPresentation *)context result:(ff_present_result)result {
    /* A callback may outlive both presenter and worker. The retained context
     * owns its directory description; this serial task owns it until fsync. */
    dispatch_async(_writer,^{@autoreleasepool {
        NSString *status;
        switch(result){case FF_PRESENT_COMPLETED:status=@"completed";break;case FF_PRESENT_SUPERSEDED:status=@"superseded";break;
            case FF_PRESENT_CLOSED:status=@"closed";break;default:status=@"gpu_error";break;}
        NSString *name=[NSString stringWithFormat:@"frame-%llu-%llu.presentation-result.json",(unsigned long long)context.stream,(unsigned long long)context.frame];
        BOOL written=worker_json(context.directory,name,@{@"format":@"bedrock-native-frame-presentation",@"version":@1,
            @"stream":@(context.stream),@"frame":@(context.frame),@"ledger_digest":@(context.digest),@"status":status,
            @"presenter_completed":@((BOOL)(result==FF_PRESENT_COMPLETED)),@"render_evidence":context.renderEvidence});
        [self.lock lock];
        if(result==FF_PRESENT_COMPLETED)++self->_completed;else if(result==FF_PRESENT_SUPERSEDED)++self->_superseded;
        else if(result==FF_PRESENT_CLOSED)++self->_closed;else ++self->_gpuErrors;
        if(!written)++self->_writeErrors;--self->_pending;[self.lock unlock];
    }});
}
@end
static void worker_presented(void *opaque,ff_present_result result) {
    FFSTWorkerPresentation *context=(__bridge_transfer FFSTWorkerPresentation *)opaque;
    [context.receipts settle:context result:result];
}
static FFSTWorkerPresentation *worker_presentation(int directory,uint64_t stream,uint64_t frame,
    NSDictionary *metrics,FFSTWorkerReceipts *receipts) {
    if(![metrics[@"stream"] isEqual:@(stream)]||![metrics[@"frame"] isEqual:@(frame)]||
       ![metrics[@"ledger_digest"] isKindOfClass:[NSNumber class]])return nil;
    const char *type=[metrics[@"ledger_digest"] objCType];
    if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0]))return nil;
    int owned=fcntl(directory,F_DUPFD_CLOEXEC,0);if(owned<0)return nil;
    FFSTWorkerPresentation *context=[FFSTWorkerPresentation new];context.directory=owned;
    context.stream=stream;context.frame=frame;context.digest=[metrics[@"ledger_digest"] unsignedLongLongValue];
    context.renderEvidence=metrics;context.receipts=receipts;return context;
}
static BOOL worker_stop(int directory) {
    int fd=openat(directory,"presentation.stop",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC);if(fd<0)return NO;
    struct stat s;char bytes[6]={0};BOOL stop=!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==getuid()&&
        !(s.st_mode&077)&&s.st_size==5&&read(fd,bytes,sizeof(bytes))==5&&!memcmp(bytes,"stop\n",5);close(fd);return stop;
}
static NSString *next_marker(int directory,uint64_t stream,uint64_t frame,BOOL *invalid) {
    /* Open a new directory description: dup would share readdir's offset. */
    int scan=openat(directory,".",O_RDONLY|O_DIRECTORY|O_CLOEXEC);DIR *dir=scan>=0?fdopendir(scan):NULL;
    if(!dir){if(scan>=0)close(scan);*invalid=YES;return nil;}
    NSString *selected=nil;uint64_t bestStream=UINT64_MAX,bestFrame=UINT64_MAX;unsigned count=0;
    struct dirent *entry;while((entry=readdir(dir))){
        if(++count>8192){*invalid=YES;break;}
        unsigned long long a,b;int used=0;
        if(sscanf(entry->d_name,"frame-%llu-%llu.ready.json%n",&a,&b,&used)!=2||!used||entry->d_name[used])continue;
        NSString *name=[NSString stringWithUTF8String:entry->d_name];
        if(!a||!b||![name isEqual:[NSString stringWithFormat:@"frame-%llu-%llu.ready.json",a,b]]){*invalid=YES;break;}
        if(a<stream||(a==stream&&b<=frame))continue;
        if(a<bestStream||(a==bestStream&&b<bestFrame)){bestStream=a;bestFrame=b;selected=name;}
    }closedir(dir);return *invalid?nil:selected;
}

int ffst_native_frame_worker(int directory,long timeout,int present) {
    if(![NSThread isMainThread]||timeout<1||timeout>600)return 2;
    NSLock *lock=[NSLock new];NSMutableArray<NSDictionary *> *completed=[NSMutableArray new];
    NSMutableDictionary<NSString *,FFSTNativeFrameExecution *> *outputs=[NSMutableDictionary new];
    dispatch_queue_t delivery=dispatch_queue_create("bedrock.native-frame.delivery",DISPATCH_QUEUE_SERIAL);
    dispatch_queue_t ingestion=dispatch_queue_create("bedrock.native-frame.ingestion",DISPATCH_QUEUE_SERIAL);
    __block BOOL loading=NO,loadReady=NO;
    __block FFSTNativeFrameRequest *loaded=nil;
    __block NSString *loadFailure=nil,*loadMarker=nil;
    FFSTNativeFrameQueue *queue=[[FFSTNativeFrameQueue alloc] initWithMaxRetainedBytes:FFST_FRAME_QUEUE_HARD_BYTES
        callbackQueue:delivery executor:^(id<FFSTQueuedFrame> value,FFSTFrameCancellation cancelled,FFSTFrameExecutorCompletion done){
            @autoreleasepool {
                FFSTNativeFrameRequest *request=(FFSTNativeFrameRequest *)value;NSString *failure=nil;
                FFSTNativeFrameExecution *output=ffst_native_frame_execute(request,nil,cancelled,&failure);
                NSString *key=[NSString stringWithFormat:@"%llu:%llu",(unsigned long long)request.streamID,(unsigned long long)request.frameID];
                if(output){[lock lock];outputs[key]=output;[lock unlock];done(output.metrics,nil);}
                else done(@{},[NSError errorWithDomain:@"bedrock.native-frame" code:1
                    userInfo:@{NSLocalizedDescriptionKey:failure?:@"Native frame execution failed"}]);
            }
        } observer:^(uint64_t stream,uint64_t frame,BOOL cancelled,NSDictionary *evidence,NSError *error){
            [lock lock];[completed addObject:@{@"stream":@(stream),@"frame":@(frame),@"cancelled":@(cancelled),
                @"evidence":evidence?:@{},@"error":error.localizedDescription?:@""}];[lock unlock];
        }];
    if(!queue)return 2;
    ff_native_presenter *presenter=NULL;FFSTWorkerReceipts *receipts=[FFSTWorkerReceipts new];
    uint64_t lastStream=0,lastFrame=0,rendered=0;BOOL stopping=NO,failed=NO,wrotePixels=NO;
    struct timespec started,now;clock_gettime(CLOCK_MONOTONIC,&started);
    for(;;){@autoreleasepool {
        clock_gettime(CLOCK_MONOTONIC,&now);
        if(worker_stop(directory)||now.tv_sec-started.tv_sec>=timeout)stopping=YES;
        if(presenter&&!ff_presenter_pump(presenter,0.01))stopping=YES;
        if(stopping)[queue close];
        [lock lock];NSArray *ready=[completed copy];[completed removeAllObjects];[lock unlock];
        for(NSDictionary *item in ready){
            uint64_t stream=[item[@"stream"] unsignedLongLongValue],frame=[item[@"frame"] unsignedLongLongValue];
            NSString *key=[NSString stringWithFormat:@"%llu:%llu",(unsigned long long)stream,(unsigned long long)frame];
            [lock lock];FFSTNativeFrameExecution *output=outputs[key];[outputs removeObjectForKey:key];[lock unlock];
            NSMutableDictionary *evidence=[item mutableCopy];evidence[@"format"]=@"bedrock-native-frame-worker-result";evidence[@"version"]=@1;
            evidence[@"status"]=output?(present?@"rendered":@"completed"):@"rejected";
            if(output&&present)evidence[@"presentation_status"]=stopping?@"not_submitted":@"pending";
            NSString *base=[NSString stringWithFormat:@"frame-%llu-%llu",(unsigned long long)stream,(unsigned long long)frame];
            if(!output){failed=YES;stopping=YES;}
            else {
                ++rendered;
                if(!wrotePixels){wrotePixels=worker_write(directory,[base stringByAppendingString:@".bgra"],output.pixels);if(!wrotePixels){failed=YES;stopping=YES;}}
                if(present&&!stopping){
                    if(!presenter){char error[256]={0};presenter=ff_presenter_create((__bridge void *)output.texture.device,
                        "ARM64 Metal frame output",(uint32_t)MIN(output.texture.width,1200),(uint32_t)MIN(output.texture.height,800),error,sizeof(error));}
                    FFSTWorkerPresentation *context=presenter?worker_presentation(directory,stream,frame,output.metrics,receipts):nil;
                    if(!context){evidence[@"presentation_status"]=@"submit_rejected";failed=YES;stopping=YES;}
                    else {
                        [receipts.lock lock];++receipts.submitted;++receipts.pending;[receipts.lock unlock];
                        void *owned=(__bridge_retained void *)context;
                        if(!ff_presenter_submit(presenter,(__bridge void *)output.texture,worker_presented,owned)){
                            /* The submit contract guarantees no callback on rejection. */
                            (void)CFBridgingRelease(owned);
                            [receipts.lock lock];--receipts.submitted;--receipts.pending;++receipts.rejected;[receipts.lock unlock];
                            evidence[@"presentation_status"]=@"submit_rejected";failed=YES;stopping=YES;
                        }
                    }
                }
            }
            if(!worker_json(directory,[base stringByAppendingString:@".native-result.json"],evidence)){failed=YES;stopping=YES;}
        }
        [lock lock];BOOL ingested=loadReady,inProgress=loading;
        FFSTNativeFrameRequest *request=ingested?loaded:nil;
        NSString *reason=ingested?loadFailure:nil,*finishedMarker=ingested?loadMarker:nil;
        if(ingested){loadReady=NO;loaded=nil;loadFailure=nil;loadMarker=nil;}[lock unlock];
        if(ingested&&!stopping){
            if(!request||[queue submit:request]!=FFSTFrameAccepted){
                worker_json(directory,@"frame-rejected.json",@{@"status":@"rejected",@"marker":finishedMarker?:@"",
                    @"reason":reason?:@"Frame queue rejected request"});failed=YES;stopping=YES;
            }else{lastStream=request.streamID;lastFrame=request.frameID;}
        }
        NSDictionary *state=[queue stats];
        [lock lock];BOOL mailboxPending=completed.count!=0;[lock unlock];
        /* Queue slots retire only after observer delivery. Once outstanding is
         * zero this mailbox check sees every result already delivered. */
        if(stopping&&![state[@"outstanding"] unsignedLongLongValue]&&!inProgress&&!mailboxPending)break;
        /* Submit only after delivering the previous result, bounding retained
         * pixels/textures independently from the queue's request-byte budget. */
        if(!stopping&&!inProgress&&!mailboxPending&&![state[@"outstanding"] unsignedLongLongValue]){
            BOOL invalid=NO;NSString *marker=next_marker(directory,lastStream,lastFrame,&invalid);
            if(invalid){failed=YES;stopping=YES;}
            if(marker){
                [lock lock];loading=YES;[lock unlock];
                dispatch_async(ingestion,^{@autoreleasepool {
                    NSString *failure=nil;FFSTNativeFrameRequest *value=nil;
                    @try {value=ffst_frame_request_from_files(directory,marker,&failure);}
                    @catch(__unused NSException *exception){failure=@"Frame ingestion raised an exception";}
                    [lock lock];loaded=value;loadFailure=failure;loadMarker=marker;loading=NO;loadReady=YES;[lock unlock];
                }});
            }
        }
        if(!presenter)usleep(10000);
    }}
    [queue close];
    if(presenter){ff_presenter_close(presenter);
        for(unsigned i=0;i<FFST_WORKER_RECEIPT_WAIT_MILLISECONDS;i++){
            if(![[receipts snapshot][@"pending"] unsignedLongLongValue])break;usleep(1000);}
        ff_presenter_destroy(presenter);
    }
    NSDictionary *presentation=[receipts snapshot];
    BOOL success=rendered&&!failed&&(!present||([presentation[@"submitted"] unsignedLongLongValue]==rendered&&
        [presentation[@"completed"] unsignedLongLongValue]==rendered&&![presentation[@"pending"] unsignedLongLongValue]&&
        ![presentation[@"write_errors"] unsignedLongLongValue]));
    worker_json(directory,@"frame-worker-result.json",@{@"format":@"bedrock-native-frame-worker",@"version":@1,
        @"status":success?@"completed":@"failed",@"rendered_frames":@(rendered),@"queue":[queue stats],
        @"presentation":presentation,@"presentation_completed":presentation[@"completed"],@"presentation_gpu_errors":presentation[@"gpu_errors"]});
    return success?0:1;
}
