/* Private experiment: include after struct pso, psos[N], and guard.
 * MRC. Live registry lookup, snapshot creation, and retirement all use guard. */
#ifndef FF_PRIVATE_PIPELINE_SNAPSHOT_CACHE_H
#define FF_PRIVATE_PIPELINE_SNAPSHOT_CACHE_H
#import <objc/runtime.h>
#include <stdatomic.h>

/* Separate from FFReplayBytes: conservative fixed charge for each cached
 * snapshot, its fixed-size layout, owner array, accounting token and allocator
 * overhead. This is an admission estimate, not malloc's exact byte count.
 * The charge follows the snapshot until its final release (not just eviction),
 * so outstanding autorelease pools cannot make the cache unbounded. */
#define FF_PC_CHARGE (sizeof(ff_draw_layout) + 4096u)
#define FF_PC_BUDGET ((size_t)N * FF_PC_CHARGE)
static _Atomic size_t ff_pc_charged;
static _Atomic size_t ff_pc_peak;
static _Atomic uint64_t ff_pc_hits, ff_pc_builds, ff_pc_fallbacks, ff_pc_mismatches;
static int ff_pipeline_cache_mode; /* 0 original, 1 shadow, 2 cached */
static char ff_pc_charge_key;
#ifdef FF_PIPELINE_CACHE_TESTING
static int ff_pc_fail_next;
#endif

@interface FFPrivatePipelineCharge : NSObject @end
@implementation FFPrivatePipelineCharge
- (void)dealloc { atomic_fetch_sub(&ff_pc_charged, FF_PC_CHARGE); [super dealloc]; }
@end

static BOOL ff_pc_reserve(void) {
    size_t old=atomic_load(&ff_pc_charged);
    do { if(old>FF_PC_BUDGET-FF_PC_CHARGE)return NO; }
    while(!atomic_compare_exchange_weak(&ff_pc_charged,&old,old+FF_PC_CHARGE));
    size_t now=old+FF_PC_CHARGE, peak=atomic_load(&ff_pc_peak);
    while(peak<now&&!atomic_compare_exchange_weak(&ff_pc_peak,&peak,now)) {}
    return YES;
}
/* The same assignments as the original resolver. The caller owns the result.
 * For the cached path only, catch allocation exceptions and fall back. */
static FFSTPassPipelineSnapshot *ff_pc_make(struct pso *s, BOOL cacheAttempt) {
    FFSTPassPipelineSnapshot *snapshot=nil;
    @try {
        snapshot=[[FFSTPassPipelineSnapshot alloc]init];
        if(!snapshot)return nil;
        snapshot.vertexLibrary=s->vs.payload;snapshot.fragmentLibrary=s->ps.payload;
        snapshot.vertexFunction=s->vn;snapshot.fragmentFunction=s->pn;
        snapshot.state=s->state;snapshot.topology=s->topology;
        snapshot.layout=[NSData dataWithBytes:&s->layout length:sizeof(s->layout)];
        snapshot.byteOwners=@[s->vs,s->ps];
        if(cacheAttempt&&(!snapshot.layout||!snapshot.byteOwners||!snapshot.vertexLibrary||
                          !snapshot.fragmentLibrary||!snapshot.vertexFunction||
                          !snapshot.fragmentFunction||!snapshot.state)) {
            [snapshot release];return nil;
        }
        return snapshot;
    } @catch (NSException *exception) {
        [snapshot release];
        if(!cacheAttempt)@throw;
        (void)exception;return nil;
    }
}
/* Compare concrete classes as well as equality, recursively for metadata;
 * exact owner and library identities ensure byte accounting is unchanged. */
