/* CPU-only receipt staging. One transport owner drains in FIFO order; native
 * execution and presenter callbacks may append concurrently. */
#ifndef BEDROCK_NATIVE_RECEIPT_MAILBOX_H
#define BEDROCK_NATIVE_RECEIPT_MAILBOX_H
#import <Foundation/Foundation.h>
#include "chunk_stream.h"

@interface FFSTNativeReceiptMailbox : NSObject
/* Four full native batches plus seven reserved failure/presentation receipts.
 * This is staging capacity, separate from the 256-entry transport ring. */
- (BOOL)enqueueBatch:(NSArray<NSData *> *)batch timeoutSeconds:(double)timeout;
- (BOOL)enqueuePriority:(NSData *)receipt;
- (NSData *)first;
- (BOOL)removeFirst:(NSData *)receipt;
- (NSUInteger)count;
- (NSUInteger)maximumCount;
/* Diagnostic snapshot; transport draining uses first/removeFirst. */
- (NSArray<NSData *> *)snapshot;
/* Wakes ordinary waiters; the transport owner may still drain existing items
 * and priority callbacks may still report cancellation. */
- (void)stop;
/* Only after an explicit normal source close: no receiver remains. */
- (void)discardAll;
@end
#endif
