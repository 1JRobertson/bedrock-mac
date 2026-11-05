/* Canonical buffer content identity, independent of transport representation.
 * Large buffers use ordered verified 64-KiB page SHA256 values. Raw/file
 * fallbacks derive the identical ID from fresh bytes. Textures/libraries keep
 * ordinary whole-blob SHA256; source identities and versions remain separate. */
#ifndef BEDROCK_NATIVE_CONTENT_IDENTITY_H
#define BEDROCK_NATIVE_CONTENT_IDENTITY_H
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
#define FFST_CONTENT_PAGE_BYTES 65536u
#define FFST_CONTENT_PAGE_MIN_BYTES (4u*FFST_CONTENT_PAGE_BYTES)
#define FFST_CONTENT_BUFFER_MAX_BYTES (32u*1024u*1024u)
#define FFST_CONTENT_PAGE_LIMIT (FFST_CONTENT_BUFFER_MAX_BYTES/FFST_CONTENT_PAGE_BYTES)
static inline void ffst_content_be64(NSMutableData *data,uint64_t value) {
    uint8_t bytes[8];for(unsigned i=0;i<8;++i)bytes[i]=(uint8_t)(value>>(56-8*i));[data appendBytes:bytes length:8];
}
static inline NSData *ffst_verified_pages_content_id(const uint8_t *pageSHA,size_t count,uint64_t length) {
    if(!pageSHA||length<FFST_CONTENT_PAGE_MIN_BYTES||length>FFST_CONTENT_BUFFER_MAX_BYTES||
       count!=(length+FFST_CONTENT_PAGE_BYTES-1)/FFST_CONTENT_PAGE_BYTES||count>FFST_CONTENT_PAGE_LIMIT)return nil;
    static const char domain[]="bedrock-native-buffer-pages-v1";
    NSMutableData *identity=[NSMutableData dataWithBytes:domain length:sizeof(domain)];
    ffst_content_be64(identity,FFST_CONTENT_PAGE_BYTES);ffst_content_be64(identity,length);ffst_content_be64(identity,count);
    for(size_t i=0;i<count;++i){uint64_t size=MIN((uint64_t)FFST_CONTENT_PAGE_BYTES,length-i*FFST_CONTENT_PAGE_BYTES);
        ffst_content_be64(identity,size);[identity appendBytes:pageSHA+i*32 length:32];}
    uint8_t digest[32];CC_SHA256(identity.bytes,(CC_LONG)identity.length,digest);return [NSData dataWithBytes:digest length:32];
}

/* Private opt-in fork/join of independent canonical page hashes.  Only page
 * SHA work is parallel; output slots preserve the exact original order. */
static inline unsigned ffst_private_page_mode(void) {
    const char *value=getenv("BEDROCK_PRIVATE_PAGE_SHA");
    if(!value)return 0;if(!strcmp(value,"1"))return 1;if(!strcmp(value,"2"))return 2;if(!strcmp(value,"4"))return 4;if(!strcmp(value,"6"))return 6;if(!strcmp(value,"8"))return 8;return 0;
}
static inline void ffst_private_page_serial(const uint8_t *bytes,size_t length,size_t count,uint8_t *out) {
    for(size_t i=0;i<count;++i){size_t offset=i*FFST_CONTENT_PAGE_BYTES,size=MIN((size_t)FFST_CONTENT_PAGE_BYTES,length-offset);
        CC_SHA256(bytes+offset,(CC_LONG)size,out+i*32);}
}
static inline void ffst_private_page_parallel(const uint8_t *bytes,size_t length,size_t count,unsigned lanes,uint8_t *out) {
    dispatch_queue_t queue=dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0);
    if(!queue){ffst_private_page_serial(bytes,length,count,out);return;}
    lanes=MIN(lanes,(unsigned)count);
    dispatch_apply(lanes,queue,^(size_t lane){
        for(size_t i=lane;i<count;i+=lanes){size_t offset=i*FFST_CONTENT_PAGE_BYTES,size=MIN((size_t)FFST_CONTENT_PAGE_BYTES,length-offset);
            CC_SHA256(bytes+offset,(CC_LONG)size,out+i*32);}
    });
}
static _Atomic uint32_t ffst_private_page_rows=0;
static inline void ffst_private_page_report(unsigned mode,size_t length,size_t count,unsigned mismatch) {
    const char *option=getenv("BEDROCK_PRIVATE_PAGE_SHA_OBSERVE");
    if(mode!=1&&(!option||strcmp(option,"1")))return;
    uint32_t n=atomic_fetch_add_explicit(&ffst_private_page_rows,1,memory_order_relaxed);if(n>=16384)return;
    char line[160];int size=snprintf(line,sizeof(line),"[CPS1] mode=%u bytes=%zu pages=%zu mismatch=%u\n",mode,length,count,mismatch);
    if(size>0&&(size_t)size<sizeof(line))(void)write(STDERR_FILENO,line,(size_t)size);
}

static inline NSData *ffst_buffer_content_id(const void *bytes,size_t length) {
    if(!bytes||!length||length>FFST_CONTENT_BUFFER_MAX_BYTES)return nil;
    if(length<FFST_CONTENT_PAGE_MIN_BYTES){uint8_t digest[32];CC_SHA256(bytes,(CC_LONG)length,digest);return [NSData dataWithBytes:digest length:32];}
    uint8_t digests[FFST_CONTENT_PAGE_LIMIT*32];size_t count=(length+FFST_CONTENT_PAGE_BYTES-1)/FFST_CONTENT_PAGE_BYTES;
    unsigned mode=ffst_private_page_mode();
    if(!mode)ffst_private_page_serial(bytes,length,count,digests);
    else if(mode==1){uint8_t parallel[FFST_CONTENT_PAGE_LIMIT*32];
        ffst_private_page_serial(bytes,length,count,digests);
        ffst_private_page_parallel(bytes,length,count,4,parallel);
        unsigned mismatch=memcmp(digests,parallel,count*32)!=0;
        ffst_private_page_report(mode,length,count,mismatch);if(mismatch)return nil;
    } else {ffst_private_page_parallel(bytes,length,count,mode,digests);
        ffst_private_page_report(mode,length,count,0);}
    return ffst_verified_pages_content_id(digests,count,length);
}
#endif
