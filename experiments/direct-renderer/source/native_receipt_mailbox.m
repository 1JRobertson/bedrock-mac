#import "native_receipt_mailbox.h"
#include <math.h>
#include <time.h>

#if !__has_feature(objc_arc)
#error native_receipt_mailbox.m requires ARC
#endif

enum { FFST_MAILBOX_ORDINARY = 4 * FFSC_RECEIPT_CAPACITY,
    FFST_MAILBOX_PRIORITY = 7, FFST_MAILBOX_TOTAL = FFST_MAILBOX_ORDINARY + FFST_MAILBOX_PRIORITY };

static double mailbox_now(void) {
    struct timespec value;clock_gettime(CLOCK_MONOTONIC,&value);
    return (double)value.tv_sec+(double)value.tv_nsec/1e9;
}

@implementation FFSTNativeReceiptMailbox {
    NSCondition *_condition;
    NSMutableArray<NSData *> *_queue;
    NSUInteger _head,_maximumCount;
    BOOL _stopped;
}
- (instancetype)init {
    self=[super init];if(self){_condition=[NSCondition new];_queue=[NSMutableArray new];}
    return self;
}
- (NSUInteger)queued {return _queue.count-_head;}
- (BOOL)valid:(NSArray<NSData *> *)batch {
    if(![batch isKindOfClass:[NSArray class]]||!batch.count||batch.count>FFSC_RECEIPT_CAPACITY)return NO;
    for(id item in batch)if(![item isKindOfClass:[NSData class]]||[item length]!=sizeof(ffsc_receipt))return NO;
    return YES;
}
- (BOOL)enqueueBatch:(NSArray<NSData *> *)batch timeoutSeconds:(double)timeout {
    if(![self valid:batch]||!isfinite(timeout)||timeout<=0||timeout>30)return NO;
    double deadline=mailbox_now()+timeout;
    [_condition lock];
    while(!_stopped&&([self queued]>FFST_MAILBOX_ORDINARY||
        batch.count>FFST_MAILBOX_ORDINARY-[self queued])){
        double remaining=deadline-mailbox_now();if(remaining<=0){[_condition unlock];return NO;}
        [_condition waitUntilDate:[NSDate dateWithTimeIntervalSinceNow:MIN(remaining,0.05)]];
    }
    if(_stopped){[_condition unlock];return NO;}
    [_queue addObjectsFromArray:batch];_maximumCount=MAX(_maximumCount,[self queued]);
    [_condition unlock];return YES;
}
- (BOOL)enqueuePriority:(NSData *)receipt {
    if(![receipt isKindOfClass:[NSData class]]||receipt.length!=sizeof(ffsc_receipt))return NO;
    [_condition lock];BOOL admitted=[self queued]<FFST_MAILBOX_TOTAL;
    if(admitted){[_queue addObject:receipt];_maximumCount=MAX(_maximumCount,[self queued]);}
    [_condition unlock];return admitted;
}
- (NSData *)first {
    [_condition lock];NSData *value=[self queued]?_queue[_head]:nil;[_condition unlock];return value;
}
- (BOOL)removeFirst:(NSData *)receipt {
    [_condition lock];BOOL matched=[self queued]&&_queue[_head]==receipt;
    if(matched){++_head;
        if(_head==_queue.count){[_queue removeAllObjects];_head=0;}
        else if(_head>=512&&_head*2>=_queue.count){[_queue removeObjectsInRange:NSMakeRange(0,_head)];_head=0;}
        [_condition broadcast];}
    [_condition unlock];return matched;
}
- (NSUInteger)count {[_condition lock];NSUInteger value=[self queued];[_condition unlock];return value;}
- (NSUInteger)maximumCount {[_condition lock];NSUInteger value=_maximumCount;[_condition unlock];return value;}
- (NSArray<NSData *> *)snapshot {[_condition lock];NSArray *value=[[_queue subarrayWithRange:NSMakeRange(_head,[self queued])] copy];[_condition unlock];return value;}
- (void)stop {[_condition lock];_stopped=YES;[_condition broadcast];[_condition unlock];}
- (void)discardAll {[_condition lock];[_queue removeAllObjects];_head=0;[_condition broadcast];[_condition unlock];}
@end
