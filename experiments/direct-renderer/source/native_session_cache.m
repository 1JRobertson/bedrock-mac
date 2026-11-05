#import "native_session_cache.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdlib.h>

#if !__has_feature(objc_arc)
#error native_session_cache.m requires ARC
#endif

NSData *ffst_asset_content_key(uint32_t kind,NSData *digest,uint64_t length,NSData *descriptor) {
    if(![digest isKindOfClass:[NSData class]]||digest.length!=CC_SHA256_DIGEST_LENGTH||!length||
       (kind!=FFST_ASSET_BUFFER&&kind!=FFST_ASSET_TEXTURE)||
       (kind==FFST_ASSET_BUFFER&&descriptor.length)||
       (kind==FFST_ASSET_TEXTURE&&(![descriptor isKindOfClass:[NSData class]]||!descriptor.length||descriptor.length>8192)))return nil;
    const uint64_t header[]={UINT64_C(0x4646535441535345),1,kind,length};
    NSMutableData *key=[NSMutableData dataWithBytes:header length:sizeof(header)];
    [key appendData:digest];
    if(kind==FFST_ASSET_TEXTURE){unsigned char shape[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(descriptor.bytes,(CC_LONG)descriptor.length,shape);[key appendBytes:shape length:sizeof(shape)];}
    return [key copy];
}

/* Fixed storage makes the commit phase allocation-free. Keys are canonical
 * Foundation snapshots before hashing, so caller overrides cannot run while
 * bucket/LRU links are being changed. Slots own objects; links are indices. */
#define CACHE_NONE NSNotFound
typedef struct {
    __strong id key,object;
    uint64_t cost;
    NSUInteger hash,bucketPrev,bucketNext,prev,next,freeNext;
} FFSTCacheSlot;

static void cache_lru_remove(FFSTCacheSlot *slots,NSUInteger index,NSUInteger *head,NSUInteger *tail) {
    FFSTCacheSlot *slot=&slots[index];
    if(slot->prev!=CACHE_NONE)slots[slot->prev].next=slot->next;else *head=slot->next;
    if(slot->next!=CACHE_NONE)slots[slot->next].prev=slot->prev;else *tail=slot->prev;
}
static void cache_lru_append(FFSTCacheSlot *slots,NSUInteger index,NSUInteger *head,NSUInteger *tail) {
    slots[index].prev=*tail;slots[index].next=CACHE_NONE;
    if(*tail!=CACHE_NONE)slots[*tail].next=index;else *head=index;*tail=index;
}

static BOOL cache_key(id key) {
    return [key isKindOfClass:[NSString class]] || [key isKindOfClass:[NSData class]];
}
static id cache_key_snapshot(id key) {
    if([key isKindOfClass:[NSString class]]){
        if([key length]>4096)return nil;
        NSData *utf8=[key dataUsingEncoding:NSUTF8StringEncoding];
        if(!utf8||utf8.length>4096)return nil;
        return [[NSString alloc] initWithBytes:utf8.bytes length:utf8.length encoding:NSUTF8StringEncoding];
    }
    if([key isKindOfClass:[NSData class]]){
        NSUInteger length=[key length];if(length>4096)return nil;
        return [[NSData alloc] initWithBytes:[key bytes] length:length];
    }
    return nil;
}
static uint64_t cache_increment(uint64_t count,uint64_t amount) {
    return amount>UINT64_MAX-count?UINT64_MAX:count+amount;
}
@interface FFSTNativeSessionCache () {
    FFSTCacheSlot *_slots;
    NSUInteger *_buckets,_bucketCount,_maxEntries,_count,_head,_tail,_free;
    uint64_t _maxCost,_cost,_hits,_misses,_evictions;
    uint64_t _bufferUploadBytes,_textureUploadBytes,_bufferAllocations,_textureAllocations,_textureStagingAllocations;
    uint64_t _bufferContentHits,_textureContentHits,_firstIdentityContentHits;
}
@end
@implementation FFSTNativeSessionCache
- (instancetype)initWithMaxEntries:(NSUInteger)maxEntries maxCost:(uint64_t)maxCost {
    if(!maxEntries||!maxCost||maxEntries>SIZE_MAX/sizeof(FFSTCacheSlot)||maxEntries>SIZE_MAX/2)return nil;
    self=[super init];if(self){
        _maxEntries=maxEntries;_maxCost=maxCost;_bucketCount=1;
        while(_bucketCount<maxEntries*2){if(_bucketCount>SIZE_MAX/2)return nil;_bucketCount*=2;}
        if(_bucketCount>SIZE_MAX/sizeof(NSUInteger))return nil;
        _slots=calloc(maxEntries,sizeof(*_slots));_buckets=malloc(_bucketCount*sizeof(*_buckets));
        if(!_slots||!_buckets)return nil;
        for(NSUInteger i=0;i<_bucketCount;i++)_buckets[i]=CACHE_NONE;
        for(NSUInteger i=0;i<maxEntries;i++)_slots[i].freeNext=i+1<maxEntries?i+1:CACHE_NONE;
        _head=_tail=CACHE_NONE;_free=0;
    }return self;
}
- (void)dealloc {
    if(_slots)for(NSUInteger i=0;i<_maxEntries;i++){_slots[i].key=nil;_slots[i].object=nil;}
    free(_slots);free(_buckets);
}
- (NSUInteger)findKey:(id)key hash:(NSUInteger)hash {
    for(NSUInteger i=_buckets[hash&(_bucketCount-1)];i!=CACHE_NONE;i=_slots[i].bucketNext)
        if(_slots[i].hash==hash&&[_slots[i].key isEqual:key])return i;
    return CACHE_NONE;
}
- (void)removeIndex:(NSUInteger)index {
    FFSTCacheSlot *slot=&_slots[index];
    if(slot->bucketPrev!=CACHE_NONE)_slots[slot->bucketPrev].bucketNext=slot->bucketNext;
    else _buckets[slot->hash&(_bucketCount-1)]=slot->bucketNext;
    if(slot->bucketNext!=CACHE_NONE)_slots[slot->bucketNext].bucketPrev=slot->bucketPrev;
    cache_lru_remove(_slots,index,&_head,&_tail);_cost-=slot->cost;--_count;
    slot->key=nil;slot->object=nil;slot->freeNext=_free;_free=index;
}
- (id)objectForKey:(id)key {
    @try {
        id query=cache_key_snapshot(key);
        NSUInteger index=query?[self findKey:query hash:[query hash]]:CACHE_NONE;
        if(index!=CACHE_NONE){
            if(index!=_tail){cache_lru_remove(_slots,index,&_head,&_tail);cache_lru_append(_slots,index,&_head,&_tail);}
            _hits=cache_increment(_hits,1);return _slots[index].object;
        }
    } @catch(__unused NSException *exception) { }
    _misses=cache_increment(_misses,1);return nil;
}
- (id)objectForAssetKind:(uint32_t)kind digest:(NSData *)digest length:(uint64_t)length
             descriptor:(NSData *)descriptor key:(NSData **)key {
    if(key)*key=nil;
    @try {
        /* No caller-supplied key is trusted: this is a fresh immutable copy
         * constructed here from the canonical content fields. */
        NSData *query=ffst_asset_content_key(kind,digest,length,descriptor);if(!query)return nil;
        if(key)*key=query;
        NSUInteger index=[self findKey:query hash:query.hash];
        if(index!=CACHE_NONE){
            if(index!=_tail){cache_lru_remove(_slots,index,&_head,&_tail);cache_lru_append(_slots,index,&_head,&_tail);}
            _hits=cache_increment(_hits,1);return _slots[index].object;
        }
    } @catch(__unused NSException *exception) { }
    _misses=cache_increment(_misses,1);return nil;
}
- (BOOL)setObject:(id)object forKey:(id)key cost:(uint64_t)cost {
    __attribute__((objc_precise_lifetime)) NSMutableArray *retired;
    id ownedKey;__attribute__((objc_precise_lifetime)) id ownedObject=object;
    uint64_t total=_cost,victims=0;NSUInteger existing,hash,count=_count;
    @try {
        if(!object||!cache_key(key)||cost>_maxCost)return NO;
        ownedKey=cache_key_snapshot(key);if(!ownedKey)return NO;hash=[ownedKey hash];existing=[self findKey:ownedKey hash:hash];
        retired=[NSMutableArray array];
        if(existing!=CACHE_NONE){total-=_slots[existing].cost;--count;[retired addObject:_slots[existing].object];}
        for(NSUInteger i=_head;count>=_maxEntries||cost>_maxCost-total;i=_slots[i].next){
            if(i==CACHE_NONE)return NO;if(i==existing)continue;
            total-=_slots[i].cost;--count;++victims;[retired addObject:_slots[i].object];
        }
    } @catch(__unused NSException *exception) { return NO; }
    /* No allocation or caller key methods after this point. Displaced objects
     * stay alive until the complete residency/LRU/counters have been published. */
    if(existing!=CACHE_NONE)[self removeIndex:existing];
    for(uint64_t i=0;i<victims;i++)[self removeIndex:_head];
    NSUInteger index=_free;FFSTCacheSlot *slot=&_slots[index];_free=slot->freeNext;
    slot->key=ownedKey;slot->object=ownedObject;slot->cost=cost;slot->hash=hash;
    NSUInteger bucket=hash&(_bucketCount-1);slot->bucketPrev=CACHE_NONE;slot->bucketNext=_buckets[bucket];
    if(slot->bucketNext!=CACHE_NONE)_slots[slot->bucketNext].bucketPrev=index;_buckets[bucket]=index;
    cache_lru_append(_slots,index,&_head,&_tail);++_count;_cost=total+cost;_evictions=cache_increment(_evictions,victims);
    return YES;
}
- (void)removeAll {
    __attribute__((objc_precise_lifetime)) NSMutableArray *retired;
    @try {retired=[NSMutableArray arrayWithCapacity:_count];
        for(NSUInteger i=_head;i!=CACHE_NONE;i=_slots[i].next)[retired addObject:_slots[i].object];}
    @catch(__unused NSException *exception){return;}
    while(_head!=CACHE_NONE)[self removeIndex:_head];
}
- (NSUInteger)removeObjectsWithKeyPrefix:(NSString *)prefix {
    __attribute__((objc_precise_lifetime)) NSMutableArray *retired;NSMutableArray<NSNumber *> *indices;
    @try {
        if(![prefix isKindOfClass:[NSString class]])return 0;
        NSString *ownedPrefix=cache_key_snapshot(prefix);if(!ownedPrefix)return 0;
        retired=[NSMutableArray array];indices=[NSMutableArray array];
        for(NSUInteger i=_head;i!=CACHE_NONE;i=_slots[i].next)
            if([_slots[i].key isKindOfClass:[NSString class]]&&[_slots[i].key hasPrefix:ownedPrefix]){
                [indices addObject:@(i)];[retired addObject:_slots[i].object];}
    } @catch(__unused NSException *exception) {return 0;}
    for(NSNumber *index in indices)[self removeIndex:index.unsignedIntegerValue];return indices.count;
}
- (void)recordAssetUpload:(uint32_t)kind bytes:(uint64_t)bytes {
    if(kind==FFST_ASSET_BUFFER){_bufferUploadBytes=cache_increment(_bufferUploadBytes,bytes);_bufferAllocations=cache_increment(_bufferAllocations,1);}
    else if(kind==FFST_ASSET_TEXTURE){_textureUploadBytes=cache_increment(_textureUploadBytes,bytes);
        _textureAllocations=cache_increment(_textureAllocations,1);_textureStagingAllocations=cache_increment(_textureStagingAllocations,1);}
}
- (void)recordAssetContentHit:(uint32_t)kind firstIdentity:(BOOL)firstIdentity {
    if(kind==FFST_ASSET_BUFFER)_bufferContentHits=cache_increment(_bufferContentHits,1);
    else if(kind==FFST_ASSET_TEXTURE)_textureContentHits=cache_increment(_textureContentHits,1);else return;
    if(firstIdentity)_firstIdentityContentHits=cache_increment(_firstIdentityContentHits,1);
}
- (NSDictionary<NSString *,NSNumber *> *)stats {
    return @{@"count":@(_count),@"cost":@(_cost),@"hits":@(_hits),@"misses":@(_misses),@"evictions":@(_evictions),
        @"buffer_upload_bytes":@(_bufferUploadBytes),@"texture_upload_bytes":@(_textureUploadBytes),
        @"buffer_asset_allocations":@(_bufferAllocations),@"texture_asset_allocations":@(_textureAllocations),
        @"texture_staging_allocations":@(_textureStagingAllocations),@"buffer_content_hits":@(_bufferContentHits),
        @"texture_content_hits":@(_textureContentHits),@"first_identity_content_hits":@(_firstIdentityContentHits)};
}
@end
