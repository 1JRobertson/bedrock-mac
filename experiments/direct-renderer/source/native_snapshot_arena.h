/* Native ownership of sealed cross-process buffer snapshots. ARC. */
#ifndef BEDROCK_NATIVE_SNAPSHOT_ARENA_H
#define BEDROCK_NATIVE_SNAPSHOT_ARENA_H
#import <Foundation/Foundation.h>
#include "shared_snapshot_arena.h"

@protocol FFSTSharedSnapshotMemory <NSObject>
@property(nonatomic,readonly) NSUInteger allocatedLength;
@end

@class FFSTNativeSnapshotLease;
@interface FFSTNativeSnapshotArena : NSObject
- (instancetype)initWithPath:(const char *)path;
- (FFSTNativeSnapshotLease *)acquire:(ffsa_lease)identity failure:(NSString **)failure;
@end

@interface FFSTNativeSnapshotLease : NSObject
- (NSData<FFSTSharedSnapshotMemory> *)snapshotAtOffset:(uint64_t)offset length:(uint64_t)length
    failure:(NSString **)failure;
/* These are called by the serial native executor, not the decode thread. */
- (BOOL)submitted:(NSString **)failure;
- (BOOL)gpuCompleted:(NSString **)failure;
- (void)abandon;
@end
#endif
