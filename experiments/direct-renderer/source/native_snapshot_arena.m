#import "native_snapshot_arena.h"
#include <fcntl.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error native_snapshot_arena.m requires ARC
#endif

static NSString *arena_error(NSString **failure,NSString *action,ffsa_result result) {
    NSString *reason=[NSString stringWithFormat:@"Shared snapshot %@ failed (%s)",action,ffsa_result_name(result)];
    if(failure)*failure=reason;return reason;
}
@interface FFSTNativeSnapshotLease (ArenaPrivate)
- (instancetype)initWithArena:(FFSTNativeSnapshotArena *)arena identity:(ffsa_lease)identity;
@end

@interface FFSTNativeSnapshotArena () {
@public
    ffsa_endpoint *_endpoint;
}
@end
@implementation FFSTNativeSnapshotArena
- (instancetype)initWithPath:(const char *)path {
    if(!path||path[0]!='/')return nil;
    int fd=open(path,O_RDWR|O_NOFOLLOW|O_CLOEXEC);if(fd<0)return nil;
    ffsa_endpoint *endpoint=NULL;ffsa_result result=ffsa_attach(fd,FFSA_NATIVE,&endpoint);close(fd);
    if(result!=FFSA_OK)return nil;
    self=[super init];if(!self){ffsa_stop(endpoint);ffsa_detach(endpoint);return nil;}
    _endpoint=endpoint;return self;
}
- (FFSTNativeSnapshotLease *)acquire:(ffsa_lease)identity failure:(NSString **)failure {
    uint64_t used=0;ffsa_result result=ffsa_acquire(_endpoint,identity,&used);
    if(result!=FFSA_OK){arena_error(failure,@"lease acquisition",result);return nil;}
    FFSTNativeSnapshotLease *lease=[[FFSTNativeSnapshotLease alloc] initWithArena:self identity:identity];
    if(!lease){(void)ffsa_native_abandon(_endpoint,identity);arena_error(failure,@"lease ownership",FFSA_INVALID);}
    (void)used;return lease;
}
- (void)dealloc {if(_endpoint){ffsa_stop(_endpoint);(void)ffsa_detach(_endpoint);_endpoint=NULL;}}
@end

typedef NS_ENUM(uint8_t, FFSTSnapshotLeaseState) {
    FFSTSnapshotAcquired,FFSTSnapshotSubmitted,FFSTSnapshotRetirePending,
    FFSTSnapshotAbandonPending,FFSTSnapshotDone
};
@interface FFSTNativeSnapshotLease () {
    FFSTNativeSnapshotArena *_arena;
    ffsa_lease _identity;
    NSLock *_lock;
    FFSTSnapshotLeaseState _state;
}
- (instancetype)initWithArena:(FFSTNativeSnapshotArena *)arena identity:(ffsa_lease)identity;
- (void)unpin;
- (void)finishLocked;
@end

@interface FFSTSharedSnapshotBytes : NSData <FFSTSharedSnapshotMemory> {
    FFSTNativeSnapshotLease *_lease;
    const void *_bytes;
    NSUInteger _length,_allocatedLength;
}
- (instancetype)initWithLease:(FFSTNativeSnapshotLease *)lease bytes:(const void *)bytes
    length:(NSUInteger)length allocatedLength:(NSUInteger)allocatedLength;
@end
@implementation FFSTSharedSnapshotBytes
- (instancetype)initWithLease:(FFSTNativeSnapshotLease *)lease bytes:(const void *)bytes
    length:(NSUInteger)length allocatedLength:(NSUInteger)allocatedLength {
    if(!lease||!bytes||!length||allocatedLength<length)return nil;
    self=[super init];if(self){_lease=lease;_bytes=bytes;_length=length;_allocatedLength=allocatedLength;}return self;
}
- (const void *)bytes {return _bytes;}
- (NSUInteger)length {return _length;}
- (NSUInteger)allocatedLength {return _allocatedLength;}
- (id)copyWithZone:(NSZone *)zone {(void)zone;return self;}
- (void)dealloc {[_lease unpin];}
@end