static BOOL ff_pc_equal_value(id a,id b) {
    if(a==b)return YES;
    if(!a||!b||[a class]!=[b class]||![a isEqual:b])return NO;
    if([a isKindOfClass:[NSArray class]]) {
        NSArray *aa=a,*bb=b;if(aa.count!=bb.count)return NO;
        for(NSUInteger i=0;i<aa.count;++i)if(!ff_pc_equal_value(aa[i],bb[i]))return NO;
    } else if([a isKindOfClass:[NSDictionary class]]) {
        NSDictionary *aa=a,*bb=b;
        for(id key in aa) {
            id other=nil;for(id candidate in bb)if(ff_pc_equal_value(key,candidate)){other=candidate;break;}
            if(!other||!ff_pc_equal_value(aa[key],bb[other]))return NO;
        }
    }
    return YES;
}
static BOOL ff_pc_equal(FFSTPassPipelineSnapshot *a,FFSTPassPipelineSnapshot *b) {
    if(!a||!b||[a class]!=[b class]||a.topology!=b.topology||
       a.vertexLibrary!=b.vertexLibrary||a.fragmentLibrary!=b.fragmentLibrary||
       !ff_pc_equal_value(a.vertexLibrary,b.vertexLibrary)||!ff_pc_equal_value(a.fragmentLibrary,b.fragmentLibrary)||
       !ff_pc_equal_value(a.vertexFunction,b.vertexFunction)||!ff_pc_equal_value(a.fragmentFunction,b.fragmentFunction)||
       !ff_pc_equal_value(a.state,b.state)||!ff_pc_equal_value(a.layout,b.layout)||
       !ff_pc_equal_value(a.byteOwners,b.byteOwners)||a.byteOwners.count!=b.byteOwners.count)return NO;
    for(NSUInteger i=0;i<a.byteOwners.count;++i)
        if(a.byteOwners[i]!=b.byteOwners[i]||[a.byteOwners[i] class]!=[b.byteOwners[i] class])return NO;
    return YES;
}
/* Must hold guard. Slot owns the retained result until ff_pc_drop. */
static FFSTPassPipelineSnapshot *ff_pc_cached(struct pso *s) {
    if(s->cached_snapshot){atomic_fetch_add(&ff_pc_hits,1);return s->cached_snapshot;}
    if(!ff_pc_reserve()){atomic_fetch_add(&ff_pc_fallbacks,1);return nil;}
#ifdef FF_PIPELINE_CACHE_TESTING
    if(ff_pc_fail_next){ff_pc_fail_next=0;atomic_fetch_sub(&ff_pc_charged,FF_PC_CHARGE);atomic_fetch_add(&ff_pc_fallbacks,1);return nil;}
#endif
    FFPrivatePipelineCharge *charge=nil;FFSTPassPipelineSnapshot *snapshot=nil;
    @try { charge=[[FFPrivatePipelineCharge alloc]init]; }
    @catch (NSException *exception) { (void)exception; }
    if(!charge){atomic_fetch_sub(&ff_pc_charged,FF_PC_CHARGE);atomic_fetch_add(&ff_pc_fallbacks,1);return nil;}
    @try {
        snapshot=ff_pc_make(s,YES);
        if(snapshot) {
            objc_setAssociatedObject(snapshot,&ff_pc_charge_key,charge,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            if(objc_getAssociatedObject(snapshot,&ff_pc_charge_key)!=charge){[snapshot release];snapshot=nil;}
        }
    } @catch (NSException *exception) { (void)exception;[snapshot release];snapshot=nil; }
    [charge release];
    if(!snapshot){atomic_fetch_add(&ff_pc_fallbacks,1);return nil;}
    s->cached_snapshot=snapshot;atomic_fetch_add(&ff_pc_builds,1);return snapshot;
}
static void ff_pc_drop(struct pso *s) { [s->cached_snapshot release];s->cached_snapshot=nil; }
/* Returns an autoreleased reference retained while locked, so concurrent
 * eviction cannot end its lifetime. Every call repeats the live lookup. */
static FFSTPassPipelineSnapshot *ff_pc_resolve(id object) {
    if(!object)return nil;
    FFSTPassPipelineSnapshot *result=nil;pthread_mutex_lock(&guard);
    for(unsigned i=0;i<N;++i)if(psos[i].obj==object) {
        struct pso *s=&psos[i];
        if(ff_pipeline_cache_mode==0)result=ff_pc_make(s,NO);
        else if(ff_pipeline_cache_mode==1) {
            result=ff_pc_make(s,NO);
            FFSTPassPipelineSnapshot *cached=ff_pc_cached(s);
            if(cached&&!ff_pc_equal(result,cached)) {
                uint64_t n=atomic_fetch_add(&ff_pc_mismatches,1)+1;
                if(n<=10)fprintf(stderr,"[pipeline-snapshot-cache] shadow-mismatch=%llu\n",(unsigned long long)n);
            }
        } else {
            FFSTPassPipelineSnapshot *cached=ff_pc_cached(s);
            result=cached?[cached retain]:ff_pc_make(s,NO);
        }
        break;
    }
    pthread_mutex_unlock(&guard);return [result autorelease];
}
#ifndef FF_PIPELINE_CACHE_TESTING
__attribute__((destructor)) static void ff_pc_summary(void) {
    if(!ff_pipeline_cache_mode)return;
    fprintf(stderr,"[pipeline-snapshot-cache-summary] mode=%d hits=%llu builds=%llu fallbacks=%llu mismatches=%llu charged=%zu peak=%zu budget=%zu charge=%zu\n",
        ff_pipeline_cache_mode,(unsigned long long)atomic_load(&ff_pc_hits),(unsigned long long)atomic_load(&ff_pc_builds),
        (unsigned long long)atomic_load(&ff_pc_fallbacks),(unsigned long long)atomic_load(&ff_pc_mismatches),
        atomic_load(&ff_pc_charged),atomic_load(&ff_pc_peak),FF_PC_BUDGET,(size_t)FF_PC_CHARGE);
}
#endif
#endif
