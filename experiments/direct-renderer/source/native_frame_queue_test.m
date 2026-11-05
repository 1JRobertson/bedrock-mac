/* Focused CPU lifecycle fixture. No Metal, IPC, game, account or timing-based GPU proof. */
#import "native_frame_queue.h"
#include <stdio.h>

static unsigned checks;
#define CHECK(value) do { ++checks; if (!(value)) { fprintf(stderr,"frame queue fixture failed line %u\n",__LINE__); return 1; } } while(0)
static BOOL wait_signal(dispatch_semaphore_t semaphore) {
    return !dispatch_semaphore_wait(semaphore,dispatch_time(DISPATCH_TIME_NOW,5*NSEC_PER_SEC));
}
@interface TestFrame:NSObject<FFSTQueuedFrame>
@property(nonatomic) uint64_t streamID;
@property(nonatomic) uint64_t frameID;
@property(nonatomic) size_t retainedBytes;
@end
@implementation TestFrame @end
static TestFrame *frame(uint64_t stream,uint64_t identifier,size_t bytes) {
    TestFrame *r=[TestFrame new]; r.streamID=stream; r.frameID=identifier; r.retainedBytes=bytes; return r;
}
@interface Harness:NSObject
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSMutableArray *callbacks;
@property(nonatomic,strong) NSMutableArray *predicates;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *started;
@property(nonatomic,strong) NSMutableArray<NSDictionary *> *observed;
@property(nonatomic,strong) dispatch_semaphore_t begins;
@property(nonatomic,strong) dispatch_semaphore_t results;
@property(nonatomic,strong) dispatch_queue_t deliveries;
@end
@implementation Harness
- (instancetype)init {
    self=[super init]; if(self){_lock=[NSLock new];_callbacks=[NSMutableArray array];_predicates=[NSMutableArray array];
        _started=[NSMutableArray array];_observed=[NSMutableArray array];_begins=dispatch_semaphore_create(0);
        _results=dispatch_semaphore_create(0);_deliveries=dispatch_queue_create("fixture.frame-observer",DISPATCH_QUEUE_SERIAL);}
    return self;
}
@end
static FFSTFrameObserver observer(Harness *h) {
    return ^(uint64_t stream,uint64_t identifier,BOOL cancelled,NSDictionary *facts,NSError *error){
        [h.lock lock]; [h.observed addObject:@{@"stream":@(stream),@"frame":@(identifier),@"cancelled":@(cancelled),
            @"evidence":facts ?: (id)[NSNull null],@"error":error ? @(error.code) : (id)[NSNull null]}];
        [h.lock unlock]; dispatch_semaphore_signal(h.results);
    };
}
static FFSTFrameExecutor asynchronous(Harness *h) {
    return ^(id<FFSTQueuedFrame> request,FFSTFrameCancellation cancelled,FFSTFrameExecutorCompletion complete){
        [h.lock lock];[h.started addObject:@(request.frameID)];[h.callbacks addObject:[complete copy]];
        [h.predicates addObject:[cancelled copy]];[h.lock unlock];dispatch_semaphore_signal(h.begins);
    };
}
static NSDictionary *facts(void) {return @{@"backend":@"cpu-fixture",@"gpu_calls":@0,@"leases_retired":@YES};}
static BOOL stats_reach(FFSTNativeFrameQueue *q,NSString *key,uint64_t expected) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:5];
    do {if([q.stats[key] unsignedLongLongValue]==expected)return YES;[NSThread sleepForTimeInterval:0.001];}
    while([deadline timeIntervalSinceNow]>0);return NO;
}
static int cancellation_and_ownership(void) {
    Harness *h=[Harness new];
    FFSTNativeFrameQueue *q=[[FFSTNativeFrameQueue alloc]initWithMaxRetainedBytes:8 callbackQueue:h.deliveries executor:asynchronous(h) observer:observer(h)];
    CHECK(q!=nil);
    __weak TestFrame *first=nil; __weak TestFrame *second=nil;
    @autoreleasepool {TestFrame *r=frame(1,1,4);first=r;CHECK([q submit:r]==FFSTFrameAccepted);}
    CHECK(wait_signal(h.begins));
    @autoreleasepool {TestFrame *r=frame(1,2,4);second=r;CHECK([q submit:r]==FFSTFrameAccepted);}
    @autoreleasepool {CHECK(first!=nil&&second!=nil);}
    CHECK([q submit:frame(1,3,1)]==FFSTFrameBackpressure);
    CHECK([q submit:frame(1,1,1)]==FFSTFrameOrder);
    CHECK([q submit:frame(2,1,1)]==FFSTFrameOrder);
    CHECK([q submit:frame(1,3,9)]==FFSTFrameInvalid);
    CHECK([q submit:nil]==FFSTFrameInvalid);
    @autoreleasepool {CHECK([q cancelStream:1 frame:2]);}
    @autoreleasepool {CHECK(second==nil&&first!=nil);}
    CHECK([q.stats[@"retained_bytes"] unsignedLongLongValue]==4);
    CHECK([q.stats[@"outstanding"] unsignedLongLongValue]==2);
    CHECK(![q cancelStream:1 frame:99]);
    CHECK(dispatch_semaphore_wait(h.results,DISPATCH_TIME_NOW)!=0); /* no out-of-order pending cancellation result */
    [q close]; CHECK([q submit:frame(1,3,1)]==FFSTFrameClosed);
    FFSTFrameCancellation cancelled=h.predicates[0];CHECK(cancelled());@autoreleasepool {CHECK(first!=nil);}
    FFSTFrameExecutorCompletion complete=h.callbacks[0];CHECK(complete(facts(),nil));CHECK(!complete(facts(),nil));
    CHECK(wait_signal(h.results));CHECK(wait_signal(h.results));dispatch_sync(h.deliveries,^{});
    CHECK(first==nil&&second==nil);
    CHECK(h.observed.count==2&&[h.observed[0][@"frame"] isEqual:@1]&&[h.observed[1][@"frame"] isEqual:@2]);
    CHECK([h.observed[0][@"cancelled"] boolValue]&&[h.observed[1][@"error"] integerValue]==FFSTFrameCancelledBeforeExecution);
    CHECK([q.stats[@"retired"] unsignedLongLongValue]==1&&[q.stats[@"cancelled_pending"] unsignedLongLongValue]==1);
    CHECK([q.stats[@"duplicate_completions"] unsignedLongLongValue]==1&&[q.stats[@"outstanding"] unsignedLongLongValue]==0);
    CHECK([q.stats[@"retained_bytes"] unsignedLongLongValue]==0&&q.history.count==2);
    return 0;
}
static int callback_bounds_and_streams(void) {
    Harness *h=[Harness new];dispatch_semaphore_t gate=dispatch_semaphore_create(0),blocked=dispatch_semaphore_create(0);
    dispatch_async(h.deliveries,^{dispatch_semaphore_signal(blocked);dispatch_semaphore_wait(gate,DISPATCH_TIME_FOREVER);});
    CHECK(wait_signal(blocked));
    __block __weak FFSTNativeFrameQueue *weakQueue=nil;__block BOOL retainedDuringInline=YES;
    FFSTFrameExecutor execute=^(id<FFSTQueuedFrame> request,FFSTFrameCancellation cancelled,FFSTFrameExecutorCompletion complete){
        (void)cancelled;
        [h.lock lock];[h.started addObject:@(request.frameID)];[h.lock unlock];
        BOOL accepted=complete(facts(),nil);
        if(!accepted||[weakQueue.stats[@"retained_bytes"] unsignedLongLongValue]<request.retainedBytes)retainedDuringInline=NO;
        dispatch_semaphore_signal(h.begins);
    };
    FFSTNativeFrameQueue *q=[[FFSTNativeFrameQueue alloc]initWithMaxRetainedBytes:8 callbackQueue:h.deliveries executor:execute observer:observer(h)];weakQueue=q;
    CHECK([q submit:frame(10,1,4)]==FFSTFrameAccepted);CHECK([q submit:frame(10,2,4)]==FFSTFrameAccepted);
    CHECK(wait_signal(h.begins));CHECK(wait_signal(h.begins));CHECK(stats_reach(q,@"retired",2));
    CHECK(retainedDuringInline);CHECK([q.stats[@"outstanding"] unsignedLongLongValue]==2);
    CHECK([q submit:frame(10,3,4)]==FFSTFrameBackpressure);CHECK(q.history.count==0);
    dispatch_semaphore_signal(gate);CHECK(wait_signal(h.results));CHECK(wait_signal(h.results));dispatch_sync(h.deliveries,^{});
    CHECK(([h.started isEqual:@[@1,@2]]));
    for(uint64_t identifier=3;identifier<=20;++identifier){
        CHECK([q submit:frame(10,identifier,4)]==FFSTFrameAccepted);CHECK(wait_signal(h.begins));
        CHECK(wait_signal(h.results));dispatch_sync(h.deliveries,^{});
    }
    CHECK(q.history.count==FFST_FRAME_QUEUE_HISTORY);
    CHECK([q.history.firstObject[@"frame_id"] unsignedLongLongValue]==13);
    CHECK([q submit:frame(11,1,4)]==FFSTFrameAccepted);CHECK(wait_signal(h.begins));CHECK(wait_signal(h.results));dispatch_sync(h.deliveries,^{});
    CHECK([q submit:frame(10,21,4)]==FFSTFrameOrder);CHECK([q submit:frame(11,1,4)]==FFSTFrameOrder);
    [q close];CHECK([q.stats[@"outstanding"] unsignedLongLongValue]==0);
    return 0;
}
static int evidence_and_exception(void) {
    Harness *h=[Harness new];
    FFSTNativeFrameQueue *q=[[FFSTNativeFrameQueue alloc]initWithMaxRetainedBytes:0 callbackQueue:h.deliveries executor:asynchronous(h) observer:observer(h)];
    CHECK([q.stats[@"max_retained_bytes"] unsignedLongLongValue]==FFST_FRAME_QUEUE_DEFAULT_BYTES);
    CHECK([q submit:frame(1,1,1)]==FFSTFrameAccepted);CHECK(wait_signal(h.begins));
    FFSTFrameExecutorCompletion complete=h.callbacks[0];CHECK(complete(@{@"invalid":[NSData data]},nil));
    CHECK(wait_signal(h.results));dispatch_sync(h.deliveries,^{});
    CHECK([h.observed[0][@"error"] integerValue]==FFSTFrameInvalidBackendEvidence);
    CHECK(h.observed[0][@"evidence"]==[NSNull null]);[q close];
    CHECK([[FFSTNativeFrameQueue alloc]initWithMaxRetainedBytes:FFST_FRAME_QUEUE_HARD_BYTES+1 callbackQueue:h.deliveries executor:asynchronous(h) observer:observer(h)]==nil);
    Harness *throwing=[Harness new];
    FFSTFrameExecutor throws=^(id<FFSTQueuedFrame> request,FFSTFrameCancellation cancelled,FFSTFrameExecutorCompletion callback){
        (void)request;[throwing.lock lock];[throwing.callbacks addObject:[callback copy]];[throwing.predicates addObject:[cancelled copy]];
        [throwing.lock unlock];dispatch_semaphore_signal(throwing.begins);
        @throw [NSException exceptionWithName:@"fixture" reason:@"completion retained for explicit retirement" userInfo:nil];
    };
    FFSTNativeFrameQueue *exceptionQueue=[[FFSTNativeFrameQueue alloc]initWithMaxRetainedBytes:8 callbackQueue:throwing.deliveries executor:throws observer:observer(throwing)];
    __weak TestFrame *held=nil;
    @autoreleasepool {TestFrame *r=frame(1,1,4);held=r;CHECK([exceptionQueue submit:r]==FFSTFrameAccepted);}
    CHECK(wait_signal(throwing.begins));CHECK(stats_reach(exceptionQueue,@"executor_exceptions",1));
    @autoreleasepool {CHECK(held!=nil&&[exceptionQueue.stats[@"retained_bytes"] unsignedLongLongValue]==4);}
    [exceptionQueue close];@autoreleasepool {CHECK(held!=nil);}FFSTFrameExecutorCompletion recovered=throwing.callbacks[0];CHECK(recovered(facts(),nil));
    CHECK(wait_signal(throwing.results));dispatch_sync(throwing.deliveries,^{});
    CHECK(held==nil);
    CHECK([throwing.observed[0][@"error"] integerValue]==FFSTFrameExecutorException);
    return 0;
}
int main(void){@autoreleasepool{
    if(cancellation_and_ownership()||callback_bounds_and_streams()||evidence_and_exception())return 1;
    printf("{\"frame_queue_checks\":%u,\"gpu_calls\":0,\"status\":\"passed\"}\n",checks);return 0;
}}
