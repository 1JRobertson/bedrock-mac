#import "native_session_execute.h"
#import <CoreFoundation/CoreFoundation.h>
#include <string.h>
#if !__has_feature(objc_arc)
#error native_session_payload.m requires ARC
#endif

static BOOL chunk_integer(id object,uint64_t maximum,uint64_t *out) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType],*text=[[object stringValue] UTF8String];
    if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0])||!text||!*text||strlen(text)>20)return NO;
    uint64_t value=0;for(const char *p=text;*p;++p){if(*p<'0'||*p>'9')return NO;unsigned digit=(unsigned)(*p-'0');
        if(digit>maximum||value>(maximum-digit)/10)return NO;value=value*10+digit;}*out=value;return YES;
}
static id chunk_failure(NSString **failure,NSString *message) {if(failure)*failure=message;return nil;}

@implementation FFSTNativeChunkRequest
+ (instancetype)requestWithRecords:(NSData *)source serial:(uint64_t)serial
    retainedBytes:(size_t)bytes payloads:(id<FFSTNativeFramePayloadProvider>)payloads
    retiredRoots:(NSArray<NSDictionary *> *)retiredRoots failure:(NSString **)failure {
    if(failure)*failure=nil;
    if(![source isKindOfClass:[NSData class]]||!source.length||source.length%sizeof(ffs_record)||
       source.length/sizeof(ffs_record)>FFS_MAX_RECORDS||!serial||!payloads||
       ![payloads respondsToSelector:@selector(renderPayload:stream:frame:failure:)]||bytes<source.length||bytes>FFST_NATIVE_FRAME_MAX_BYTES)
        return chunk_failure(failure,@"Invalid native chunk ownership or reservation");
    NSData *records=[NSData dataWithBytes:source.bytes length:source.length];size_t count=records.length/sizeof(ffs_record);
    ffs_record first,last;memcpy(&first,records.bytes,sizeof(first));memcpy(&last,(const uint8_t *)records.bytes+(count-1)*sizeof(last),sizeof(last));
    BOOL begins=first.kind==FFS_FRAME_BEGIN,ends=last.kind==FFS_FRAME_END;
    if(count<(size_t)(2+begins+ends)||!first.stream||!first.frame||!first.sequence||
       (!begins&&first.kind!=FFS_CHUNK_BEGIN)||(!ends&&last.kind!=FFS_CHUNK_END))
        return chunk_failure(failure,@"Native chunk requires its original ledger boundaries");
    uint64_t digest=UINT64_C(14695981039346656037),sequence=first.sequence,chunk=first.chunk;
    BOOL inChunk=NO,finished=NO;unsigned starts=0,finishes=0;
    for(size_t i=0;i<count;++i){ffs_record r;memcpy(&r,(const uint8_t *)records.bytes+i*sizeof(r),sizeof(r));
        if(r.magic!=FFS_MAGIC||r.version!=FFS_VERSION||r.bytes!=sizeof(r)||r.stream!=first.stream||r.frame!=first.frame||
           r.chunk!=chunk||r.sequence!=sequence||sequence==UINT64_MAX||
           r.flags&~(FFS_UNSUPPORTED|FFS_EXTERNAL|FFS_READ|FFS_WRITE|FFS_ATTACHMENT|FFS_PAYLOAD)||
           (r.flags&FFS_UNSUPPORTED)||r.kind==FFS_REJECT||r.kind==FFS_RESOURCE_UNRESOLVED)
            return chunk_failure(failure,@"Native chunk has unsupported or discontinuous records");
        if(r.kind==FFS_FRAME_BEGIN){if(i||!begins)return chunk_failure(failure,@"Duplicate native frame begin");}
        else if(r.kind==FFS_CHUNK_BEGIN){if(inChunk||finished||++starts!=1)return chunk_failure(failure,@"Duplicate native chunk begin");inChunk=YES;}
        else if(r.kind==FFS_CHUNK_END){if(!inChunk||++finishes!=1)return chunk_failure(failure,@"Invalid native chunk end");inChunk=NO;finished=YES;}
        else if(r.kind==FFS_FRAME_END){if(i+1!=count||!ends||!finished)return chunk_failure(failure,@"Invalid native frame end");}
        else if(!inChunk||r.kind<FFS_ENCODER_BEGIN||r.kind>FFS_ENCODER_END)
            return chunk_failure(failure,@"Record outside native chunk");
        if(r.kind==FFS_ENCODER_BEGIN&&r.data[0]!=FFS_NULL&&r.data[0]!=FFS_RENDER&&r.data[0]!=FFS_CLEAR&&r.data[0]!=FFS_RESOLVE&&
           r.data[0]!=FFS_BLIT&&r.data[0]!=FFS_TIMESTAMP&&r.data[0]!=FFS_SIGNAL_EVENT&&r.data[0]!=FFS_PRESENT_ENCODER)
            return chunk_failure(failure,@"Native chunk encoder category is unsupported");
        digest=ffs_digest(digest,&r);++sequence;
    }
    if(starts!=1||finishes!=1||inChunk)return chunk_failure(failure,@"Native chunk is incomplete");
    if(retiredRoots&&(![retiredRoots isKindOfClass:[NSArray class]]||retiredRoots.count>FFS_MAX_RESOURCES))
        return chunk_failure(failure,@"Native retirement list is invalid");
    NSMutableArray *retirements=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(id entry in retiredRoots){uint64_t kind,root,generation,lastUse;
        if(![entry isKindOfClass:[NSDictionary class]]||[entry count]!=4||!chunk_integer(entry[@"kind"],FFS_TEXTURE,&kind)||!kind||
           !chunk_integer(entry[@"root"],UINT64_MAX,&root)||!root||!chunk_integer(entry[@"allocation_generation"],UINT64_MAX,&generation)||!generation||
           !chunk_integer(entry[@"last_use_serial"],serial,&lastUse)||!lastUse)
            return chunk_failure(failure,@"Native retirement identity is invalid");
        NSString *key=[NSString stringWithFormat:@"%llu:%llu:%llu",(unsigned long long)kind,(unsigned long long)root,(unsigned long long)generation];
        if([seen containsObject:key])return chunk_failure(failure,@"Duplicate native retirement identity");
        [seen addObject:key];[retirements addObject:@{@"kind":@(kind),@"root":@(root),@"allocation_generation":@(generation),@"last_use_serial":@(lastUse)}];
    }
    FFSTNativeChunkRequest *result=[self new];result->_serial=serial;result->_streamID=first.stream;result->_frameID=first.frame;
    result->_chunkID=chunk;result->_firstSequence=first.sequence;result->_nextSequence=sequence;result->_recordDigest=digest;
    result->_retainedBytes=bytes;result->_beginsFrame=begins;result->_endsFrame=ends;result->_records=records;result->_payloads=payloads;
    result->_retiredRoots=[retirements copy];return result;
}
@end