@implementation FFSTNativeSnapshotLease
- (instancetype)initWithArena:(FFSTNativeSnapshotArena *)arena identity:(ffsa_lease)identity {
    self=[super init];if(self){_arena=arena;_identity=identity;_lock=[NSLock new];_state=FFSTSnapshotAcquired;}return self;
}
- (void)finishLocked {
    ffsa_result result=FFSA_BACKPRESSURE;
    if(_state==FFSTSnapshotRetirePending)result=ffsa_release(_arena->_endpoint,_identity);
    else if(_state==FFSTSnapshotAbandonPending)result=ffsa_native_abandon(_arena->_endpoint,_identity);
    if(result==FFSA_OK)_state=FFSTSnapshotDone;
    else if(result!=FFSA_BACKPRESSURE)ffsa_stop(_arena->_endpoint);
}
- (NSData<FFSTSharedSnapshotMemory> *)snapshotAtOffset:(uint64_t)offset length:(uint64_t)length
    failure:(NSString **)failure {
    [_lock lock];
    if(_state!=FFSTSnapshotAcquired||!length||length>UINT64_MAX-FFSA_ALIGNMENT+1){[_lock unlock];
        arena_error(failure,@"extent bounds",FFSA_INVALID);return nil;}
    uint64_t rounded=(length+FFSA_ALIGNMENT-1)&~((uint64_t)FFSA_ALIGNMENT-1);
    ffsa_extent_desc descriptor={.lease=_identity,.offset=offset,.length=length,.allocated_length=rounded};
    void *bytes=NULL;ffsa_result result=ffsa_pin_extent(_arena->_endpoint,descriptor,&bytes);
    FFSTSharedSnapshotBytes *view=result==FFSA_OK?[[FFSTSharedSnapshotBytes alloc] initWithLease:self bytes:bytes
        length:(NSUInteger)length allocatedLength:(NSUInteger)rounded]:nil;
    if(result==FFSA_OK&&!view){(void)ffsa_unpin_extent(_arena->_endpoint,_identity);result=FFSA_INVALID;}
    [_lock unlock];if(result!=FFSA_OK){arena_error(failure,@"extent pin",result);return nil;}return view;
}
- (BOOL)submitted:(NSString **)failure {
    [_lock lock];ffsa_result result=_state==FFSTSnapshotAcquired?
        ffsa_native_submitted(_arena->_endpoint,_identity):FFSA_ORDER;
    if(result==FFSA_OK)_state=FFSTSnapshotSubmitted;[_lock unlock];
    if(result!=FFSA_OK){arena_error(failure,@"submission",result);return NO;}return YES;
}
- (BOOL)gpuCompleted:(NSString **)failure {
    [_lock lock];ffsa_result result=_state==FFSTSnapshotSubmitted?
        ffsa_native_gpu_complete(_arena->_endpoint,_identity):FFSA_ORDER;
    if(result==FFSA_OK){_state=FFSTSnapshotRetirePending;[self finishLocked];}
    [_lock unlock];if(result!=FFSA_OK){arena_error(failure,@"GPU retirement",result);return NO;}return YES;
}
- (void)abandon {
    [_lock lock];if(_state==FFSTSnapshotAcquired){_state=FFSTSnapshotAbandonPending;[self finishLocked];}[_lock unlock];
}
- (void)unpin {
    [_lock lock];ffsa_result result=ffsa_unpin_extent(_arena->_endpoint,_identity);
    if(result!=FFSA_OK)ffsa_stop(_arena->_endpoint);
    else [self finishLocked];[_lock unlock];
}
- (void)dealloc {
    if(_state==FFSTSnapshotAcquired)[self abandon];
    else if(_state==FFSTSnapshotSubmitted)ffsa_stop(_arena->_endpoint);
}
@end
