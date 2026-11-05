#import "native_frame_queue.h"
#include <math.h>

#if !__has_feature(objc_arc)
#error native_frame_queue.m requires ARC
#endif
NSString *const FFSTFrameQueueErrorDomain = @"BedrockNativeFrameQueue";

typedef NS_ENUM(unsigned, FFSTFrameState) { FFSTPending, FFSTActive, FFSTFinished };
@interface FFSTFrameItem : NSObject
@property(nonatomic, strong) id<FFSTQueuedFrame> request;
@property(nonatomic) uint64_t stream;
@property(nonatomic) uint64_t frame;
@property(nonatomic) uint64_t bytes;
@property(nonatomic) FFSTFrameState state;
@property(atomic) BOOL cancelled;
@property(nonatomic) BOOL reported;
@property(nonatomic) BOOL evidenceReady;
@property(nonatomic) BOOL executorReturned;
@property(nonatomic) BOOL delivering;
@property(nonatomic, strong) NSDictionary *evidence;
@property(nonatomic, strong) NSError *error;
@property(nonatomic, strong) NSError *executorFault;
@property(nonatomic, strong) NSString *source;
@end
@implementation FFSTFrameItem @end

static void increment(uint64_t *value) { if (*value != UINT64_MAX) ++*value; }
static NSError *queue_error(FFSTFrameQueueError code, NSString *message) {
    return [NSError errorWithDomain:FFSTFrameQueueErrorDomain code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
static BOOL bounded_string(id value, NSUInteger maximum) {
    return [value isKindOfClass:[NSString class]] && [value length] <= maximum &&
        [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= maximum;
}
static BOOL json_value(id value, unsigned depth, unsigned *nodes) {
    if (++*nodes > 256 || depth > 4) return NO;
    if (value == [NSNull null]) return YES;
    if ([value isKindOfClass:[NSString class]]) return bounded_string(value,4096);
    if ([value isKindOfClass:[NSNumber class]]) return isfinite([value doubleValue]);
    if ([value isKindOfClass:[NSArray class]]) {
        if ([value count] > 64) return NO;
        for (id child in value) if (!json_value(child,depth+1,nodes)) return NO;
        return YES;
    }
    if ([value isKindOfClass:[NSDictionary class]]) {
        if ([value count] > 64) return NO;
        for (id key in value) if (!bounded_string(key,128) || !json_value(value[key],depth+1,nodes)) return NO;
        return YES;
    }
    return NO;
}
static NSDictionary *copy_evidence(id evidence) {
    if (![evidence isKindOfClass:[NSDictionary class]]) return nil;
    unsigned nodes=0; if (!json_value(evidence,0,&nodes)) return nil;
    NSData *data=[NSJSONSerialization dataWithJSONObject:evidence options:0 error:nil];
    if (!data || data.length>FFST_FRAME_QUEUE_EVIDENCE_BYTES) return nil;
    return [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
}
static NSError *copy_error(NSError *error) {
    if (!error) return nil;
    if (![error isKindOfClass:[NSError class]] || !bounded_string(error.domain,128) ||
        !bounded_string(error.localizedDescription,1024))
        return queue_error(FFSTFrameInvalidBackendEvidence,@"Backend error exceeds bounded result contract");
    return [NSError errorWithDomain:error.domain code:error.code
        userInfo:@{NSLocalizedDescriptionKey:error.localizedDescription}];
}

@interface FFSTNativeFrameQueue () {
    NSLock *_lock;
    dispatch_queue_t _worker, _callbacks;
    FFSTFrameExecutor _executor;
    FFSTFrameObserver _observer;
    NSMutableArray<FFSTFrameItem *> *_slots;
    NSMutableArray<NSDictionary *> *_history;
    FFSTFrameItem *_active;
    FFSTNativeFrameQueue *_lifetime;
    uint64_t _maxBytes, _bytes, _lastStream, _lastFrame;
    BOOL _closed, _deliveryScheduled;
    uint64_t _accepted, _backpressure, _closedRejected, _orderRejected, _invalid;
    uint64_t _retired, _backendErrors, _pendingCancelled, _activeCancelled;
    uint64_t _duplicates, _delivered, _executorExceptions, _observerExceptions;
}
- (void)scheduleDeliveryLocked;
- (void)scheduleWorkerLocked;
- (void)finalizeLocked:(FFSTFrameItem *)item;
- (BOOL)complete:(FFSTFrameItem *)item evidence:(NSDictionary *)evidence error:(NSError *)error;
- (BOOL)cancelLocked:(FFSTFrameItem *)item;
- (void)drainResults;
- (NSDictionary *)record:(FFSTFrameItem *)item;
@end
@implementation FFSTNativeFrameQueue
- (instancetype)initWithMaxRetainedBytes:(uint64_t)maxBytes callbackQueue:(dispatch_queue_t)callbackQueue
    executor:(FFSTFrameExecutor)executor observer:(FFSTFrameObserver)observer {
    if (!callbackQueue || !executor || !observer || maxBytes>FFST_FRAME_QUEUE_HARD_BYTES) return nil;
    self=[super init]; if (!self) return nil;
    _maxBytes=maxBytes ?: FFST_FRAME_QUEUE_DEFAULT_BYTES;
    _lock=[NSLock new]; _slots=[NSMutableArray array]; _history=[NSMutableArray array];
    _worker=dispatch_queue_create("bedrock.native-frame.execute",DISPATCH_QUEUE_SERIAL);
    _callbacks=dispatch_queue_create("bedrock.native-frame.results",DISPATCH_QUEUE_SERIAL);
    dispatch_set_target_queue(_callbacks,callbackQueue);
    _executor=[executor copy]; _observer=[observer copy]; return self;
}
- (void)scheduleDeliveryLocked {
    if (_deliveryScheduled || !_slots.count || _slots[0].state!=FFSTFinished) return;
    _deliveryScheduled=YES;
    dispatch_async(_callbacks,^{ [self drainResults]; });
}
- (void)finalizeLocked:(FFSTFrameItem *)item {
    if (item.state!=FFSTActive || !item.reported || !item.evidenceReady || !item.executorReturned) return;
    item.state=FFSTFinished; _bytes-=item.bytes; item.request=nil; _active=nil;
    increment(&_retired); if (item.error) increment(&_backendErrors);
    [self scheduleWorkerLocked]; [self scheduleDeliveryLocked];
}
- (BOOL)complete:(FFSTFrameItem *)item evidence:(NSDictionary *)evidence error:(NSError *)error {
    [_lock lock];
    if (item.reported || item.state!=FFSTActive) { increment(&_duplicates); [_lock unlock]; return NO; }
    item.reported=YES; [_lock unlock];
    NSDictionary *bounded=nil; NSError *boundedError=nil;
    @try {
        bounded=evidence ? copy_evidence(evidence) : nil; boundedError=copy_error(error);
        if ((evidence && !bounded) || (!evidence && !error))
            boundedError=queue_error(FFSTFrameInvalidBackendEvidence,@"Executor returned invalid or missing bounded evidence");
    } @catch (NSException *exception) {
        (void)exception; bounded=nil;
        boundedError=queue_error(FFSTFrameInvalidBackendEvidence,@"Executor result could not be copied safely");
    }
    [_lock lock];
    item.evidence=bounded; item.error=boundedError ?: item.executorFault;
    item.source=@"executor"; item.evidenceReady=YES;
    [self finalizeLocked:item]; [_lock unlock]; return YES;
}
- (void)scheduleWorkerLocked {
    if (_active) return;
    for (FFSTFrameItem *item in _slots) {
        if (item.state!=FFSTPending) continue;
        item.state=FFSTActive; _active=item;
        dispatch_async(_worker,^{
            /* A synchronous completion cannot free the request while invocation
             * arguments/autoreleased temporaries still borrow it. Finalization
             * waits for this pool and executor invocation to return as well. */
            @autoreleasepool {
                __unsafe_unretained id<FFSTQueuedFrame> request=item.request;
                @try {
                    self->_executor(request, ^BOOL { return item.cancelled; },
                        ^BOOL(NSDictionary *facts,NSError *error) { return [self complete:item evidence:facts error:error]; });
                } @catch (NSException *exception) {
                    (void)exception;
                    [self->_lock lock]; increment(&self->_executorExceptions);
                    item.executorFault=queue_error(FFSTFrameExecutorException,@"Executor threw before confirmed retirement");
                    if (!item.reported && !item.cancelled) { item.cancelled=YES; increment(&self->_activeCancelled); }
                    if (item.evidenceReady && !item.error) item.error=item.executorFault;
                    [self->_lock unlock];
                    /* Throwing is not GPU/lease retirement. Without the saved
                     * completion callback this intentionally stays active. */
                }
            }
            [self->_lock lock]; item.executorReturned=YES;
            [self finalizeLocked:item]; [self->_lock unlock];
        });
        return;
    }
}
- (FFSTFrameSubmitResult)submit:(id<FFSTQueuedFrame>)request {
    uint64_t stream=0,frame=0,bytes=0; BOOL valid=NO;
    @try {
        valid=request && [request conformsToProtocol:@protocol(FFSTQueuedFrame)];
        if (valid) { stream=request.streamID; frame=request.frameID; bytes=request.retainedBytes; valid=stream && frame && bytes<=_maxBytes; }
    } @catch (NSException *exception) { (void)exception; valid=NO; }
    [_lock lock];
    if (_closed) { increment(&_closedRejected); [_lock unlock]; return FFSTFrameClosed; }
    if (!valid) { increment(&_invalid); [_lock unlock]; return FFSTFrameInvalid; }
    BOOL busy=NO; for (FFSTFrameItem *item in _slots) if (item.state!=FFSTFinished) busy=YES;
    if ((_lastStream && stream<_lastStream) || (stream==_lastStream && frame<=_lastFrame) ||
        (_lastStream && stream>_lastStream && busy)) {
        increment(&_orderRejected); [_lock unlock]; return FFSTFrameOrder;
    }
    if (_slots.count>=FFST_FRAME_QUEUE_CAPACITY || bytes>_maxBytes-_bytes) {
        increment(&_backpressure); [_lock unlock]; return FFSTFrameBackpressure;
    }
    FFSTFrameItem *item=[FFSTFrameItem new]; item.request=request; item.stream=stream; item.frame=frame; item.bytes=bytes;
    [_slots addObject:item]; _lifetime=self; _bytes+=bytes; _lastStream=stream; _lastFrame=frame; increment(&_accepted);
    [self scheduleWorkerLocked]; [_lock unlock]; return FFSTFrameAccepted;
}
- (BOOL)cancelLocked:(FFSTFrameItem *)item {
    if (item.state==FFSTFinished || item.reported) return NO;
    if (item.state==FFSTActive) {
        if (!item.cancelled) { item.cancelled=YES; increment(&_activeCancelled); }
    } else {
        item.cancelled=YES; item.state=FFSTFinished; _bytes-=item.bytes; item.request=nil;
        item.source=@"cancelled-before-execution";
        item.error=queue_error(FFSTFrameCancelledBeforeExecution,@"Pending frame cancelled before execution");
        increment(&_pendingCancelled);
    }
    [self scheduleDeliveryLocked]; return YES;
}
- (BOOL)cancelStream:(uint64_t)stream frame:(uint64_t)frame {
    [_lock lock]; BOOL found=NO;
    for (FFSTFrameItem *item in _slots) if (item.stream==stream && item.frame==frame) { found=[self cancelLocked:item]; break; }
    [_lock unlock]; return found;
}
- (void)cancelAll { [_lock lock]; for (FFSTFrameItem *item in _slots) [self cancelLocked:item]; [_lock unlock]; }
- (void)close { [_lock lock]; _closed=YES; for (FFSTFrameItem *item in _slots) [self cancelLocked:item]; [_lock unlock]; }
- (NSDictionary *)record:(FFSTFrameItem *)item {
    NSDictionary *error=item.error ? @{ @"domain":item.error.domain, @"code":@(item.error.code), @"description":item.error.localizedDescription } : nil;
    return @{ @"stream_id":@(item.stream), @"frame_id":@(item.frame), @"cancelled":@(item.cancelled),
        @"source":item.source ?: @"unknown", @"evidence":item.evidence ?: (id)[NSNull null], @"error":error ?: (id)[NSNull null] };
}
- (void)drainResults {
    while (YES) @autoreleasepool {
        [_lock lock];
        FFSTFrameItem *item=_slots.firstObject;
        if (!item || item.state!=FFSTFinished || item.delivering) { _deliveryScheduled=NO; [_lock unlock]; return; }
        item.delivering=YES; [_history addObject:[self record:item]];
        if (_history.count>FFST_FRAME_QUEUE_HISTORY) [_history removeObjectAtIndex:0];
        increment(&_delivered); [_lock unlock];
        @try { _observer(item.stream,item.frame,item.cancelled,item.evidence,item.error); }
        @catch (NSException *exception) { (void)exception; [_lock lock]; increment(&_observerExceptions); [_lock unlock]; }
        [_lock lock]; [_slots removeObjectAtIndex:0];
        if (!_slots.count) _lifetime=nil;
        [self scheduleWorkerLocked]; [_lock unlock];
    }
}
- (NSDictionary *)stats {
    [_lock lock]; unsigned pending=0;
    for (FFSTFrameItem *item in _slots) if (item.state==FFSTPending) ++pending;
    NSDictionary *result=@{ @"accepted":@(_accepted), @"backpressure":@(_backpressure), @"rejected_closed":@(_closedRejected),
        @"rejected_order":@(_orderRejected), @"rejected_invalid":@(_invalid), @"retired":@(_retired), @"backend_errors":@(_backendErrors),
        @"cancelled_pending":@(_pendingCancelled), @"cancelled_active":@(_activeCancelled), @"duplicate_completions":@(_duplicates),
        @"delivered":@(_delivered), @"executor_exceptions":@(_executorExceptions), @"observer_exceptions":@(_observerExceptions),
        @"outstanding":@(_slots.count), @"active":@(_active!=nil), @"pending":@(pending), @"retained_bytes":@(_bytes),
        @"max_retained_bytes":@(_maxBytes), @"last_stream_id":@(_lastStream), @"last_frame_id":@(_lastFrame), @"closed":@(_closed) };
    [_lock unlock]; return result;
}
- (NSArray<NSDictionary *> *)history { [_lock lock]; NSArray *result=[_history copy]; [_lock unlock]; return result; }
@end
