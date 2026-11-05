/* Bounded immutable native-object residency. ARC; one serialized session owner. */
#ifndef BEDROCK_NATIVE_SESSION_CACHE_H
#define BEDROCK_NATIVE_SESSION_CACHE_H
#import <Foundation/Foundation.h>
#include <stdint.h>

enum { FFST_ASSET_BUFFER = 1, FFST_ASSET_TEXTURE = 2 };
/* Verify immutable bytes and logical-version consistency before looking up
 * this key. Texture descriptors include allocation/view and plane-layout
 * fields. Digest is 32 bytes; texture descriptor is 1..8192 bytes, buffer nil.
 * Keys omit source allocation identity and stay below the 4096-byte key cap. */
NSData *ffst_asset_content_key(uint32_t kind, NSData *sha256, uint64_t length, NSData *descriptor);

@interface FFSTNativeSessionCache : NSObject
/* Both limits must be nonzero. Declared costs may be zero and must include the
 * caller's chosen residency estimate. The cache has no Metal/device dependency. */
- (instancetype)initWithMaxEntries:(NSUInteger)maxEntries maxCost:(uint64_t)maxCost NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/* NSString/NSData inputs are snapshotted into immutable storage, capped at 4096
 * UTF-8/byte bytes. Equal keys share one entry; reads
 * and successful replacements make that entry most recently used. Lookup uses
 * a preallocated hash table and O(1) LRU links. Invalid keys
 * and key-operation exceptions are misses; failed puts preserve residency. */
- (id)objectForKey:(id)key;
/* Builds the canonical immutable content key inside the cache, then looks it
 * up without a second snapshot. The returned key may be used for insertion.
 * Invalid asset fields return nil and set key to nil without a cache lookup. */
- (id)objectForAssetKind:(uint32_t)kind digest:(NSData *)digest length:(uint64_t)length
             descriptor:(NSData *)descriptor key:(NSData **)key;
- (BOOL)setObject:(id)object forKey:(id)key cost:(uint64_t)cost;
/* Clears resident objects/cost, preserving lifetime hit/miss/eviction counters.
 * External command buffers/contexts must retain their own in-flight objects. */
- (void)removeAll;
/* Explicit source retirement: remove matching NSString keys, leaving NSData
 * keys and other generations resident. Does not increment eviction counters. */
- (NSUInteger)removeObjectsWithKeyPrefix:(NSString *)prefix;
/* Cumulative immutable-asset work, independent of residency cost. Texture
 * uploads allocate one asset and one temporary staging buffer. firstIdentity
 * means this logical identity had no verified digest before the content hit. */
- (void)recordAssetUpload:(uint32_t)kind bytes:(uint64_t)bytes;
- (void)recordAssetContentHit:(uint32_t)kind firstIdentity:(BOOL)firstIdentity;
/* Immutable snapshot of residency and cumulative asset-work counters. Counters
 * saturate at UINT64_MAX. Explicit removals/replacements are not evictions. */
- (NSDictionary<NSString *,NSNumber *> *)stats;
@end
#endif
