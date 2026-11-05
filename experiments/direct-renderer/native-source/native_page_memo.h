/* Private decoder-owned exact page memo. Sampled words select a slot only;
 * a hit requires length equality and memcmp of every independently owned byte.
 * Canonical domains, ordered page digests and final IDs are unchanged. */
#ifndef BEDROCK_PRIVATE_PAGE_MEMO_H
#define BEDROCK_PRIVATE_PAGE_MEMO_H
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#define FFPC_SLOTS 256u
#define FFPC_BYTES (FFPC_SLOTS*FFST_CONTENT_PAGE_BYTES)
typedef struct {
    pthread_mutex_t lock;
    uint64_t signature;
    size_t length;
    uint8_t digest[32];
    BOOL valid;
} ffpc_entry;
typedef struct {
    _Atomic uint64_t pages,hits,misses,comparedBytes,copiedBytes,mismatches;
} ffpc_event;
@interface FFSTPrivatePageMemo : NSObject {
@public
    ffpc_entry entries[FFPC_SLOTS];
    uint8_t *storage;
    unsigned mode,observe,initialized;
    ffpc_event event;
}
- (instancetype)initWithMode:(unsigned)value observe:(BOOL)enabled;
@end
@implementation FFSTPrivatePageMemo
- (instancetype)initWithMode:(unsigned)value observe:(BOOL)enabled {
    self=[super init];if(!self)return nil;mode=value;observe=enabled?1u:0u;
    storage=malloc(FFPC_BYTES);if(!storage)return nil;
    for(unsigned i=0;i<FFPC_SLOTS;++i){if(pthread_mutex_init(&entries[i].lock,NULL))return nil;++initialized;}
    return self;
}
- (void)dealloc {
    for(unsigned i=0;i<initialized;++i)pthread_mutex_destroy(&entries[i].lock);
    free(storage);
}
@end
static unsigned ffpc_mode(void) {
    const char *v=getenv("BEDROCK_PRIVATE_PAGE_MEMO");
    return v&&!strcmp(v,"1")?1u:v&&!strcmp(v,"2")?2u:0u;
}
static FFSTPrivatePageMemo *ffpc_create(void) {
    unsigned mode=ffpc_mode();if(!mode)return nil;
    const char *v=getenv("BEDROCK_PRIVATE_PAGE_MEMO_OBSERVE");
    return [[FFSTPrivatePageMemo alloc] initWithMode:mode observe:(mode==1||(v&&!strcmp(v,"1")))];
}
static uint64_t ffpc_signature(const uint8_t *bytes,size_t length) {
    uint64_t h=UINT64_C(0x9e3779b97f4a7c15)^(uint64_t)length;
    /* All callers pass a nonempty page. Tiny partial pages use one byte. */
    if(length<8){for(size_t i=0;i<length;++i)h=(h^bytes[i])*UINT64_C(0x100000001b3);return h;}
    const size_t at[]={0,length/4,length/2,(length/4)*3,length-8};
    for(unsigned i=0;i<5;++i){size_t offset=MIN(at[i],length-8);uint64_t word;
        memcpy(&word,bytes+offset,8);h^=word;h^=h>>30;h*=UINT64_C(0xbf58476d1ce4e5b9);
        h^=h>>27;h*=UINT64_C(0x94d049bb133111eb);h^=h>>31;}
    return h;
}
static BOOL ffpc_page(FFSTPrivatePageMemo *memo,const uint8_t *bytes,size_t length,uint8_t out[32]) {
    if(!memo||!bytes||!length||length>FFST_CONTENT_PAGE_BYTES)return NO;
    uint64_t signature=ffpc_signature(bytes,length);unsigned slot=(unsigned)signature&(FFPC_SLOTS-1);
    ffpc_entry *e=&memo->entries[slot];uint8_t *owned=memo->storage+(size_t)slot*FFST_CONTENT_PAGE_BYTES;
    BOOL hit=NO;pthread_mutex_lock(&e->lock);
    if(e->valid&&e->signature==signature&&e->length==length){
        if(memo->observe)atomic_fetch_add_explicit(&memo->event.comparedBytes,length,memory_order_relaxed);
        hit=memcmp(owned,bytes,length)==0;
        if(hit)memcpy(out,e->digest,32);
    }
    pthread_mutex_unlock(&e->lock);
    if(memo->observe){atomic_fetch_add_explicit(&memo->event.pages,1,memory_order_relaxed);
        atomic_fetch_add_explicit(hit?&memo->event.hits:&memo->event.misses,1,memory_order_relaxed);}
    if(hit&&memo->mode==2)return YES;
    uint8_t actual[32];CC_SHA256(bytes,(CC_LONG)length,actual);
    if(hit){if(memcmp(actual,out,32)){atomic_fetch_add_explicit(&memo->event.mismatches,1,memory_order_relaxed);return NO;}}
    else {
        pthread_mutex_lock(&e->lock);
        memcpy(owned,bytes,length);memcpy(e->digest,actual,32);e->signature=signature;e->length=length;e->valid=YES;
        pthread_mutex_unlock(&e->lock);
        if(memo->observe)atomic_fetch_add_explicit(&memo->event.copiedBytes,length,memory_order_relaxed);
    }
    memcpy(out,actual,32);return YES;
}
static NSData *ffpc_buffer_id(FFSTPrivatePageMemo *memo,const void *bytes,size_t length) {
    if(!memo)return ffst_buffer_content_id(bytes,length);
    if(!bytes||length<FFST_CONTENT_PAGE_MIN_BYTES||length>FFST_CONTENT_BUFFER_MAX_BYTES)return nil;
    uint8_t digests[FFST_CONTENT_PAGE_LIMIT*32];uint8_t *output=digests;
    size_t count=(length+FFST_CONTENT_PAGE_BYTES-1)/FFST_CONTENT_PAGE_BYTES;
    unsigned mode=ffst_private_page_mode(),lanes=mode==2?2u:mode==4?4u:1u;
    _Atomic unsigned failed=0;_Atomic unsigned *failure=&failed;
    void (^work)(size_t)=^(size_t lane){
        for(size_t i=lane;i<count;i+=lanes){size_t offset=i*FFST_CONTENT_PAGE_BYTES;
            if(!ffpc_page(memo,(const uint8_t *)bytes+offset,MIN((size_t)FFST_CONTENT_PAGE_BYTES,length-offset),output+i*32))
                atomic_store_explicit(failure,1,memory_order_relaxed);
        }
    };
    if(lanes==1)work(0);else dispatch_apply(lanes,dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),work);
    if(atomic_load_explicit(&failed,memory_order_relaxed))return nil;
    return ffst_verified_pages_content_id(digests,count,length);
}
static void ffpc_begin(FFSTPrivatePageMemo *memo) {
    if(!memo||!memo->observe)return;
    /* The decoder owns the memo; fork/join of the previous call is complete. */
    atomic_store(&memo->event.pages,0);atomic_store(&memo->event.hits,0);atomic_store(&memo->event.misses,0);
    atomic_store(&memo->event.comparedBytes,0);atomic_store(&memo->event.copiedBytes,0);atomic_store(&memo->event.mismatches,0);
}
static _Atomic unsigned ffpc_rows=0;
static void ffpc_report(FFSTPrivatePageMemo *memo,uint64_t serial,uint64_t frame,uint64_t chunk) {
    if(!memo||!memo->observe)return;
    if(atomic_fetch_add_explicit(&ffpc_rows,1,memory_order_relaxed)>=16384)return;
    unsigned resident=0;for(unsigned i=0;i<FFPC_SLOTS;++i)resident+=memo->entries[i].valid?1u:0u;
    char line[384];int size=snprintf(line,sizeof(line),
        "[PCM1] serial=%llu frame=%llu chunk=%llu mode=%u pages=%llu hits=%llu misses=%llu compared_bytes=%llu copied_bytes=%llu resident_pages=%u mismatches=%llu\n",
        (unsigned long long)serial,(unsigned long long)frame,(unsigned long long)chunk,memo->mode,
        (unsigned long long)atomic_load(&memo->event.pages),(unsigned long long)atomic_load(&memo->event.hits),
        (unsigned long long)atomic_load(&memo->event.misses),(unsigned long long)atomic_load(&memo->event.comparedBytes),
        (unsigned long long)atomic_load(&memo->event.copiedBytes),resident,(unsigned long long)atomic_load(&memo->event.mismatches));
    if(size>0&&(size_t)size<sizeof(line))(void)write(STDERR_FILENO,line,(size_t)size);
}
#endif
