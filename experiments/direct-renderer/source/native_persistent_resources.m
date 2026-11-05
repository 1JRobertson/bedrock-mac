#import "native_persistent_resources.h"

@interface FFPRBudget : NSObject
@property(nonatomic) NSUInteger limit;
@property(nonatomic) NSUInteger used;
- (BOOL)reserve:(NSUInteger)bytes;
- (void)releaseBytes:(NSUInteger)bytes;
@end
@implementation FFPRBudget
- (BOOL)reserve:(NSUInteger)bytes { @synchronized(self) {
    if (bytes > _limit - _used) return NO; _used += bytes; return YES;
} }
- (void)releaseBytes:(NSUInteger)bytes { @synchronized(self) { _used -= bytes; } }
@end

@interface FFPRRecord : NSObject
@property(nonatomic) uint64_t generation;
@property(nonatomic, strong) id<MTLBuffer> buffer;
@property(nonatomic, strong) FFPRBudget *budget;
@property(nonatomic) NSUInteger chargedBytes;
@end
@implementation FFPRRecord
- (void)dealloc { if (_budget) [_budget releaseBytes:_chargedBytes]; }
@end

@interface FFPRBatch ()
@property(nonatomic, strong) id<MTLCommandBuffer> command;
@property(nonatomic, strong) NSMutableArray *owned;
@property(nonatomic) BOOL finished;
- (BOOL)hold:(id)object;
@end
@implementation FFPRBatch
- (instancetype)initWithCommandBuffer:(id<MTLCommandBuffer>)command {
    if (!command || command.status != MTLCommandBufferStatusNotEnqueued) return nil;
    if ((self = [super init])) { _command = command; _owned = [NSMutableArray array]; }
    return self;
}
- (BOOL)hold:(id)object {
    if (_finished || !object || _command.status != MTLCommandBufferStatusNotEnqueued) return NO;
    [_owned addObject:object]; return YES;
}
- (BOOL)finish {
    if (_finished || _command.status != MTLCommandBufferStatusNotEnqueued) return NO;
    _finished = YES;
    /* The completion handler explicitly drops the objects on actual completion,
       even if Metal keeps the handler block after invoking it. */
    NSMutableArray *owned = [_owned mutableCopy];
    [_command addCompletedHandler:^(id<MTLCommandBuffer> completed) { (void)completed; [owned removeAllObjects]; }];
    [_owned removeAllObjects];
    return YES;
}
@end

@implementation FFPRRegistry {
    id<MTLDevice> _device;
    FFPRBudget *_budget;
    NSMutableDictionary<NSNumber *, FFPRRecord *> *_records;
    NSMutableDictionary<NSNumber *, NSNumber *> *_lastGenerations;
}
- (instancetype)initWithDevice:(id<MTLDevice>)device {
    return [self initWithDevice:device budget:512u * 1024u * 1024u];
}
- (instancetype)initWithDevice:(id<MTLDevice>)device budget:(NSUInteger)budget {
    if (!device || !budget) return nil;
    if ((self = [super init])) { _device = device; _budget = [FFPRBudget new]; _budget.limit = budget; _records = [NSMutableDictionary dictionary]; _lastGenerations = [NSMutableDictionary dictionary]; }
    return self;
}
- (FFPRRecord *)record:(FFPRHandle)handle {
    if (!handle.object || !handle.generation) return nil;
    FFPRRecord *record = _records[@(handle.object)];
    return record.generation == handle.generation ? record : nil;
}
- (BOOL)createBuffer:(FFPRHandle)handle length:(NSUInteger)length {
    if (!handle.object || !handle.generation || !length || _records[@(handle.object)] ||
        handle.generation <= [_lastGenerations[@(handle.object)] unsignedLongLongValue]) return NO;
    if (![_budget reserve:length]) return NO;
    id<MTLBuffer> buffer = [_device newBufferWithLength:length options:MTLResourceStorageModePrivate];
    if (!buffer) { [_budget releaseBytes:length]; return NO; }
    FFPRRecord *record = [FFPRRecord new]; record.generation = handle.generation; record.buffer = buffer;
    record.budget = _budget; record.chargedBytes = length;
    _records[@(handle.object)] = record; _lastGenerations[@(handle.object)] = @(handle.generation);
    return YES;
}
- (id<MTLBuffer>)buffer:(FFPRHandle)handle batch:(FFPRBatch *)batch {
    FFPRRecord *record = [self record:handle];
    if (!record || !batch || batch.command.device != _device || ![batch hold:record]) return nil;
    return record.buffer;
}
- (BOOL)writeBuffer:(FFPRHandle)handle offset:(NSUInteger)offset bytes:(const void *)bytes length:(NSUInteger)length batch:(FFPRBatch *)batch {
    FFPRRecord *record = [self record:handle];
    if (!record || !batch || batch.finished || batch.command.device != _device || !bytes || !length ||
        offset > record.buffer.length || length > record.buffer.length - offset ||
        batch.command.status != MTLCommandBufferStatusNotEnqueued) return NO;
    if (![_budget reserve:length]) return NO;
    id<MTLBuffer> staging = [_device newBufferWithBytes:bytes length:length options:MTLResourceStorageModeShared];
    if (!staging) { [_budget releaseBytes:length]; return NO; }
    FFPRRecord *upload = [FFPRRecord new]; upload.buffer = staging; upload.budget = _budget; upload.chargedBytes = length;
    id<MTLBlitCommandEncoder> encoder = [batch.command blitCommandEncoder];
    if (!encoder) return NO;
    [encoder copyFromBuffer:staging sourceOffset:0 toBuffer:record.buffer destinationOffset:offset size:length];
    [encoder endEncoding];
    [batch hold:upload]; [batch hold:record]; return YES;
}
- (BOOL)copyBuffer:(FFPRHandle)source sourceOffset:(NSUInteger)sourceOffset destination:(FFPRHandle)destination destinationOffset:(NSUInteger)destinationOffset length:(NSUInteger)length batch:(FFPRBatch *)batch {
    FFPRRecord *src = [self record:source], *dst = [self record:destination];
    if (!src || !dst || !batch || batch.finished || batch.command.device != _device || !length ||
        sourceOffset > src.buffer.length || length > src.buffer.length-sourceOffset ||
        destinationOffset > dst.buffer.length || length > dst.buffer.length-destinationOffset ||
        batch.command.status != MTLCommandBufferStatusNotEnqueued) return NO;
    /* Metal does not define overlapping copies within one buffer. */
    if (src.buffer == dst.buffer && sourceOffset < destinationOffset+length && destinationOffset < sourceOffset+length) return NO;
    id<MTLBlitCommandEncoder> encoder = [batch.command blitCommandEncoder];
    if (!encoder) return NO;
    [encoder copyFromBuffer:src.buffer sourceOffset:sourceOffset toBuffer:dst.buffer destinationOffset:destinationOffset size:length];
    [encoder endEncoding];
    [batch hold:src]; [batch hold:dst]; return YES;
}
- (BOOL)destroyBuffer:(FFPRHandle)handle {
    if (![self record:handle]) return NO;
    [_records removeObjectForKey:@(handle.object)]; return YES;
}
@end
