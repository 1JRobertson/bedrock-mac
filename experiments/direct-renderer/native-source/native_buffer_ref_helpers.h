/* Private receiver-only opt-in helpers; no public ABI or default behavior. */
#ifndef BEDROCK_NATIVE_BUFFER_REF_HELPERS_H
#define BEDROCK_NATIVE_BUFFER_REF_HELPERS_H
#import <Foundation/Foundation.h>
#include "vertex_resources.h"
#include "native_buffer_ref.h"
#include <stdlib.h>
#include <string.h>

static inline __attribute__((unused)) BOOL ff_native_buffer_ref_enabled(void) {
    const char *value=getenv("BEDROCK_NATIVE_BUFFER_REF_EXPERIMENT");
    return value&&!strcmp(value,"1");
}
/* Only the producer's canonical, bounded, one-based snapshot leaf. */
static inline __attribute__((unused)) NSUInteger ff_native_buffer_ref_index(NSString *name) {
    if(![name isKindOfClass:[NSString class]]||![name hasPrefix:@"cut-buffer-"]||
       ![name hasSuffix:@".nref"])return 0;
    const NSUInteger prefix=11,suffix=5;
    if(name.length<prefix+2+suffix||name.length>prefix+5+suffix)return 0;
    uint64_t value=0;
    for(NSUInteger i=prefix;i<name.length-suffix;++i){unichar c=[name characterAtIndex:i];
        if(c<'0'||c>'9')return 0;value=value*10+(unsigned)(c-'0');
        if(value>FF_DRAW_RESOURCE_LIMIT)return 0;}
    return value&&[name isEqualToString:[NSString stringWithFormat:@"cut-buffer-%02llu.nref",(unsigned long long)value]]?(NSUInteger)value:0;
}
static inline __attribute__((unused)) BOOL ff_native_buffer_ref_valid(ff_native_buffer_ref ref) {
    return ref.magic==FF_NATIVE_BUFFER_REF_MAGIC&&ref.version==FF_NATIVE_BUFFER_REF_VERSION&&
        ref.stream&&ref.frame&&ref.chunk&&ref.payload&&ref.snapshot_id&&
        ref.snapshot_id<=FF_DRAW_RESOURCE_LIMIT&&ref.root&&ref.generation&&
        ref.input_version&&ref.input_version<UINT64_MAX&&ref.length&&
        ref.length<=FF_VERTEX_BYTES_LIMIT&&ref.offset<=UINT64_MAX-ref.length;
}
#endif
