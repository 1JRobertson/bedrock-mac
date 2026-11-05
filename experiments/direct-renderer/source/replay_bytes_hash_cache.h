/* Private MRC implementation of the real byte owner. Include after `total`.
 * Only these exact owners, whose payload is copied on init, may cache names. */
#ifndef FF_PRIVATE_REPLAY_BYTES_HASH_CACHE_H
#define FF_PRIVATE_REPLAY_BYTES_HASH_CACHE_H
#import <objc/runtime.h>
#include <stdatomic.h>
#import "library_hash_name.h"
#define FF_LHC_SLOTS 1024u
/* A conservative fixed admission charge, not malloc's exact accounting. */
#define FF_LHC_CHARGE 512u
#define FF_LHC_BUDGET ((size_t)FF_LHC_SLOTS*FF_LHC_CHARGE)
static _Atomic size_t ff_lhc_charged,ff_lhc_peak;
static _Atomic uint64_t ff_lhc_hits,ff_lhc_builds,ff_lhc_fallbacks,ff_lhc_unknown,ff_lhc_mismatches;
static int ff_lhc_mode;
#ifdef FF_LIBRARY_CACHE_TESTING
static int ff_lhc_fail_next;
#endif
static BOOL ff_lhc_reserve(void) {
    size_t old=atomic_load(&ff_lhc_charged);
    do {if(old>FF_LHC_BUDGET-FF_LHC_CHARGE)return NO;}
    while(!atomic_compare_exchange_weak(&ff_lhc_charged,&old,old+FF_LHC_CHARGE));
    size_t now=old+FF_LHC_CHARGE,peak=atomic_load(&ff_lhc_peak);
    while(peak<now&&!atomic_compare_exchange_weak(&ff_lhc_peak,&peak,now)){}
    return YES;
}
@interface FFReplayBytes : NSObject
@property(nonatomic,readonly) NSData *payload;
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length;
- (NSString *)ff_cachedLibraryName;
#ifdef FF_LIBRARY_CACHE_TESTING
- (void)ff_fixtureCorruptName;
#endif
@end
@implementation FFReplayBytes { NSData *_payload; NSString *_ff_cached_name; }
- (instancetype)initWithBytes:(const void *)bytes length:(NSUInteger)length {
    self=[super init];if(!self)return nil;
    _payload=[[NSData alloc]initWithBytes:bytes length:length];
    if(!_payload){[self release];return nil;}
    atomic_fetch_add(&total,length);return self;
}
- (NSData *)payload{return _payload;}
- (NSString *)ff_cachedLibraryName {
    @synchronized(self) {
        if(_ff_cached_name){atomic_fetch_add(&ff_lhc_hits,1);return [[_ff_cached_name retain]autorelease];}
        if(!ff_lhc_reserve()){atomic_fetch_add(&ff_lhc_fallbacks,1);return nil;}
#ifdef FF_LIBRARY_CACHE_TESTING
        if(ff_lhc_fail_next){ff_lhc_fail_next=0;atomic_fetch_sub(&ff_lhc_charged,FF_LHC_CHARGE);atomic_fetch_add(&ff_lhc_fallbacks,1);return nil;}
#endif
        @try { _ff_cached_name=[ff_private_library_name(_payload) retain]; }
        @catch(NSException *exception){(void)exception;_ff_cached_name=nil;}
        if(!_ff_cached_name){atomic_fetch_sub(&ff_lhc_charged,FF_LHC_CHARGE);atomic_fetch_add(&ff_lhc_fallbacks,1);return nil;}
        atomic_fetch_add(&ff_lhc_builds,1);return [[_ff_cached_name retain]autorelease];
    }
}
#ifdef FF_LIBRARY_CACHE_TESTING
- (void)ff_fixtureCorruptName {
    @synchronized(self){if(_ff_cached_name){[_ff_cached_name release];_ff_cached_name=[@"fixture-corrupt" retain];}}
}
#endif
- (void)dealloc {
    if(_ff_cached_name){[_ff_cached_name release];atomic_fetch_sub(&ff_lhc_charged,FF_LHC_CHARGE);}
    if(_payload){atomic_fetch_sub(&total,_payload.length);[_payload release];}
    [super dealloc];
}
@end
/* A nil return means the generic producer must use its original SHA path.
 * Array keeps its owners alive; returned names are retained/autoreleased.
 * Avoid even sending payload to unknown objects, subclasses or providers. */
NSString *ff_replay_private_library_name(NSData *blob,NSArray *owners) {
    if(!ff_lhc_mode||!blob||!owners)return nil;
    for(id owner in owners) {
        if(object_getClass(owner)!=[FFReplayBytes class])continue;
        FFReplayBytes *bytes=owner;
        if(bytes.payload!=blob)continue;
        NSString *cached=[bytes ff_cachedLibraryName];
        if(!cached)return nil;
        if(ff_lhc_mode==2)return cached;
        NSString *original=ff_private_library_name(blob);
        if([cached class]!=[original class]||![cached isEqualToString:original]) {
            uint64_t n=atomic_fetch_add(&ff_lhc_mismatches,1)+1;
            if(n<=10)fprintf(stderr,"[library-hash-cache] shadow-mismatch=%llu\n",(unsigned long long)n);
        }
        return original;
    }
    atomic_fetch_add(&ff_lhc_unknown,1);return nil;
}
#ifndef FF_LIBRARY_CACHE_TESTING
__attribute__((destructor)) static void ff_lhc_summary(void) {
    if(!ff_lhc_mode)return;
    fprintf(stderr,"[library-hash-cache-summary] mode=%d hits=%llu builds=%llu fallbacks=%llu unknown=%llu mismatches=%llu charged=%zu peak=%zu budget=%zu charge=%u\n",
        ff_lhc_mode,(unsigned long long)atomic_load(&ff_lhc_hits),(unsigned long long)atomic_load(&ff_lhc_builds),
        (unsigned long long)atomic_load(&ff_lhc_fallbacks),(unsigned long long)atomic_load(&ff_lhc_unknown),
        (unsigned long long)atomic_load(&ff_lhc_mismatches),atomic_load(&ff_lhc_charged),atomic_load(&ff_lhc_peak),FF_LHC_BUDGET,FF_LHC_CHARGE);
}
#endif
#endif
