/* Canonical buffer content identity, independent of transport representation.
 * Large buffers use ordered verified 64-KiB page SHA256 values. Raw/file
 * fallbacks derive the identical ID from fresh bytes. Textures/libraries keep
 * ordinary whole-blob SHA256; source identities and versions remain separate. */
#ifndef BEDROCK_NATIVE_CONTENT_IDENTITY_H
#define BEDROCK_NATIVE_CONTENT_IDENTITY_H
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdint.h>
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
static inline NSData *ffst_buffer_content_id(const void *bytes,size_t length) {
    if(!bytes||!length||length>FFST_CONTENT_BUFFER_MAX_BYTES)return nil;
    if(length<FFST_CONTENT_PAGE_MIN_BYTES){uint8_t digest[32];CC_SHA256(bytes,(CC_LONG)length,digest);return [NSData dataWithBytes:digest length:32];}
    uint8_t digests[FFST_CONTENT_PAGE_LIMIT*32];size_t count=(length+FFST_CONTENT_PAGE_BYTES-1)/FFST_CONTENT_PAGE_BYTES;
    for(size_t i=0;i<count;++i){size_t offset=i*FFST_CONTENT_PAGE_BYTES,size=MIN((size_t)FFST_CONTENT_PAGE_BYTES,length-offset);
        CC_SHA256((const uint8_t *)bytes+offset,(CC_LONG)size,digests+i*32);}
    return ffst_verified_pages_content_id(digests,count,length);
}
#endif
