/* Immutable CPU ownership and ledger validation. No GPU completion is inferred. */
#import "native_frame_execute.h"
#import "vertex_resources.h"
#import "native_owned_blobs.h"
#import "native_content_identity.h"
#import "native_metadata_sidecar.h"
#include <CommonCrypto/CommonDigest.h>
#include <fcntl.h>
#include <stdio.h>
#include <math.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error native_frame_payload.m requires ARC
#endif


/* Fixed generated leaf names only. Memory payloads are owned byte snapshots,
 * not filesystem identities: no uid/mode claims or descriptor fallback. */
static NSUInteger payload_indexed_blob(NSString *name,NSString *prefix,unsigned maximum) {
    if(![name hasPrefix:prefix]||![name hasSuffix:@".bin"]||name.length<prefix.length+6)return 0;
    NSUInteger digits=name.length-prefix.length-4;unsigned width=2;
    for(unsigned remaining=maximum;remaining>=100;remaining/=10)++width;
    if(digits<2||digits>width)return 0;
    unsigned index=0;
    for(NSUInteger i=0;i<digits;++i){unichar c=[name characterAtIndex:prefix.length+i];
        if(c<'0'||c>'9')return 0;unsigned digit=(unsigned)(c-'0');
        if(digit>maximum||index>(maximum-digit)/10)return 0;index=index*10+digit;}
    return index&&index<=maximum&&[name isEqualToString:[NSString stringWithFormat:@"%@%02u.bin",prefix,index]];
}
static NSUInteger payload_blob_limit(NSString *name) {
    if(![name isKindOfClass:[NSString class]]||!name.length||name.length>82)return 0;
    if([name isEqualToString:@"replay.json"]||[name isEqualToString:@"replay-template.json"])return 2u*1024u*1024u;
    if([name isEqualToString:@"bindings.json"]||[name isEqualToString:@"draw-resource-cut.json"])return 8u*1024u*1024u;
    if([name isEqualToString:@"draw-plan.bin"]||[name isEqualToString:@"draw-resource-cut.bin"]||
       [name isEqualToString:@"bindings.bin"])return FFMD_MAX_BYTES;
    if(payload_indexed_blob(name,@"cut-buffer-",FF_DRAW_RESOURCE_LIMIT)||payload_indexed_blob(name,@"cut-texture-",FF_TEXTURE_RESOURCE_LIMIT)||
       payload_indexed_blob(name,@"operation-buffer-",FFS_MAX_RESOURCES)||
       payload_indexed_blob(name,@"operation-texture-",FFS_MAX_RESOURCES))return 32u*1024u*1024u;
    if(name.length!=82||![name hasPrefix:@"pass-lib-"]||![name hasSuffix:@".metallib"])return 0;
    for(NSUInteger i=9;i<73;++i){unichar c=[name characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return 0;}
    return 8u*1024u*1024u;
}
static NSDictionary<NSString *,NSData *> *payload_blob_snapshot(id source) {
    if(![source isKindOfClass:[NSDictionary class]]||[source count]>8192)return nil;
    NSMutableDictionary<NSString *,NSData *> *result=[NSMutableDictionary dictionary];NSUInteger total=0;
    NSMutableArray<NSArray *> *entries=[NSMutableArray arrayWithCapacity:[source count]];
    /* Validate the complete metadata budget before touching any source bytes.
     * Oversized mmap payloads must not churn allocations on their way to reject. */
    for(id rawKey in source){
        if(![rawKey isKindOfClass:[NSString class]])return nil;
        NSString *name=[rawKey copy];NSUInteger maximum=payload_blob_limit(name);id value=source[rawKey];
        if(!maximum||![value isKindOfClass:[NSData class]])return nil;
        NSUInteger length=[value length];
        if(!length||length>maximum||length>64u*1024u*1024u-total)return nil;
        [entries addObject:@[name,value,@(length)]];total+=length;
    }
    for(NSArray *entry in entries){
        NSString *name=entry[0];NSData *value=entry[1];NSUInteger length=[entry[2] unsignedIntegerValue];
        if(value.length!=length)return nil;
        /* NSData wrappers may borrow an mmap slot: force an actual owned copy,
         * even when the wrapper's Objective-C interface is immutable. */
        NSData *data=[[NSData alloc]initWithBytes:value.bytes length:length];if(!data||value.length!=length)return nil;
        if([name hasPrefix:@"pass-lib-"]){unsigned char digest[CC_SHA256_DIGEST_LENGTH];char text[65];
            CC_SHA256(data.bytes,(CC_LONG)data.length,digest);
            for(unsigned i=0;i<32;++i)snprintf(text+2*i,3,"%02x",digest[i]);
            if(![name isEqualToString:[NSString stringWithFormat:@"pass-lib-%s.metallib",text]])return nil;}
        result[name]=data;
    }
    return [result copy];
}

static const NSUInteger FFSTManifestBytes = 2u * 1024u * 1024u;
static const NSUInteger FFSTBindingsBytes = 8u * 1024u * 1024u;

static BOOL payload_fail(NSString **failure, NSString *message) {
    if (failure) *failure = message;
    return NO;
}

/* A lower bound on serialized bytes bounds traversal before serialization.
 * The final encoded-byte check also accounts for JSON escaping and numbers. */
static BOOL json_spend(NSUInteger *remaining, NSUInteger bytes) {
    if (bytes > *remaining) return NO;
    *remaining -= bytes;
    return YES;
}

static BOOL bounded_json(id value, NSUInteger *remaining, unsigned depth,
    NSHashTable *ancestors) {
    if (depth > 64) return NO;
    if (value == [NSNull null]) return json_spend(remaining, 4);
    if ([value isKindOfClass:[NSString class]]) {
        if ([value length] > *remaining) return NO;
        NSUInteger bytes = [value lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
        return json_spend(remaining, 2) && json_spend(remaining, bytes);
    }
    if ([value isKindOfClass:[NSNumber class]])
        return isfinite([value doubleValue]) && json_spend(remaining, 1);
    BOOL dictionary = [value isKindOfClass:[NSDictionary class]];
    if (!dictionary && ![value isKindOfClass:[NSArray class]]) return NO;
    if ([ancestors containsObject:value] || !json_spend(remaining, 2)) return NO;
    NSUInteger count = [value count];
    if (count && !json_spend(remaining, count - 1)) return NO;
    [ancestors addObject:value];
    BOOL valid = YES;
    for (id item in value) {
        if (dictionary) {
            if (![item isKindOfClass:[NSString class]] ||
                !bounded_json(item, remaining, depth + 1, ancestors) ||
                !json_spend(remaining, 1) ||
                !bounded_json(value[item], remaining, depth + 1, ancestors)) {
                valid = NO; break;
            }
        } else if (!bounded_json(item, remaining, depth + 1, ancestors)) {
            valid = NO; break;
        }
    }
    [ancestors removeObject:value];
    return valid;
}

/* Only for objects freshly produced by NSJSONSerialization options:0. Their
 * classes, string keys and acyclicity are guaranteed by parsing. For UTF8,
 * the bounded source bytes dominate bounded_json's lower serialized-byte
 * estimate, including escaped Unicode and duplicate keys. Keep the two checks
 * not implied by parsing/byte bounds: our depth64 policy and finite numbers.
 * UTF16/32 dictionary syntax necessarily contains NUL bytes; conservatively
 * retain the original budget walk for such encodings. */
static BOOL parsed_json_depth_numbers(CFTypeRef value,unsigned depth);
typedef struct {unsigned depth;BOOL valid;} FFSTParsedJSONContext;
static void parsed_json_dictionary_value(const void *key,const void *value,void *opaque) {
    (void)key;FFSTParsedJSONContext *context=opaque;
    if(context->valid)context->valid=parsed_json_depth_numbers(value,context->depth);
}
static BOOL parsed_json_depth_numbers(CFTypeRef value,unsigned depth) {
    if(depth>64)return NO;CFTypeID type=CFGetTypeID(value);
    if(type==CFDictionaryGetTypeID()){
        CFDictionaryRef dictionary=(CFDictionaryRef)value;
        if(depth==64&&CFDictionaryGetCount(dictionary))return NO; /* keys also consume one level */
        FFSTParsedJSONContext context={depth+1,YES};
        CFDictionaryApplyFunction(dictionary,parsed_json_dictionary_value,&context);return context.valid;
    }
    if(type==CFArrayGetTypeID()){
        CFArrayRef array=(CFArrayRef)value;CFIndex count=CFArrayGetCount(array);
        for(CFIndex i=0;i<count;++i)if(!parsed_json_depth_numbers(CFArrayGetValueAtIndex(array,i),depth+1))return NO;
        return YES;
    }
    if(type==CFNumberGetTypeID())return isfinite([(__bridge NSNumber *)value doubleValue]);
    return type==CFStringGetTypeID()||type==CFBooleanGetTypeID()||type==CFNullGetTypeID();
}
static BOOL bounded_parsed_json(NSDictionary *parsed,NSData *wire,NSUInteger maximum) {
    if(!memchr(wire.bytes,0,wire.length))return parsed_json_depth_numbers((__bridge CFTypeRef)parsed,0);
    NSUInteger remaining=maximum;NSHashTable *ancestors=[NSHashTable hashTableWithOptions:
        NSPointerFunctionsStrongMemory|NSPointerFunctionsObjectPointerPersonality];
    return bounded_json(parsed,&remaining,0,ancestors);
}

static NSDictionary *immutable_json_dictionary(id source, NSUInteger maximum) {
    if (![source isKindOfClass:[NSDictionary class]]) return nil;
    @try {
        NSUInteger remaining = maximum;
        NSHashTable *ancestors = [NSHashTable hashTableWithOptions:
            NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality];
        if (!bounded_json(source, &remaining, 0, ancestors)) return nil;
        NSData *wire = [NSJSONSerialization dataWithJSONObject:source options:0 error:nil];
        if (!wire || wire.length > maximum) return nil;
        id copy = [NSJSONSerialization JSONObjectWithData:wire options:0 error:nil];
        return [copy isKindOfClass:[NSDictionary class]] ? copy : nil;
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

@interface FFSTOwnedBlobs ()
- (instancetype)initDecoderBlobs:(NSDictionary *)blobs digests:(NSDictionary *)digests pageIDs:(NSDictionary *)pageIDs
    parsedTemplate:(NSDictionary *)parsedTemplate failure:(NSString **)failure;
@end
@implementation FFSTOwnedBlobs {
    NSDictionary<NSString *,NSDictionary *> *_json;
    NSDictionary<NSValue *,NSArray *> *_pointers;
}
- (instancetype)initDecoderBlobs:(NSDictionary *)blobs digests:(NSDictionary *)digests pageIDs:(NSDictionary *)pageIDs
    parsedTemplate:(NSDictionary *)parsedTemplate failure:(NSString **)failure {
    if(![blobs isKindOfClass:[NSDictionary class]]||![digests isKindOfClass:[NSDictionary class]]||
       ![pageIDs isKindOfClass:[NSDictionary class]]||blobs.count>8192||digests.count+pageIDs.count!=blobs.count)return nil;
    self=[super init];if(!self)return nil;
    NSMutableDictionary *owned=[NSMutableDictionary new],*json=[NSMutableDictionary new],*pointers=[NSMutableDictionary new];NSUInteger total=0;
    for(id key in blobs){NSUInteger maximum=payload_blob_limit(key);NSData *data=blobs[key],*digest=digests[key],*pageID=pageIDs[key];
        if(!maximum||![data isKindOfClass:[NSData class]]||[data isKindOfClass:[NSMutableData class]]||!data.length||
           data.length>maximum||data.length>64u*1024u*1024u-total||
           (pageID?digest||![pageID isKindOfClass:[NSData class]]||pageID.length!=32||data.length<FFST_CONTENT_PAGE_MIN_BYTES||
               !(payload_indexed_blob(key,@"cut-buffer-",FF_DRAW_RESOURCE_LIMIT)||payload_indexed_blob(key,@"operation-buffer-",FFS_MAX_RESOURCES)):
               ![digest isKindOfClass:[NSData class]]||digest.length!=32))
            return nil;
        total+=data.length;NSString *name=[key copy];NSData *sha=digest?[[NSData alloc] initWithBytes:digest.bytes length:32]:nil;
        NSData *contentID=pageID?[[NSData alloc] initWithBytes:pageID.bytes length:32]:nil;
        if([name hasPrefix:@"pass-lib-"]){char hex[65];for(unsigned i=0;i<32;++i)snprintf(hex+2*i,3,"%02x",((const uint8_t *)sha.bytes)[i]);
            if(![name isEqual:[NSString stringWithFormat:@"pass-lib-%s.metallib",hex]])return nil;}
        if([name hasSuffix:@".json"]){id parsed=[name isEqualToString:@"replay-template.json"]?parsedTemplate:nil;
            if(!parsed)parsed=[NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            BOOL memoized=parsedTemplate&&[name isEqualToString:@"replay-template.json"];
            if(![parsed isKindOfClass:[NSDictionary class]]||(!memoized&&
               !bounded_parsed_json(parsed,data,maximum)))return nil;json[name]=parsed;}
        NSValue *pointer=[NSValue valueWithPointer:data.bytes];NSArray *prior=pointers[pointer];
        if(prior&&([prior[0] length]!=data.length||(sha&&prior[1]!=[NSNull null]&&![prior[1] isEqual:sha])||
           (contentID&&prior[2]!=[NSNull null]&&![prior[2] isEqual:contentID])))return nil;
        pointers[pointer]=@[data,sha?:prior[1]?:[NSNull null],contentID?:prior[2]?:[NSNull null]];owned[name]=data;
    }
    _blobs=[owned copy];_json=[json copy];_pointers=[pointers copy];(void)failure;return self;
}
- (NSDictionary *)jsonDictionary:(NSString *)name {return _json[name];}
- (NSData *)verifiedDigestForBytes:(const void *)bytes length:(NSUInteger)length {
    if(!bytes||!length)return nil;NSArray *entry=_pointers[[NSValue valueWithPointer:bytes]];
    NSData *owner=entry[0];id digest=entry[1];return owner&&owner.bytes==bytes&&owner.length==length&&[digest isKindOfClass:[NSData class]]?digest:nil;
}
- (NSData *)verifiedBufferIDForBytes:(const void *)bytes length:(NSUInteger)length {
    if(!bytes||!length)return nil;NSArray *entry=_pointers[[NSValue valueWithPointer:bytes]];
    NSData *owner=entry[0];id identity=entry[2];return owner&&owner.bytes==bytes&&owner.length==length&&[identity isKindOfClass:[NSData class]]?identity:nil;
}
- (NSData<FFSTSharedSnapshotMemory> *)verifiedSharedSnapshotForBytes:(const void *)bytes length:(NSUInteger)length {
    if(!bytes||!length)return nil;NSArray *entry=_pointers[[NSValue valueWithPointer:bytes]];
    NSData *owner=entry[0];return owner&&owner.bytes==bytes&&owner.length==length&&
        [owner conformsToProtocol:@protocol(FFSTSharedSnapshotMemory)]?(id)owner:nil;
}
@end
FFSTOwnedBlobs *ffst_owned_blobs_from_decoder(NSDictionary<NSString *,NSData *> *blobs,NSDictionary<NSString *,NSData *> *digests,NSString **failure) {
    return ffst_owned_blobs_with_page_ids_from_decoder(blobs,digests,@{},failure);
}
FFSTOwnedBlobs *ffst_owned_blobs_with_page_ids_from_decoder(NSDictionary<NSString *,NSData *> *blobs,NSDictionary<NSString *,NSData *> *digests,NSDictionary<NSString *,NSData *> *pageIDs,NSString **failure) {
    return ffst_owned_blobs_with_template_from_decoder(blobs,digests,pageIDs,nil,failure);
}
FFSTOwnedBlobs *ffst_owned_blobs_with_template_from_decoder(NSDictionary<NSString *,NSData *> *blobs,NSDictionary<NSString *,NSData *> *digests,NSDictionary<NSString *,NSData *> *pageIDs,NSDictionary *parsedTemplate,NSString **failure) {
    if(failure)*failure=nil;
    @try {FFSTOwnedBlobs *owned=[[FFSTOwnedBlobs alloc] initDecoderBlobs:blobs digests:digests pageIDs:pageIDs parsedTemplate:parsedTemplate failure:failure];
        if(!owned)payload_fail(failure,@"Invalid owned immutable blob provenance, names, digests or bounds");return owned;
    }@catch(__unused NSException *exception){payload_fail(failure,@"Malformed owned immutable blobs");return nil;}
}
@interface FFSTNativeFramePassPayload ()
@property(nonatomic,strong,readwrite) FFSTOwnedBlobs *ownedBlobs;
@end
@interface FFSTNativeFrameOperationPayload ()
@property(nonatomic,strong,readwrite) FFSTOwnedBlobs *ownedBlobs;
@end

@implementation FFSTNativeFramePassPayload
static BOOL payload_positive_u64(id object,uint64_t *value) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType],*digits=[[object stringValue] UTF8String];
    if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0])||!digits||!*digits)return NO;
    uint64_t result=0;
    for(const char *p=digits;*p;++p){if(*p<'0'||*p>'9'||result>(UINT64_MAX-(unsigned)(*p-'0'))/10)return NO;
        result=result*10+(unsigned)(*p-'0');}
    if(!result)return NO;*value=result;return YES;
}
static BOOL payload_u32(id object,uint32_t *value) {
    if(![object isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)object)==CFBooleanGetTypeID())return NO;
    const char *type=[object objCType],*digits=[[object stringValue] UTF8String];
    if(!type||!type[0]||type[1]||!strchr("cCsSiIlLqQ",type[0])||!digits||!*digits)return NO;
    uint64_t result=0;for(const char *p=digits;*p;++p){if(*p<'0'||*p>'9'||result>(UINT32_MAX-(unsigned)(*p-'0'))/10)return NO;
        result=result*10+(unsigned)(*p-'0');}
    *value=(uint32_t)result;return YES;
}
static NSDictionary *payload_expand_replay_v3(FFSTOwnedBlobs *owned,NSDictionary *delta,NSString **failure) {
    NSSet *keys=[NSSet setWithArray:@[@"format",@"version",@"complete_pass",@"template_sha256",@"indexed_overrides",
        @"cut_id",@"resource_cut_id",@"shared_attachment_cut"]];
    if(![[NSSet setWithArray:delta.allKeys] isEqual:keys]||
       ![delta[@"format"] isEqual:@"bedrock-native-pass-replay"]||![delta[@"version"] isEqual:@3]||
       CFGetTypeID((__bridge CFTypeRef)(delta[@"complete_pass"]?:@0))!=CFBooleanGetTypeID()||
       ![delta[@"complete_pass"] boolValue]){payload_fail(failure,@"Invalid replay v3 delta envelope");return nil;}
    NSString *hex=delta[@"template_sha256"];
    NSData *bytes=owned.blobs[@"replay-template.json"];
    NSData *digest=bytes?[owned verifiedDigestForBytes:bytes.bytes length:bytes.length]:nil;
    if(![hex isKindOfClass:[NSString class]]||hex.length!=64||digest.length!=32){
        payload_fail(failure,@"Replay v3 template digest is absent");return nil;}
    const uint8_t *raw=digest.bytes;
    for(NSUInteger i=0;i<32;++i){char expected[3];snprintf(expected,sizeof(expected),"%02x",raw[i]);
        if([hex characterAtIndex:2*i]!=(unichar)expected[0]||[hex characterAtIndex:2*i+1]!=(unichar)expected[1]){
            payload_fail(failure,@"Replay v3 template digest differs");return nil;}}
    NSDictionary *base=[owned jsonDictionary:@"replay-template.json"];
    NSArray *draws=base[@"draws"],*overrides=delta[@"indexed_overrides"];
    if(![base[@"format"] isEqual:@"bedrock-native-pass-replay"]||![base[@"version"] isEqual:@2]||
       CFGetTypeID((__bridge CFTypeRef)(base[@"complete_pass"]?:@0))!=CFBooleanGetTypeID()||
       ![base[@"complete_pass"] boolValue]||![draws isKindOfClass:[NSArray class]]||
       ![overrides isKindOfClass:[NSArray class]]||draws.count!=overrides.count||draws.count>FFST_PASS_DRAW_LIMIT){
        payload_fail(failure,@"Replay v3 template or draw coverage differs");return nil;}
    uint64_t baseCut=0,cut=0,shared=0,baseShared=0;
    id sharedObject=delta[@"shared_attachment_cut"],baseSharedObject=base[@"shared_attachment_cut"];
    if(!payload_positive_u64(base[@"cut_id"],&baseCut)||!payload_positive_u64(delta[@"cut_id"],&cut)||
       ![base[@"resource_cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)baseCut]]||
       ![delta[@"resource_cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)cut]]||
       (baseSharedObject&&(!payload_positive_u64(baseSharedObject,&baseShared)||baseShared!=baseCut))||
       (baseSharedObject?( !payload_positive_u64(sharedObject,&shared)||shared!=cut):sharedObject!=[NSNull null])){
        payload_fail(failure,@"Replay v3 capture identity differs");return nil;}
    NSMutableArray *expanded=[NSMutableArray arrayWithCapacity:draws.count];
    for(NSUInteger i=0;i<draws.count;++i){
        if(![draws[i] isKindOfClass:[NSDictionary class]]||
           (overrides[i]!=[NSNull null]&&![overrides[i] isKindOfClass:[NSDictionary class]])){
            payload_fail(failure,@"Replay v3 indexed override is malformed");return nil;}
        NSMutableDictionary *draw=[draws[i] mutableCopy];
        if(overrides[i]==[NSNull null])[draw removeObjectForKey:@"indexed"];
        else draw[@"indexed"]=overrides[i];
        [expanded addObject:[draw copy]];
    }
    NSMutableDictionary *manifest=[base mutableCopy];manifest[@"draws"]=[expanded copy];
    manifest[@"cut_id"]=delta[@"cut_id"];manifest[@"resource_cut_id"]=delta[@"resource_cut_id"];
    if(baseSharedObject)manifest[@"shared_attachment_cut"]=sharedObject;
    return [manifest copy];
}
static BOOL payload_verified_sha(FFSTOwnedBlobs *owned,NSString *name,NSString *hex,NSData **bytes,NSData **digest) {
    NSData *data=owned.blobs[name];NSData *sha=data?[owned verifiedDigestForBytes:data.bytes length:data.length]:nil;
    if(![hex isKindOfClass:[NSString class]]||hex.length!=64||sha.length!=32)return NO;
    const uint8_t *raw=sha.bytes;
    for(unsigned i=0;i<32;++i){char pair[3];snprintf(pair,sizeof(pair),"%02x",raw[i]);
        if([hex characterAtIndex:2*i]!=(unichar)pair[0]||[hex characterAtIndex:2*i+1]!=(unichar)pair[1])return NO;}
    if(bytes)*bytes=data;if(digest)*digest=sha;return YES;
}
static NSDictionary *payload_expand_typed_sidecar(FFSTOwnedBlobs *owned,NSDictionary *graph,
    NSDictionary *envelope,NSDictionary *manifest,NSString **failure) {
    NSSet *graphKeys=[NSSet setWithArray:@[@"format",@"version",@"cut_id",@"complete_pass",@"wire_blob",
        @"wire_sha256",@"plan_blob",@"plan_sha256"]];
    NSSet *sidecarKeys=[NSSet setWithArray:@[@"format",@"version",@"stream",@"frame",@"chunk",
        @"encoder",@"category",@"payload_id",@"pass_manifest",@"resource_manifest",
        @"wire_blob",@"wire_sha256",@"plan_sha256"]];
    if(![[NSSet setWithArray:graph.allKeys] isEqual:graphKeys]||
       ![[NSSet setWithArray:envelope.allKeys] isEqual:sidecarKeys]||
       ![graph[@"format"] isEqual:@"bedrock-draw-resource-cut"]||![graph[@"version"] isEqual:@3]||
       CFGetTypeID((__bridge CFTypeRef)(graph[@"complete_pass"]?:@0))!=CFBooleanGetTypeID()||
       ![graph[@"complete_pass"] boolValue]||
       ![graph[@"wire_blob"] isEqual:@"draw-resource-cut.bin"]||
       ![graph[@"plan_blob"] isEqual:@"draw-plan.bin"]||
       ![envelope[@"format"] isEqual:@"bedrock-native-frame-pass"]||
       ![envelope[@"version"] isEqual:@2]||
       ![envelope[@"pass_manifest"] isEqual:@"replay.json"]||
       ![envelope[@"resource_manifest"] isEqual:@"draw-resource-cut.json"]||
       ![envelope[@"wire_blob"] isEqual:@"bindings.bin"]||
       ![graph[@"plan_sha256"] isEqual:envelope[@"plan_sha256"]]||
       ![graph[@"cut_id"] isEqual:manifest[@"resource_cut_id"]]){
        payload_fail(failure,@"Typed pass envelopes differ or are malformed");return nil;}
    NSData *planBytes=nil,*graphBytes=nil,*sidecarBytes=nil,*planDigest=nil;
    if(!payload_verified_sha(owned,@"draw-plan.bin",graph[@"plan_sha256"],&planBytes,&planDigest)||
       !payload_verified_sha(owned,@"draw-resource-cut.bin",graph[@"wire_sha256"],&graphBytes,NULL)||
       !payload_verified_sha(owned,@"bindings.bin",envelope[@"wire_sha256"],&sidecarBytes,NULL)){
        payload_fail(failure,@"Typed pass blob digest differs from transport evidence");return nil;}
    ffmd_view plan,draws,sidecar;
    if(!ffmd_view_decode(planBytes.bytes,planBytes.length,FFMD_PLAN,&plan)||
       !ffmd_view_decode(graphBytes.bytes,graphBytes.length,FFMD_GRAPH,&draws)||
       !ffmd_view_decode(sidecarBytes.bytes,sidecarBytes.length,FFMD_SIDECAR,&sidecar)||
       memcmp(draws.header.plan_sha256,planDigest.bytes,32)||
       memcmp(sidecar.header.plan_sha256,planDigest.bytes,32)||
       draws.header.stream!=sidecar.header.stream||draws.header.frame!=sidecar.header.frame||
       draws.header.chunk!=sidecar.header.chunk||draws.header.payload_id!=sidecar.header.payload_id||
       draws.header.cut_id!=sidecar.header.cut_id||
       ![graph[@"cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)draws.header.cut_id]]){
        payload_fail(failure,@"Typed pass wire structure or identity is invalid");return nil;}
    const uint64_t identity[]={sidecar.header.stream,sidecar.header.frame,sidecar.header.chunk,sidecar.header.payload_id};
    NSArray *keys=@[@"stream",@"frame",@"chunk",@"payload_id"];
    for(unsigned i=0;i<4;++i){uint64_t declared=0;
        if(!payload_positive_u64(envelope[keys[i]],&declared)||declared!=identity[i]){
            payload_fail(failure,@"Typed pass envelope capture identity differs");return nil;}}
    uint64_t category=0;uint32_t encoder=0;
    if(!payload_positive_u64(envelope[@"category"],&category)||category!=FFS_RENDER||
       !payload_u32(envelope[@"encoder"],&encoder)){
        payload_fail(failure,@"Typed pass encoder identity is invalid");return nil;}
    (void)encoder;
    NSDictionary *rows=ffmd_sidecar_dictionary(&sidecar);
    if(!rows){payload_fail(failure,@"Typed pass resource sidecar is invalid");return nil;}
    NSMutableDictionary *expanded=[envelope mutableCopy];
    [expanded removeObjectsForKeys:@[@"wire_blob",@"wire_sha256",@"plan_sha256"]];
    expanded[@"version"]=@1;[expanded addEntriesFromDictionary:rows];return [expanded copy];
}
+ (instancetype)payloadWithOwnedBlobs:(FFSTOwnedBlobs *)owned failure:(NSString **)failure {
    if(failure)*failure=nil;
    NSDictionary *manifest=[owned jsonDictionary:@"replay.json"],*bindings=[owned jsonDictionary:@"bindings.json"];
    if([manifest[@"version"] isEqual:@3]){
        manifest=payload_expand_replay_v3(owned,manifest,failure);if(!manifest)return nil;}
    NSDictionary *graph=[owned jsonDictionary:@"draw-resource-cut.json"];
    BOOL typed=[graph[@"version"] isEqual:@3]||[bindings[@"version"] isEqual:@2];
    if(typed){if(![graph[@"version"] isEqual:@3]||![bindings[@"version"] isEqual:@2]){
            payload_fail(failure,@"Typed pass graph/sidecar versions differ");return nil;}
        bindings=payload_expand_typed_sidecar(owned,graph,bindings,manifest,failure);if(!bindings)return nil;}
    if(![manifest[@"format"] isEqual:@"bedrock-native-pass-replay"]||![manifest[@"version"] isEqual:@2]||
       CFGetTypeID((__bridge CFTypeRef)(manifest[@"complete_pass"]?:@0))!=CFBooleanGetTypeID()||![manifest[@"complete_pass"] boolValue]||
       ![bindings[@"format"] isEqual:@"bedrock-native-frame-pass"]||![bindings[@"version"] isEqual:@1]||
       ![bindings[@"pass_manifest"] isEqual:@"replay.json"]||![bindings[@"resource_manifest"] isEqual:@"draw-resource-cut.json"]||!owned.blobs[@"draw-resource-cut.json"]){
        payload_fail(failure,@"Owned pass metadata is incomplete or malformed");return nil;}
    FFSTNativeFramePassPayload *result=[[self alloc]init];result->_blobs=owned.blobs;result->_manifest=manifest;result->_bindings=bindings;result.ownedBlobs=owned;return result;
}
- (instancetype)init {
    self = [super init];
    if (self) _directory = -1;
    return self;
}
+ (instancetype)payloadWithDirectory:(int)directory manifest:(NSDictionary *)manifest
    bindings:(NSDictionary *)bindings failure:(NSString **)failure {
    if (failure) *failure = nil;
    if (directory < 0) {
        payload_fail(failure, @"Pass payload directory is invalid"); return nil;
    }
    int owned = fcntl(directory, F_DUPFD_CLOEXEC, 0);
    struct stat info;
    if (owned < 0 || fstat(owned, &info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 0777) != 0700) {
        if (owned >= 0) close(owned);
        payload_fail(failure, @"Pass payload directory must be private and owned"); return nil;
    }
    NSDictionary *manifestCopy = immutable_json_dictionary(manifest, FFSTManifestBytes);
    NSDictionary *bindingsCopy = immutable_json_dictionary(bindings, FFSTBindingsBytes);
    if (![manifestCopy[@"format"] isEqual:@"bedrock-native-pass-replay"] ||
        ![manifestCopy[@"version"] isEqual:@2] ||
        ![manifestCopy[@"complete_pass"] isKindOfClass:[NSNumber class]] ||
        CFGetTypeID((__bridge CFTypeRef)manifestCopy[@"complete_pass"]) != CFBooleanGetTypeID() ||
        ![manifestCopy[@"complete_pass"] boolValue]) {
        close(owned);
        payload_fail(failure, @"Pass payload requires a bounded complete v2 pass manifest"); return nil;
    }
    if (![bindingsCopy[@"format"] isEqual:@"bedrock-native-frame-pass"] ||
        ![bindingsCopy[@"version"] isEqual:@1] ||
        ![bindingsCopy[@"pass_manifest"] isEqual:@"replay.json"] ||
        ![bindingsCopy[@"resource_manifest"] isEqual:@"draw-resource-cut.json"]) {
        close(owned);
        payload_fail(failure, @"Pass payload requires a bounded frame-pass binding sidecar"); return nil;
    }
    FFSTNativeFramePassPayload *result = [[self alloc] init];
    if (!result) {
        close(owned); payload_fail(failure, @"Pass payload allocation failed"); return nil;
    }
    result->_directory = owned;
    result->_manifest = manifestCopy;
    result->_bindings = bindingsCopy;
    return result;
}
+ (instancetype)payloadWithBlobs:(NSDictionary<NSString *,NSData *> *)blobs
    manifest:(NSDictionary *)manifest bindings:(NSDictionary *)bindings failure:(NSString **)failure {
    if(failure)*failure=nil;
    @try {
        NSDictionary *manifestCopy=immutable_json_dictionary(manifest,FFSTManifestBytes);
        NSDictionary *bindingsCopy=immutable_json_dictionary(bindings,FFSTBindingsBytes);
        if(![manifestCopy[@"format"] isEqual:@"bedrock-native-pass-replay"]||![manifestCopy[@"version"] isEqual:@2]||
            ![manifestCopy[@"complete_pass"] isKindOfClass:[NSNumber class]]||
            CFGetTypeID((__bridge CFTypeRef)manifestCopy[@"complete_pass"])!=CFBooleanGetTypeID()||
            ![manifestCopy[@"complete_pass"] boolValue]){
            payload_fail(failure,@"Pass payload requires a bounded complete v2 pass manifest");return nil;}
        if(![bindingsCopy[@"format"] isEqual:@"bedrock-native-frame-pass"]||![bindingsCopy[@"version"] isEqual:@1]||
            ![bindingsCopy[@"pass_manifest"] isEqual:@"replay.json"]||
            ![bindingsCopy[@"resource_manifest"] isEqual:@"draw-resource-cut.json"]){
            payload_fail(failure,@"Pass payload requires a bounded frame-pass binding sidecar");return nil;}
        NSDictionary *owned=payload_blob_snapshot(blobs);
        if(!owned||!owned[@"draw-resource-cut.json"]){
            payload_fail(failure,@"Pass blobs require bounded immutable assets and a resource graph");return nil;}
        for(NSString *name in @[@"replay.json",@"bindings.json"]){
            if(!owned[name])continue;
            NSDictionary *json=[NSJSONSerialization JSONObjectWithData:owned[name] options:0 error:nil];
            if(![json isEqual:([name isEqual:@"replay.json"]?manifestCopy:bindingsCopy)]){
                payload_fail(failure,@"Pass blob metadata differs from its validated manifest");return nil;}
        }
        FFSTNativeFramePassPayload *result=[[self alloc]init];
        if(!result){payload_fail(failure,@"Pass payload allocation failed");return nil;}
        result->_directory=-1;result->_blobs=owned;result->_manifest=manifestCopy;result->_bindings=bindingsCopy;
        return result;
    }@catch(__unused NSException *exception){payload_fail(failure,@"Malformed immutable pass blobs");return nil;}
}
- (void)dealloc {
    if (_directory >= 0) close(_directory);
}
@end

@implementation FFSTNativeFrameOperationPayload
+ (instancetype)payloadWithOwnedBlobs:(FFSTOwnedBlobs *)owned failure:(NSString **)failure {
    if(failure)*failure=nil;
    NSDictionary *bindings=[owned jsonDictionary:@"bindings.json"];
    if(![bindings[@"format"] isEqual:@"bedrock-native-frame-operation"]||![bindings[@"version"] isEqual:@1]||
       ![bindings[@"resources"] isKindOfClass:[NSArray class]]||![bindings[@"command_types"] isKindOfClass:[NSArray class]]){
        payload_fail(failure,@"Owned operation metadata is malformed");return nil;}
    FFSTNativeFrameOperationPayload *result=[[self alloc]init];result->_blobs=owned.blobs;result->_bindings=bindings;result.ownedBlobs=owned;return result;
}
- (instancetype)init {
    self = [super init];
    if (self) _directory = -1;
    return self;
}
+ (instancetype)payloadWithDirectory:(int)directory bindings:(NSDictionary *)bindings
    failure:(NSString **)failure {
    if (failure) *failure = nil;
    int owned = directory >= 0 ? fcntl(directory, F_DUPFD_CLOEXEC, 0) : -1;
    struct stat info;
    if (owned < 0 || fstat(owned, &info) || !S_ISDIR(info.st_mode) ||
        info.st_uid != getuid() || (info.st_mode & 0777) != 0700) {
        if (owned >= 0) close(owned);
        payload_fail(failure, @"Operation payload directory must be private and owned"); return nil;
    }
    NSDictionary *copy = immutable_json_dictionary(bindings, FFSTBindingsBytes);
    if (![copy[@"format"] isEqual:@"bedrock-native-frame-operation"] ||
        ![copy[@"version"] isEqual:@1] ||
        ![copy[@"resources"] isKindOfClass:[NSArray class]] ||
        ![copy[@"command_types"] isKindOfClass:[NSArray class]]) {
        close(owned);
        payload_fail(failure, @"Invalid bounded operation binding sidecar"); return nil;
    }
    FFSTNativeFrameOperationPayload *result = [[self alloc] init];
    if (!result) {
        close(owned); payload_fail(failure, @"Operation payload allocation failed"); return nil;
    }
    result->_directory = owned;
    result->_bindings = copy;
    return result;
}
+ (instancetype)payloadWithBlobs:(NSDictionary<NSString *,NSData *> *)blobs
    bindings:(NSDictionary *)bindings failure:(NSString **)failure {
    if(failure)*failure=nil;
    @try {
        NSDictionary *copy=immutable_json_dictionary(bindings,FFSTBindingsBytes);
        if(![copy[@"format"] isEqual:@"bedrock-native-frame-operation"]||![copy[@"version"] isEqual:@1]||
            ![copy[@"resources"] isKindOfClass:[NSArray class]]||![copy[@"command_types"] isKindOfClass:[NSArray class]]){
            payload_fail(failure,@"Invalid bounded operation binding sidecar");return nil;}
        NSDictionary *owned=payload_blob_snapshot(blobs);
        if(!owned){payload_fail(failure,@"Operation blobs exceed immutable name or byte bounds");return nil;}
        if(owned[@"bindings.json"]){id json=[NSJSONSerialization JSONObjectWithData:owned[@"bindings.json"] options:0 error:nil];
            if(![json isEqual:copy]){payload_fail(failure,@"Operation blob metadata differs from its binding sidecar");return nil;}}
        FFSTNativeFrameOperationPayload *result=[[self alloc]init];
        if(!result){payload_fail(failure,@"Operation payload allocation failed");return nil;}
        result->_directory=-1;result->_blobs=owned;result->_bindings=copy;return result;
    }@catch(__unused NSException *exception){payload_fail(failure,@"Malformed immutable operation blobs");return nil;}
}
- (void)dealloc { if (_directory >= 0) close(_directory); }
@end

static uint32_t wire_u32(const uint8_t *bytes) {
    return (uint32_t)bytes[0] | (uint32_t)bytes[1] << 8 |
        (uint32_t)bytes[2] << 16 | (uint32_t)bytes[3] << 24;
}
static uint64_t wire_u64(const uint8_t *bytes) {
    return (uint64_t)wire_u32(bytes) | (uint64_t)wire_u32(bytes + 4) << 32;
}
static ffs_record decode_record(const uint8_t *bytes) {
    ffs_record record = {0};
    record.magic = wire_u64(bytes);
    record.version = wire_u32(bytes + 8); record.bytes = wire_u32(bytes + 12);
    record.kind = wire_u32(bytes + 16); record.flags = wire_u32(bytes + 20);
    record.stream = wire_u64(bytes + 24); record.sequence = wire_u64(bytes + 32);
    record.frame = wire_u64(bytes + 40); record.chunk = wire_u64(bytes + 48);
    record.encoder = wire_u32(bytes + 56); record.item = wire_u32(bytes + 60);
    for (unsigned i = 0; i < 12; ++i) record.data[i] = wire_u64(bytes + 64 + 8 * i);
    return record;
}

@implementation FFSTNativeFrameRequest
+ (instancetype)requestWithRecords:(NSData *)records firstSequence:(uint64_t)firstSequence
    retainedBytes:(size_t)bytes payloads:(id<FFSTNativeFramePayloadProvider>)payloads
    failure:(NSString **)failure {
    if (failure) *failure = nil;
    if (![records isKindOfClass:[NSData class]] || !records.length ||
        records.length % sizeof(ffs_record) || records.length / sizeof(ffs_record) > FFS_MAX_RECORDS ||
        !firstSequence || bytes < records.length || bytes > FFST_NATIVE_FRAME_MAX_BYTES ||
        ![payloads conformsToProtocol:@protocol(FFSTNativeFramePayloadProvider)] ||
        ![payloads respondsToSelector:@selector(renderPayload:stream:frame:failure:)]) {
        payload_fail(failure, @"Invalid native frame request bounds or provider"); return nil;
    }
    NSData *wire = [[NSData alloc] initWithBytes:records.bytes length:records.length];
    if (!wire) {
        payload_fail(failure, @"Native frame record copy failed"); return nil;
    }
    ffs_record first = decode_record(wire.bytes);
    if (!first.stream || !first.frame) {
        payload_fail(failure, @"Native frame identity must be nonzero"); return nil;
    }
    size_t count = wire.length / sizeof(ffs_record);
    ffs_collector *collector = ffs_create(first.stream, firstSequence, count);
    if (!collector) {
        payload_fail(failure, @"Native frame collector allocation failed"); return nil;
    }
    BOOL accepted = YES;
    const uint8_t *data = wire.bytes;
    for (size_t i = 0; i < count; ++i) {
        ffs_record record = decode_record(data + i * sizeof(ffs_record));
        if (!ffs_consume(collector, &record)) { accepted = NO; break; }
        if (record.kind == FFS_ENCODER_BEGIN && record.data[0] != FFS_NULL &&
            record.data[0] != FFS_RENDER && record.data[0] != FFS_CLEAR &&
            record.data[0] != FFS_RESOLVE && record.data[0] != FFS_BLIT &&
            record.data[0] != FFS_TIMESTAMP && record.data[0] != FFS_SIGNAL_EVENT &&
            record.data[0] != FFS_PRESENT_ENCODER) {
            accepted = NO; break;
        }
    }
    ffs_summary summary = ffs_inspect(collector);
    accepted = accepted && summary.status == FFS_COMPLETE && summary.records == count &&
        summary.stream == first.stream && summary.frame == first.frame &&
        summary.category_count[FFS_RENDER] + summary.category_count[FFS_CLEAR] +
            summary.category_count[FFS_RESOLVE] + summary.category_count[FFS_BLIT] +
            summary.category_count[FFS_TIMESTAMP] + summary.category_count[FFS_SIGNAL_EVENT] <= FFST_NATIVE_FRAME_MAX_PASSES;
    ffs_destroy(collector);
    if (!accepted) {
        payload_fail(failure, @"Native frame ledger is incomplete, unsupported or invalid"); return nil;
    }
    FFSTNativeFrameRequest *result = [[self alloc] init];
    if (!result) {
        payload_fail(failure, @"Native frame request allocation failed"); return nil;
    }
    result->_streamID = summary.stream; result->_frameID = summary.frame;
    result->_retainedBytes = bytes; result->_records = wire; result->_payloads = payloads;
    return result;
}
@end
