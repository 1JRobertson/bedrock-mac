/* Shared, exact name algorithm from shared_texture_pass_capture.m. */
#ifndef FF_PRIVATE_LIBRARY_HASH_NAME_H
#define FF_PRIVATE_LIBRARY_HASH_NAME_H
#import <Foundation/Foundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
static NSString *ff_private_library_name(NSData *data) {
    unsigned char hash[CC_SHA256_DIGEST_LENGTH];char text[CC_SHA256_DIGEST_LENGTH*2+1];
    CC_SHA256(data.bytes,(CC_LONG)data.length,hash);
    for(unsigned i=0;i<CC_SHA256_DIGEST_LENGTH;++i)snprintf(text+2*i,3,"%02x",hash[i]);
    return [NSString stringWithFormat:@"pass-lib-%s.metallib",text];
}
#endif
