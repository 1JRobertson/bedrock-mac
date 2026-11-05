/* Experimental direct-stream resource registry. Requires ARC and Metal.
 * One serial stream owns a registry; methods are not thread safe. */
#ifndef BEDROCK_NATIVE_PERSISTENT_RESOURCES_H
#define BEDROCK_NATIVE_PERSISTENT_RESOURCES_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>

typedef struct { uint64_t object, generation; } FFPRHandle;

/* A batch owns every resource and staging allocation encoded into its command
 * buffer. finish installs a completion handler before the caller commits. Never
 * reuse a command buffer after finishing. Abandon only an uncommitted buffer. */
@interface FFPRBatch : NSObject
- (instancetype)initWithCommandBuffer:(id<MTLCommandBuffer>)command;
- (BOOL)finish;
@end

/* Buffer identity is allocation identity, not content identity. All methods
 * must run in stream order, on a single owner thread. Submit command buffers to
 * the same ordered Metal queue in that order. Cross-queue synchronization and
 * external GPU writes must be represented explicitly by the caller. */
@interface FFPRRegistry : NSObject
/* Default budget is 512 MiB; custom limit includes destroyed resources until
 * the last batch holding them has actually completed; includes staging bytes.
 * This bounds requested payload sizes, not Metal allocator overhead. */
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (instancetype)initWithDevice:(id<MTLDevice>)device budget:(NSUInteger)budget;
- (BOOL)createBuffer:(FFPRHandle)handle length:(NSUInteger)length;
/* The update copies bytes synchronously into owned staging memory. The caller
 * may release or modify its input as soon as this method returns. */
- (BOOL)writeBuffer:(FFPRHandle)handle offset:(NSUInteger)offset
              bytes:(const void *)bytes length:(NSUInteger)length batch:(FFPRBatch *)batch;
- (BOOL)copyBuffer:(FFPRHandle)source sourceOffset:(NSUInteger)sourceOffset
       destination:(FFPRHandle)destination destinationOffset:(NSUInteger)destinationOffset
            length:(NSUInteger)length batch:(FFPRBatch *)batch;
/* Retains the exact resource for this batch, including after destroy. */
- (id<MTLBuffer>)buffer:(FFPRHandle)handle batch:(FFPRBatch *)batch;
/* Immediately invalidates the handle. A later create for the same object must
 * use a strictly larger generation, even after the previous object retires. */
- (BOOL)destroyBuffer:(FFPRHandle)handle;
@end
#endif
