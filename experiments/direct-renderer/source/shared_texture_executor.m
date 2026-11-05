#import "shared_texture_executor.h"
#include <errno.h>
#include <math.h>
#include <stdlib.h>

#if !__has_feature(objc_arc)
#error shared_texture_executor.m requires ARC
#endif
@interface FFSTExecutorSession ()
@property(nonatomic,strong) NSLock *lock;
@property(nonatomic,strong) NSString *service,*token;
@property(nonatomic) FFSTConsumer consumer;
@property(nonatomic) uint64_t registry;
@property(nonatomic) uint32_t handles;
@property(nonatomic) BOOL closing;
@property(nonatomic,strong) NSMutableSet<NSValue *> *timedOut;
@property(nonatomic) BOOL timeoutReady;
- (FFSTConsumer)borrow:(id<MTLDevice>)device failure:(NSString **)failure;
- (void)returnConsumer:(FFSTConsumer)consumer state:(id)state healthy:(BOOL)healthy;
- (void)pendingTimeout:(id)state;
- (FFSTConsumer)detachClosedConsumer;
@end
@interface FFSTExecutorState : NSObject
@property(nonatomic) FFSTConsumer consumer;
@property(nonatomic,strong) FFSTExecutorSession *session;
@property(nonatomic) FFSTLease lease;
@property(nonatomic, strong) NSArray<id<MTLTexture>> *textures;
@property(nonatomic, strong) NSArray<NSValue *> *refs;
@property(nonatomic, strong) NSArray<NSValue *> *infos;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) dispatch_semaphore_t done;
@property(nonatomic) FFSTResult result;
@property(nonatomic) BOOL finishing, finished, released;
@end
@implementation FFSTExecutorState
@end
static void close_consumer(FFSTExecutorState *s) {
    [s.lock lock]; FFSTConsumer client = s.consumer; s.consumer = NULL;
    FFSTExecutorSession *session=s.session;s.session=nil;BOOL healthy=s.finished&&s.result==FFST_OK;[s.lock unlock];
    if(client&&session)[session returnConsumer:client state:s healthy:healthy];
    else if(client)ffst_consumer_destroy(client);
}
static void finish_state(FFSTExecutorState *s, FFSTResult result) {
    [s.lock lock]; BOOL first = !s.finished; s.finished = YES; s.result = result; BOOL close = s.released; [s.lock unlock];
    if (first) dispatch_semaphore_signal(s.done);
    if (close) close_consumer(s);
}
static void abandon_state(FFSTExecutorState *s, FFSTLease lease) {
    if (!lease) { close_consumer(s); return; }
    ffst_consumer_abandon(lease, ^(uint64_t cut, FFSTResult result) {
        (void)cut; finish_state(s, result); close_consumer(s);
    });
}
@implementation FFSTExecutorSession
- (instancetype)init {self=[super init];if(self){_lock=[NSLock new];_timedOut=[NSMutableSet set];}return self;}
- (FFSTConsumer)detachClosedConsumer {
    /* Called under lock. Timed-out acquire requests have never been submitted
     * to a GPU; force their disconnect only after every other handle retires. */
    BOOL onlyPending=_timeoutReady&&_timedOut.count&&_handles==_timedOut.count;
    FFSTConsumer client=(_closing&&(!_handles||onlyPending))?_consumer:NULL;
    if(client)_consumer=NULL;return client;
}
- (void)close {
    [_lock lock];_closing=YES;FFSTConsumer client=[self detachClosedConsumer];[_lock unlock];
    if(client)ffst_consumer_destroy(client);
}
- (void)dealloc {[self close];}
- (void)returnConsumer:(FFSTConsumer)client state:(id)state healthy:(BOOL)healthy {
    [_lock lock];[_timedOut removeObject:[NSValue valueWithNonretainedObject:state]];
    if((client!=_consumer&&_consumer)||!_handles)_closing=YES;if(_handles)--_handles;
    if(!healthy)_closing=YES;FFSTConsumer release=[self detachClosedConsumer];[_lock unlock];
    if(release)ffst_consumer_destroy(release);
}
- (void)pendingTimeout:(id)state {
    [_lock lock];_closing=YES;[_timedOut addObject:[NSValue valueWithNonretainedObject:state]];[_lock unlock];
    /* Give a late reply time to abandon through the normal retirement ACK.
     * A hung broker cannot keep an otherwise drained session alive forever. */
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_global_queue(QOS_CLASS_DEFAULT,0),^{
        [self.lock lock];self.timeoutReady=YES;FFSTConsumer client=[self detachClosedConsumer];[self.lock unlock];
        if(client)ffst_consumer_destroy(client);
    });
}
- (FFSTConsumer)borrow:(id<MTLDevice>)device failure:(NSString **)failure {
    const char *service = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_SERVICE"), *token = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_TOKEN");
    const char *registry = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_DEVICE"); char *end = NULL; errno = 0;
    uint64_t registry_id = registry ? strtoull(registry, &end, 10) : 0;
    if (!service || !token || !registry || !end || *end || errno || !registry_id || registry_id != device.registryID){
        if(failure)*failure=@"Attachment session configuration/device mismatch";[self close];return NULL;}
    NSString *serviceName=@(service),*secret=@(token);
    [_lock lock];
    if(_closing||_handles>=FFST_MAX_OUTSTANDING_LEASES){[_lock unlock];if(failure)*failure=@"Attachment session closed or lease limit reached";return NULL;}
    if(_consumer&&(_registry!=registry_id||![_service isEqual:serviceName]||![_token isEqual:secret])){
        [_lock unlock];if(failure)*failure=@"Attachment session identity changed";[self close];return NULL;}
    if(!_consumer){_consumer=ffst_consumer_create(serviceName,secret,device,0);_service=serviceName;_token=secret;_registry=registry_id;}
    FFSTConsumer client=_consumer;if(client)++_handles;else _closing=YES;[_lock unlock];
    if(!client&&failure)*failure=@"Attachment consumer creation failed";return client;
}
- (FFSTExecutorAttachments)acquire:(uint64_t)cut_id device:(id<MTLDevice>)device timeout:(double)timeout failure:(NSString **)failure {
    if(failure)*failure=nil;
    if (!device || !cut_id || !isfinite(timeout) || timeout < 1 || timeout > 30){if(failure)*failure=@"Invalid attachment acquire arguments";return NULL;}
    FFSTConsumer consumer=[self borrow:device failure:failure];if(!consumer)return NULL;
    FFSTExecutorState *s = [FFSTExecutorState new]; s.consumer = consumer;s.session=self;s.lock = [NSLock new];
    s.done = dispatch_semaphore_create(0); s.result = FFST_EMPTY;
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while ([deadline timeIntervalSinceNow] > 0) {
        dispatch_semaphore_t reply = dispatch_semaphore_create(0);
        __block FFSTResult result = FFST_EMPTY;
        __block BOOL replyCompleted=NO;
        ffst_consumer_acquire(consumer, ^(FFSTLease lease, FFSTResult value) {
            [s.lock lock];replyCompleted=YES;BOOL cancelled = s.released;
            if (!cancelled) { s.lease = lease; result = value; }
            [s.lock unlock];
            if (cancelled) abandon_state(s, lease);
            dispatch_semaphore_signal(reply);
        });
        double left = [deadline timeIntervalSinceNow];
        if (left <= 0 || dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(left * NSEC_PER_SEC)))) {
            [s.lock lock];s.released=YES;FFSTLease late=s.lease;s.lease=NULL;
            BOOL pending=!replyCompleted;if(!late&&pending)[self pendingTimeout:s];[s.lock unlock];
            [self close];
            if(late)abandon_state(s,late);else if(!pending)close_consumer(s);
            if(failure)*failure=[NSString stringWithFormat:@"Attachment acquire timeout cut=%llu",(unsigned long long)cut_id];
            return NULL;
        }
        if (result == FFST_EMPTY) { [NSThread sleepForTimeInterval:0.05]; continue; }
        if (result != FFST_OK || !s.lease) {if(failure)*failure=[NSString stringWithFormat:@"Attachment acquire failed cut=%llu result=%u",(unsigned long long)cut_id,(unsigned)result];close_consumer(s);return NULL;}
        if (ffst_lease_cut_id(s.lease) != cut_id) {FFSTLease lease=s.lease;s.lease=NULL;
            if(failure)*failure=[NSString stringWithFormat:@"Attachment cut mismatch requested=%llu actual=%llu",(unsigned long long)cut_id,(unsigned long long)ffst_lease_cut_id(lease)];
            abandon_state(s,lease);return NULL;}
        NSMutableArray *textures = [NSMutableArray array], *refs = [NSMutableArray array], *infos = [NSMutableArray array];
        for (size_t i = 0; i < ffst_lease_texture_count(s.lease); ++i) {
            id<MTLTexture> texture = ffst_lease_texture(s.lease, i);
            if (!texture || texture.device.registryID != device.registryID) {if(failure)*failure=@"Attachment texture device mismatch";FFSTLease lease=s.lease;s.lease=NULL;abandon_state(s,lease);return NULL;}
            FFSTTextureInfo info;
            if (!ffst_lease_texture_info(s.lease, i, &info)) {if(failure)*failure=@"Attachment texture metadata unavailable";FFSTLease lease=s.lease;s.lease=NULL;abandon_state(s,lease);return NULL;}
            [infos addObject:[NSValue valueWithBytes:&info objCType:@encode(FFSTTextureInfo)]];
            [textures addObject:texture];
        }
        for (size_t i = 0; i < ffst_lease_attachment_count(s.lease); ++i) {
            FFSTAttachmentRef ref;
            if (!ffst_lease_attachment(s.lease, i, &ref) || ref.texture_index >= textures.count) {if(failure)*failure=@"Attachment role metadata unavailable";FFSTLease lease=s.lease;s.lease=NULL;abandon_state(s,lease);return NULL;}
            [refs addObject:[NSValue valueWithBytes:&ref objCType:@encode(FFSTAttachmentRef)]];
        }
        s.textures = textures; s.refs = refs; s.infos = infos; return (__bridge_retained void *)s;
    }
    if(failure)*failure=[NSString stringWithFormat:@"Attachment acquire empty until timeout cut=%llu",(unsigned long long)cut_id];
    close_consumer(s); return NULL;
}
@end
FFSTExecutorAttachments ffst_executor_acquire(id<MTLDevice> device,uint64_t cut_id,double timeout) {
    FFSTExecutorSession *session=[FFSTExecutorSession new];FFSTExecutorAttachments result=[session acquire:cut_id device:device timeout:timeout failure:nil];
    [session close];return result;
}
id<MTLTexture> ffst_executor_texture(FFSTExecutorAttachments attachments, FFSTAttachmentRole role, uint32_t index) {
    if (!attachments) return nil; FFSTExecutorState *s = (__bridge FFSTExecutorState *)attachments;
    for (NSValue *value in s.refs) { FFSTAttachmentRef ref; [value getValue:&ref size:sizeof(ref)];
        if (ref.role == role && ref.attachment_index == index) return s.textures[ref.texture_index]; }
    return nil;
}
int ffst_executor_texture_info(FFSTExecutorAttachments attachments, FFSTAttachmentRole role, uint32_t index, FFSTTextureInfo *info) {
    if (!attachments || !info) return 0; FFSTExecutorState *s = (__bridge FFSTExecutorState *)attachments;
    for (NSValue *value in s.refs) { FFSTAttachmentRef ref; [value getValue:&ref size:sizeof(ref)];
        if (ref.role == role && ref.attachment_index == index && ref.texture_index < s.infos.count) {
            [s.infos[ref.texture_index] getValue:info size:sizeof(*info)]; return 1;
        }
    }
    return 0;
}
size_t ffst_executor_attachment_count(FFSTExecutorAttachments attachments) {
    return attachments ? ((__bridge FFSTExecutorState *)attachments).refs.count : 0;
}
int ffst_executor_finish(FFSTExecutorAttachments attachments, id<MTLCommandBuffer> command) {
    if (!attachments || !command) return 0; FFSTExecutorState *s = (__bridge FFSTExecutorState *)attachments;
    [s.lock lock];
    if (s.released || s.finishing || !s.lease) { [s.lock unlock]; return 0; }
    FFSTLease lease = s.lease; s.finishing = YES; [s.lock unlock];
    int accepted = ffst_consumer_finish(lease, command, ^(uint64_t cut, FFSTResult result) { (void)cut; finish_state(s, result); });
    [s.lock lock]; if (accepted) s.lease = NULL; else s.finishing = NO; [s.lock unlock]; return accepted;
}
FFSTResult ffst_executor_wait(FFSTExecutorAttachments attachments, double timeout) {
    if (!attachments || !isfinite(timeout) || timeout <= 0 || timeout > 30) return FFST_REJECTED;
    FFSTExecutorState *s = (__bridge FFSTExecutorState *)attachments;
    [s.lock lock]; BOOL finishing = s.finishing, finished = s.finished; FFSTResult result = s.result; [s.lock unlock];
    if (!finishing) return FFST_REJECTED;
    if (!finished && dispatch_semaphore_wait(s.done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)))) return FFST_EXPIRED;
    [s.lock lock]; result = s.result; [s.lock unlock]; return result;
}
void ffst_executor_release(FFSTExecutorAttachments attachments) {
    if (!attachments) return; FFSTExecutorState *s = (__bridge_transfer FFSTExecutorState *)attachments;
    [s.lock lock]; s.released = YES; FFSTLease lease = s.lease; s.lease = NULL;
    BOOL done = s.finished, finishing = s.finishing; [s.lock unlock];
    if (lease) abandon_state(s, lease); else if (done || !finishing) close_consumer(s);
}
