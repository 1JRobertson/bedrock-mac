#import "native_value_validation.h"
#import "native_chunk_payloads.h"
#import "shared_texture_executor.h"
#import "vertex_resources.h"
#import "native_owned_blobs.h"
#import "native_content_identity.h"
#import <CoreFoundation/CoreFoundation.h>
#include <CommonCrypto/CommonDigest.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !__has_feature(objc_arc)
#error native_chunk_payloads.m requires ARC
#endif
static id chunk_fail(NSString **failure,NSString *reason) {if(failure)*failure=reason;return nil;}
static BOOL integer(id object,uint64_t maximum,uint64_t *out) {return ffst_value_u64(object,maximum,out);}
static NSDictionary *json_dictionary(NSData *bytes,NSUInteger maximum) {
    if(!bytes||!bytes.length||bytes.length>maximum)return nil;
    id value=[NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    return [value isKindOfClass:[NSDictionary class]]?value:nil;
}
static NSString *blob_name(const ffsc_blob_entry *entry) {
    if(!entry->name_bytes||entry->name_bytes>FFSC_BLOB_NAME_BYTES||entry->name[0]=='.')return nil;
    for(unsigned i=0;i<entry->name_bytes;++i){char c=entry->name[i];
        if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return nil;}
    return [[NSString alloc] initWithBytes:entry->name length:entry->name_bytes encoding:NSASCIIStringEncoding];
}
static NSData *content_key(const unsigned char digest[32],uint64_t length) {
    /* Process-local tuple: preserve every digest/length bit without formatting.
     * Explicit byte offsets avoid struct padding; nothing here goes on wire. */
    unsigned char key[32+sizeof(length)];memcpy(key,digest,32);memcpy(key+32,&length,sizeof(length));
    return [NSData dataWithBytes:key length:sizeof(key)];
}
static NSData *manifest_bytes(NSData *packet,const ffsc_packet_header *header,NSDictionary *contents,NSString **failure) {
    const uint8_t *raw=packet.bytes;ffsc_blob_entry manifest={0};BOOL found=NO;
    for(uint32_t i=0;i<header->blob_count;++i){ffsc_blob_entry entry;memcpy(&entry,raw+header->blobs_offset+i*sizeof(entry),sizeof(entry));
        if(entry.payload_id)continue;
        if(found||![blob_name(&entry) isEqual:@"chunk.json"]||!entry.length||entry.length>2u*1024u*1024u||
           (entry.flags!=FFSC_BLOB_INLINE&&entry.flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_CACHE)&&entry.flags!=FFSC_BLOB_CACHED))
            return chunk_fail(failure,@"Chunk publication manifest is absent or ambiguous");
        manifest=entry;found=YES;
    }
    if(!found)return chunk_fail(failure,@"Chunk publication manifest is absent or ambiguous");
    if(manifest.flags&FFSC_BLOB_INLINE){NSData *bytes=[[NSData alloc] initWithBytes:raw+manifest.offset length:(NSUInteger)manifest.length];
        unsigned char digest[32];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
        if(memcmp(digest,manifest.sha256,32))return chunk_fail(failure,@"Chunk manifest SHA256 differs");return bytes;}
    NSData *bytes=contents[content_key(manifest.sha256,manifest.length)];
    return bytes.length==manifest.length?bytes:chunk_fail(failure,@"Referenced chunk manifest content is missing");
}
static BOOL retirement_digest(id text,unsigned char digest[32]) {
    if(![text isKindOfClass:[NSString class]]||[text length]!=64)return NO;
    for(unsigned i=0;i<32;++i){unsigned value=0;
        for(unsigned j=0;j<2;++j){unichar c=[text characterAtIndex:2*i+j];
            if(c>='0'&&c<='9')value=value*16+c-'0';
            else if(c>='a'&&c<='f')value=value*16+c-'a'+10;else return NO;}
        digest[i]=(unsigned char)value;
    }return YES;
}
static uint64_t count_add(uint64_t total,uint64_t amount) {return amount>UINT64_MAX-total?UINT64_MAX:total+amount;}
static NSString *dependency_key(uint64_t domain,uint64_t identity,uint64_t value,uint64_t payload) {
    return [NSString stringWithFormat:@"%llu:%llu:%llu:%llu",(unsigned long long)domain,(unsigned long long)identity,
        (unsigned long long)value,(unsigned long long)payload];
}
static BOOL matches(id value,NSString *key,uint64_t expected) {
    uint64_t actual;return [value isKindOfClass:[NSDictionary class]]&&integer(value[key],UINT64_MAX,&actual)&&actual==expected;
}
static NSString *category_kind(uint64_t category) {
    if(category==FFS_RENDER||category==FFS_CLEAR||category==FFS_RESOLVE)return @"render";
    if(category==FFS_BLIT||category==FFS_TIMESTAMP||category==FFS_SIGNAL_EVENT)return @"operation";
    return category==FFS_PRESENT_ENCODER?@"present":nil;
}

/* A packet slot is borrowed until consume. Uncached inline leaves share one
 * independently owned, immutable snapshot; admitted cache leaves still get
 * their own allocation so a small cache entry cannot pin the whole packet. */
@interface FFSTChunkSlabSlice : NSData {
    NSData *_owner;
    NSUInteger _offset,_sliceLength;
}
- (instancetype)initWithOwner:(NSData *)owner offset:(NSUInteger)offset length:(NSUInteger)length;
@property(nonatomic,readonly) NSData *owner;
@property(nonatomic,readonly) NSUInteger offset;
@end
@implementation FFSTChunkSlabSlice
- (instancetype)initWithOwner:(NSData *)owner offset:(NSUInteger)offset length:(NSUInteger)length {
    if(!owner||offset>owner.length||length>owner.length-offset)return nil;
    self=[super init];if(self){_owner=owner;_offset=offset;_sliceLength=length;}return self;
}
- (const void *)bytes {return (const uint8_t *)_owner.bytes+_offset;}
- (NSUInteger)length {return _sliceLength;}
- (id)copyWithZone:(NSZone *)zone {(void)zone;return self;}
- (NSData *)owner {return _owner;}
- (NSUInteger)offset {return _offset;}
@end

static BOOL segmented_buffer_name(id name) {
    if(![name isKindOfClass:[NSString class]]||![name hasSuffix:@".bin"])return NO;
    NSString *prefix;uint64_t maximum;
    if([name hasPrefix:@"cut-buffer-"]){prefix=@"cut-buffer-";maximum=FF_DRAW_RESOURCE_LIMIT;}
    else if([name hasPrefix:@"operation-buffer-"]){prefix=@"operation-buffer-";maximum=FFS_MAX_RESOURCES;}
    else return NO;
    NSUInteger digits=[name length]-prefix.length-4;if(digits<2||digits>4)return NO;
    uint64_t index=0;for(NSUInteger i=0;i<digits;++i){unichar c=[name characterAtIndex:prefix.length+i];
        if(c<'0'||c>'9')return NO;index=index*10+c-'0';}
    return index&&index<=maximum&&[name isEqual:[NSString stringWithFormat:@"%@%02llu.bin",prefix,(unsigned long long)index]];
}
static BOOL receiver_digest_name(NSString *name) {
    if(segmented_buffer_name(name))return YES;
    if(![name hasPrefix:@"page-"]||name.length<11)return NO;
    NSRange separator=[name rangeOfString:@"-" options:NSBackwardsSearch];
    if(separator.location==NSNotFound||name.length-separator.location!=5)return NO;
    for(NSUInteger i=separator.location+1;i<name.length;++i){unichar digit=[name characterAtIndex:i];
        if(digit<'0'||digit>'9')return NO;}
    NSString *base=[name substringWithRange:NSMakeRange(5,separator.location-5)];
    return segmented_buffer_name(base);
}
/* The manifest describes ordered 64-KiB pages already owned outside the slot
 * and SHA256-validated above. Validate every recipe before allocating any joined
 * buffer. Cache admissions and serial state remain uncommitted on any failure. */
static BOOL reconstruct_segments(NSDictionary *manifest,NSMutableDictionary *groups,NSMutableDictionary *digestGroups,NSMutableDictionary *pageIDGroups,NSDictionary *encoders,
    uint64_t *identityCount,uint64_t *identityPages,
    uint64_t *viewJoins,uint64_t *copiedBytes,uint64_t *owned,NSString **failure) {
#define SEGFAIL(reason) do {chunk_fail(failure,@reason);return NO;}while(0)
    id recipes=manifest[@"segmented_blobs"]?:@[];
    if(![recipes isKindOfClass:[NSArray class]]||[recipes count]>FFSC_MAX_BLOBS)SEGFAIL("Invalid segmented chunk blob table");
    NSMutableSet<NSString *> *targets=[NSMutableSet new],*pagesOwned=[NSMutableSet new];
    uint64_t reconstructed=0;NSUInteger pageCount=0;
    for(id recipe in recipes){uint64_t payload,length,pageBytes;
        if(![recipe isKindOfClass:[NSDictionary class]]||!integer(recipe[@"payload_id"],UINT64_MAX,&payload)||!payload||
           !encoders[@(payload)]||!segmented_buffer_name(recipe[@"name"])||
           !integer(recipe[@"length"],32u*1024u*1024u,&length)||length<256u*1024u||
           !integer(recipe[@"page_bytes"],65536,&pageBytes)||pageBytes!=65536)SEGFAIL("Invalid segmented buffer identity or bounds");
        ffs_record encoder;memcpy(&encoder,[encoders[@(payload)] bytes],sizeof(encoder));
        if(encoder.data[0]==FFS_PRESENT_ENCODER)SEGFAIL("Present payload cannot own segmented buffers");
        NSDictionary *group=groups[@(payload)];NSString *name=recipe[@"name"];
        NSString *target=[NSString stringWithFormat:@"%llu:%@",(unsigned long long)payload,name];
        NSArray *pages=recipe[@"pages"];uint64_t expected=(length+65535)/65536;
        if(!group||group[name]||[targets containsObject:target]||![pages isKindOfClass:[NSArray class]]||pages.count!=expected||
           pages.count>FFSC_MAX_BLOBS-pageCount)SEGFAIL("Segmented buffer coverage or original leaf conflicts");
        [targets addObject:target];pageCount+=pages.count;
        if(length>FFST_NATIVE_FRAME_MAX_BYTES-*owned-reconstructed)SEGFAIL("Segmented buffer reconstruction byte limit exceeded");
        reconstructed+=length;
        for(NSUInteger i=0;i<pages.count;++i){
            NSString *page=[NSString stringWithFormat:@"page-%@-%04lu",name,(unsigned long)i];
            if(![pages[i] isKindOfClass:[NSString class]]||![pages[i] isEqual:page]||page.length>=FFSC_BLOB_NAME_BYTES)
                SEGFAIL("Segmented buffer page name or order differs");
            NSString *owner=[NSString stringWithFormat:@"%llu:%@",(unsigned long long)payload,page];
            NSData *bytes=group[page];NSUInteger expectedBytes=(NSUInteger)MIN(UINT64_C(65536),length-i*UINT64_C(65536));
            if([pagesOwned containsObject:owner]||![bytes isKindOfClass:[NSData class]]||bytes.length!=expectedBytes)
                SEGFAIL("Segmented buffer page is missing, duplicated or wrong-sized");
            [pagesOwned addObject:owner];
        }
    }
    /* Reject orphan page leaves even in Present/metadata groups. Full canonical
     * names keep recipes disjoint, and explicit ownership prevents reuse. */
    for(NSNumber *payload in groups)for(NSString *name in groups[payload]){
        NSString *owner=[NSString stringWithFormat:@"%@:%@",payload,name];
        if(([name hasPrefix:@"page-"]&&![pagesOwned containsObject:owner])||
           ([targets containsObject:owner]&&[pagesOwned containsObject:owner]))SEGFAIL("Unowned or colliding segmented page leaf");
    }
    for(NSDictionary *recipe in recipes){
        NSUInteger length=[recipe[@"length"] unsignedIntegerValue];
        NSMutableDictionary *group=groups[recipe[@"payload_id"]],*digests=digestGroups[recipe[@"payload_id"]];NSUInteger offset=0;
        uint8_t pageSHA[FFST_CONTENT_PAGE_LIMIT*32];size_t page=0;
        FFSTChunkSlabSlice *first=nil;BOOL contiguous=YES;
        for(NSString *name in recipe[@"pages"]){NSData *bytes=group[name],*sha=digests[name];
            if(sha.length!=32)SEGFAIL("Segmented page digest provenance is missing");
            if(![bytes isKindOfClass:[FFSTChunkSlabSlice class]])contiguous=NO;
            else {FFSTChunkSlabSlice *slice=(FFSTChunkSlabSlice *)bytes;
                if(!first)first=slice;
                else if(slice.owner!=first.owner||slice.offset!=first.offset+offset)contiguous=NO;}
            offset+=bytes.length;
            memcpy(pageSHA+page++*32,sha.bytes,32);}
        NSData *contentID=ffst_verified_pages_content_id(pageSHA,page,length);
        if(!contentID)SEGFAIL("Segmented canonical content identity is invalid");
        ++*identityCount;*identityPages+=page;
        NSData *immutable=nil;
        if(contiguous&&first){immutable=[[FFSTChunkSlabSlice alloc] initWithOwner:first.owner offset:first.offset length:length];
            if(immutable)++*viewJoins;}
        else {void *joined=malloc(length);if(!joined)SEGFAIL("Cannot allocate segmented buffer reconstruction");
            offset=0;for(NSString *name in recipe[@"pages"]){NSData *bytes=group[name];
                memcpy((uint8_t *)joined+offset,bytes.bytes,bytes.length);offset+=bytes.length;}
            immutable=[[NSData alloc] initWithBytesNoCopy:joined length:length freeWhenDone:YES];
            if(!immutable)free(joined);else *copiedBytes+=length;}
        if(!immutable)SEGFAIL("Cannot own reconstructed segmented buffer");
        group[recipe[@"name"]]=immutable;[group removeObjectsForKeys:recipe[@"pages"]];
        pageIDGroups[recipe[@"payload_id"]][recipe[@"name"]]=contentID;[digests removeObjectsForKeys:recipe[@"pages"]];
    }
    /* Keep the prior conservative logical reservation even when a joined
     * buffer is only a view into the owned slab. */
    *owned+=reconstructed;return YES;
#undef SEGFAIL
}

@interface FFSTChunkPayloadProvider : NSObject <FFSTNativeFramePayloadProvider>
@property(nonatomic) uint64_t stream,frame,chunk;
@property(nonatomic,strong) NSDictionary<NSNumber *,FFSTNativeFramePassPayload *> *renders;
@property(nonatomic,strong) NSDictionary<NSNumber *,FFSTNativeFrameOperationPayload *> *operations;
@property(nonatomic,strong) NSDictionary<NSNumber *,NSDictionary *> *presents;
@property(nonatomic,strong) NSSet<NSString *> *dependencies;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,NSValue *> *imports;
@property(nonatomic,strong) FFSTExecutorSession *executorSession;
@property(nonatomic,strong) FFSTNativeSnapshotLease *sharedLease;
- (void)discardSharedSnapshots;
@end
@implementation FFSTChunkPayloadProvider
- (FFSTNativeFramePassPayload *)renderPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_renders[@(payload)])return chunk_fail(failure,@"Missing exact chunk render payload");return _renders[@(payload)];
}
- (FFSTNativeFrameOperationPayload *)operationPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_operations[@(payload)])return chunk_fail(failure,@"Missing exact chunk operation payload");return _operations[@(payload)];
}
- (NSDictionary *)presentPayload:(uint64_t)payload stream:(uint64_t)stream frame:(uint64_t)frame failure:(NSString **)failure {
    if(stream!=_stream||frame!=_frame||!_presents[@(payload)])return chunk_fail(failure,@"Missing exact chunk Present payload");return _presents[@(payload)];
}
- (BOOL)externalDependencyCompleted:(const ffs_record *)record failure:(NSString **)failure {
    if(record&&record->kind==FFS_DEPENDENCY&&record->stream==_stream&&record->frame==_frame&&record->chunk==_chunk&&
       (record->flags&FFS_EXTERNAL)&&record->data[4]==FFS_WAIT&&
       [_dependencies containsObject:dependency_key(record->data[0],record->data[1],record->data[2],record->data[5])])return YES;
    chunk_fail(failure,@"Chunk external dependency lacks exact completed source evidence");return NO;
}
- (id<MTLTexture>)initialTexture:(NSDictionary *)reference device:(id<MTLDevice>)device failure:(NSString **)failure {
    uint64_t cut,role,index,root,version,level,slice,generation;
    if(!integer(reference[@"shared_cut_id"],UINT64_MAX,&cut)||!cut||!integer(reference[@"shared_role"],FFST_STENCIL,&role)||
       role<FFST_COLOR||!integer(reference[@"shared_index"],7,&index))return chunk_fail(failure,@"Initial attachment lacks an exact shared lease");
    if(!integer(reference[@"root"],UINT64_MAX,&root)||!integer(reference[@"input_content_version"],UINT64_MAX,&version)||
       !integer(reference[@"allocation_generation"],UINT64_MAX,&generation)||!integer(reference[@"level"],UINT64_MAX,&level)||
       !integer(reference[@"slice"],UINT64_MAX,&slice))return chunk_fail(failure,@"Initial attachment provenance is invalid");
    FFSTExecutorAttachments lease=[_imports[@(cut)] pointerValue];
    if(!lease){NSString *reason=nil;lease=[_executorSession acquire:cut device:device timeout:15 failure:&reason];
        if(!lease)return chunk_fail(failure,[NSString stringWithFormat:@"Initial attachment lease unavailable cut=%llu root=%llu generation=%llu version=%llu role=%llu index=%llu mip=%llu slice=%llu: %@",
            (unsigned long long)cut,(unsigned long long)root,(unsigned long long)generation,(unsigned long long)version,
            (unsigned long long)role,(unsigned long long)index,(unsigned long long)level,(unsigned long long)slice,reason?:@"Attachment session unavailable"]);
        _imports[@(cut)]=[NSValue valueWithPointer:lease];}
    FFSTTextureInfo info={0};
    if(!ffst_executor_texture_info(lease,(FFSTAttachmentRole)role,(uint32_t)index,&info)||info.source_id!=root||
       info.source_generation!=version||info.source_level!=level||info.source_slice!=slice)
        return chunk_fail(failure,@"Initial attachment producer provenance differs");
    id<MTLTexture> texture=ffst_executor_texture(lease,(FFSTAttachmentRole)role,(uint32_t)index);
    if(!texture||texture.device.registryID!=device.registryID)return chunk_fail(failure,@"Initial attachment identity mismatch");return texture;
}
- (BOOL)finishImportsWithCommand:(id<MTLCommandBuffer>)command failure:(NSString **)failure {
    for(NSValue *value in _imports.allValues)if(!ffst_executor_finish(value.pointerValue,command)){
        chunk_fail(failure,@"Shared attachment completion hook rejected");return NO;}return YES;
}
- (BOOL)waitForImportRetirement:(NSString **)failure {
    BOOL retired=YES;for(NSValue *value in _imports.allValues)if(ffst_executor_wait(value.pointerValue,15)!=FFST_OK)retired=NO;
    if(!retired)chunk_fail(failure,@"Shared attachment retirement not acknowledged");return retired;
}
- (void)abandonImports {for(NSValue *value in _imports.allValues)ffst_executor_release(value.pointerValue);[_imports removeAllObjects];}
- (BOOL)sharedSnapshotWillSubmit:(NSString **)failure {return !_sharedLease||[_sharedLease submitted:failure];}
- (BOOL)sharedSnapshotGPUCompleted:(NSString **)failure {return !_sharedLease||[_sharedLease gpuCompleted:failure];}
- (void)sharedSnapshotAbandon {[_sharedLease abandon];}
- (void)discardSharedSnapshots {[_sharedLease abandon];_renders=nil;_operations=nil;_sharedLease=nil;}
- (void)dealloc {[self abandonImports];}
@end

@interface FFSTDecodedNativeChunk ()
@property(nonatomic,readwrite,strong) FFSTNativeChunkRequest *request;
@property(nonatomic,readwrite) ffsc_packet_header header;
@property(nonatomic,readwrite,strong) NSData *retirements;
@property(nonatomic,readwrite) uint64_t ownedBytes;
@end
@implementation FFSTDecodedNativeChunk
- (void)releasePreparedPayloads {[(FFSTChunkPayloadProvider *)_request.payloads discardSharedSnapshots];}
@end
@interface FFSTNativeChunkPayloadCache ()
- (FFSTDecodedNativeChunk *)decodePacket:(NSData *)source prevalidated:(BOOL)prevalidated failure:(NSString **)failure;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSData *> *contents;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSNumber *> *admittedSerials;
@property(nonatomic,strong) NSMutableDictionary<NSData *,NSDictionary *> *parsedTemplates;
@property(nonatomic,strong) NSMutableArray<NSData *> *parsedTemplateOrder;
@property(nonatomic) uint64_t parsedTemplateBytes,parsedTemplateHits,parsedTemplateMisses;
@property(nonatomic) uint64_t pageIdentities,pageIdentityPages;
@property(nonatomic) uint64_t bytes,maxBytes,stream,nextSerial;
@property(nonatomic) uint64_t hits,misses,admissions,evictions,evictedBytes;
@property(nonatomic) uint64_t receiverDigestBlobs,receiverDigestHashedBytes;
@property(nonatomic) uint64_t slabCopiedBytes,segmentViewJoins,segmentCopiedBytes;
@property(nonatomic) uint64_t sharedSnapshotBlobs,sharedSnapshotBytes;
@property(nonatomic,strong) FFSTNativeSnapshotArena *snapshotArena;
@property(nonatomic) NSUInteger maxBlobs;
@property(nonatomic) BOOL closed;
@property(nonatomic,strong) FFSTExecutorSession *executorSession;
@end
@implementation FFSTNativeChunkPayloadCache
- (instancetype)init {return [self initWithMaxBytes:FFSC_CACHE_MAX_BYTES maxBlobs:FFSC_CACHE_MAX_BLOBS];}
- (instancetype)initWithMaxBytes:(uint64_t)bytes maxBlobs:(NSUInteger)blobs {
    if(!bytes||bytes>FFSC_CACHE_MAX_BYTES||!blobs||blobs>FFSC_CACHE_MAX_BLOBS)return nil;
    self=[super init];if(self){_contents=[NSMutableDictionary new];_admittedSerials=[NSMutableDictionary new];
        _parsedTemplates=[NSMutableDictionary new];_parsedTemplateOrder=[NSMutableArray new];
        _maxBytes=bytes;_maxBlobs=blobs;_nextSerial=1;_executorSession=[FFSTExecutorSession new];}return self;
}
- (instancetype)initWithSnapshotArena:(FFSTNativeSnapshotArena *)arena {
    self=[self init];if(self)_snapshotArena=arena;return self;
}
- (NSDictionary *)stats {return @{@"cache_bytes":@(_bytes),@"cache_blobs":@(_contents.count),@"next_serial":@(_nextSerial),@"stream":@(_stream),@"closed":@(_closed),
    @"cache_hits":@(_hits),@"cache_misses":@(_misses),@"cache_admissions":@(_admissions),@"cache_evictions":@(_evictions),@"cache_evicted_bytes":@(_evictedBytes),
    @"digest_memo_entries":@0,@"digest_memo_hits":@0,@"digest_memo_misses":@0,
    @"digest_hashed_bytes":@(_receiverDigestHashedBytes),@"receiver_digest_blobs":@(_receiverDigestBlobs),
    @"slab_copied_bytes":@(_slabCopiedBytes),@"segment_view_joins":@(_segmentViewJoins),
    @"segment_copied_bytes":@(_segmentCopiedBytes),
    @"shared_snapshot_blobs":@(_sharedSnapshotBlobs),@"shared_snapshot_bytes":@(_sharedSnapshotBytes),
    @"parsed_template_entries":@(_parsedTemplates.count),@"parsed_template_bytes":@(_parsedTemplateBytes),
    @"parsed_template_hits":@(_parsedTemplateHits),@"parsed_template_misses":@(_parsedTemplateMisses),
    @"page_identity_count":@(_pageIdentities),@"page_identity_pages":@(_pageIdentityPages)};}
- (void)close {_closed=YES;[_contents removeAllObjects];[_admittedSerials removeAllObjects];
    [_parsedTemplates removeAllObjects];[_parsedTemplateOrder removeAllObjects];_parsedTemplateBytes=0;
    _bytes=0;[_executorSession close];_executorSession=nil;}
- (void)dealloc {[self close];}
- (FFSTDecodedNativeChunk *)decodePacket:(NSData *)source failure:(NSString **)failure {
    return [self decodePacket:source prevalidated:NO failure:failure];
}
- (FFSTDecodedNativeChunk *)decodePeekedPacket:(NSData *)source failure:(NSString **)failure {
    return [self decodePacket:source prevalidated:YES failure:failure];
}
- (FFSTDecodedNativeChunk *)decodePacket:(NSData *)source prevalidated:(BOOL)prevalidated failure:(NSString **)failure {
    if(failure)*failure=nil;
    if(_closed||![source isKindOfClass:[NSData class]]||source.length<sizeof(ffsc_packet_header)||source.length>FFSC_MAX_PACKET_BYTES)
        return chunk_fail(failure,@"Chunk cache is closed or packet size is invalid");
    NSData *packet=prevalidated?source:[[NSData alloc] initWithBytes:source.bytes length:source.length];
    if(!prevalidated&&ffsc_validate_packet(packet.bytes,packet.length)!=FFSC_OK)return chunk_fail(failure,@"Chunk packet layout or digest is invalid");
    ffsc_packet_header header;memcpy(&header,packet.bytes,sizeof(header));
    if(!(header.flags&FFSC_SOURCE_READY)||header.serial!=_nextSerial||(_stream&&header.stream!=_stream))
        return chunk_fail(failure,@"Chunk source completion or stream order differs");
    const uint8_t *raw=packet.bytes;
    NSMutableData *slabOffsets=[NSMutableData dataWithLength:(NSUInteger)header.blob_count*sizeof(NSUInteger)];
    NSMutableData *slabFirst=[NSMutableData dataWithLength:header.blob_count];
    NSUInteger *sliceOffsets=slabOffsets.mutableBytes,slabLength=0;uint8_t *first=slabFirst.mutableBytes;
    NSMutableDictionary<NSData *,NSNumber *> *inlineExtents=[NSMutableDictionary new];
    for(uint32_t i=0;i<header.blob_count;++i){ffsc_blob_entry entry;memcpy(&entry,raw+header.blobs_offset+i*sizeof(entry),sizeof(entry));
        sliceOffsets[i]=NSNotFound;
        if(entry.payload_id&&(entry.flags==FFSC_BLOB_INLINE||
           entry.flags==(FFSC_BLOB_INLINE|FFSC_BLOB_RECEIVER_DIGEST))){
            /* Validated packet aliases are identical extents; copy that owned
             * immutable span once. Cache-admitted blobs remain independent. */
            const uint64_t extent[2]={entry.offset,entry.length};NSData *key=[NSData dataWithBytes:extent length:sizeof(extent)];
            NSNumber *prior=inlineExtents[key];
            if(prior)sliceOffsets[i]=prior.unsignedIntegerValue;
            else {if(entry.length>FFSC_MAX_PACKET_BYTES-slabLength)return chunk_fail(failure,@"Inline snapshot byte limit exceeded");
                sliceOffsets[i]=slabLength;inlineExtents[key]=@(slabLength);first[i]=1;slabLength+=(NSUInteger)entry.length;}
        }
    }
    void *slabStorage=slabLength?malloc(slabLength):NULL;
    if(slabLength&&!slabStorage)return chunk_fail(failure,@"Cannot allocate inline snapshot");
    for(uint32_t i=0;i<header.blob_count;++i)if(first[i]){ffsc_blob_entry entry;
        memcpy(&entry,raw+header.blobs_offset+i*sizeof(entry),sizeof(entry));
        memcpy((uint8_t *)slabStorage+sliceOffsets[i],raw+entry.offset,(size_t)entry.length);}
    NSData *slab=slabLength?[[NSData alloc] initWithBytesNoCopy:slabStorage length:slabLength freeWhenDone:YES]:nil;
    if(slabLength&&!slab){free(slabStorage);return chunk_fail(failure,@"Cannot own inline snapshot");}
    /* Read the independently owned/hash-validated manifest first: retirement
     * creates provisional capacity, never an early mutation of the live cache. */
    NSData *manifestData=manifest_bytes(packet,&header,_contents,failure);if(!manifestData)return nil;
    NSDictionary *manifest=json_dictionary(manifestData,2u*1024u*1024u);
    if(![manifest[@"format"] isEqual:@"bedrock-native-chunk-files"]||!matches(manifest,@"version",1)||!matches(manifest,@"serial",header.serial)||
       !matches(manifest,@"stream",header.stream)||!matches(manifest,@"frame",header.frame)||!matches(manifest,@"chunk",header.chunk)||
       CFGetTypeID((__bridge CFTypeRef)(manifest[@"producer_completed"]?:@0))!=CFBooleanGetTypeID()||![manifest[@"producer_completed"] boolValue])
        return chunk_fail(failure,@"Chunk publication identity or source completion differs");
    BOOL hasShared=NO;for(uint32_t i=0;i<header.blob_count;++i){ffsc_blob_entry entry;
        memcpy(&entry,raw+header.blobs_offset+i*sizeof(entry),sizeof(entry));
        if(entry.flags==FFSC_BLOB_SHARED_SNAPSHOT)hasShared=YES;}
    NSDictionary *sharedInfo=manifest[@"shared_snapshot"];
    if(hasShared!=!!sharedInfo)return chunk_fail(failure,@"Shared snapshot manifest coverage differs");
    FFSTNativeSnapshotLease *snapshotLease=nil;
    if(hasShared){uint64_t slot,generation,serial;
        if(!_snapshotArena||![sharedInfo isKindOfClass:[NSDictionary class]]||sharedInfo.count!=3||
           !integer(sharedInfo[@"slot"],FFSA_SLOT_COUNT-1,&slot)||
           !integer(sharedInfo[@"generation"],UINT64_MAX,&generation)||!generation||
           !integer(sharedInfo[@"serial"],UINT64_MAX,&serial)||serial!=header.serial)
            return chunk_fail(failure,@"Shared snapshot lease identity differs");
        ffsa_lease identity={.slot=(uint32_t)slot,.generation=generation,.serial=serial};
        snapshotLease=[_snapshotArena acquire:identity failure:failure];if(!snapshotLease)return nil;
    }
    id retirementsTable=manifest[@"cache_evictions"]?:@[];
    if(![retirementsTable isKindOfClass:[NSArray class]]||[retirementsTable count]>FFSC_CACHE_MAX_BLOBS)
        return chunk_fail(failure,@"Invalid chunk cache retirement table");
    NSMutableSet<NSData *> *retiredKeys=[NSMutableSet new];uint64_t retiredBytes=0;
    if([retirementsTable count]){
        NSMutableSet<NSData *> *currentDigests=[NSMutableSet new];
        for(uint32_t i=0;i<header.blob_count;++i){ffsc_blob_entry entry;memcpy(&entry,raw+header.blobs_offset+i*sizeof(entry),sizeof(entry));
            [currentDigests addObject:[NSData dataWithBytes:entry.sha256 length:32]];}
        for(id retirement in retirementsTable){uint64_t length,admitted;unsigned char digest[32];
            if(![retirement isKindOfClass:[NSDictionary class]]||!retirement_digest(retirement[@"sha256"],digest)||
               !integer(retirement[@"bytes"],FFSC_MAX_PACKET_BYTES,&length)||!length||
               !integer(retirement[@"admitted_serial"],UINT64_MAX,&admitted)||!admitted||admitted>=header.serial)
                return chunk_fail(failure,@"Invalid chunk cache retirement identity");
            NSData *key=content_key(digest,length);NSData *prior=_contents[key];
            if(!prior||prior.length!=length||[_admittedSerials[key] unsignedLongLongValue]!=admitted||[retiredKeys containsObject:key]||
               [currentDigests containsObject:[NSData dataWithBytes:digest length:32]])
                return chunk_fail(failure,@"Unknown, duplicated or currently referenced cache retirement");
            if(length>_bytes-retiredBytes)return chunk_fail(failure,@"Chunk cache retirement byte count differs");
            [retiredKeys addObject:key];retiredBytes+=length;
        }
    }
    uint64_t remainingBytes=_bytes-retiredBytes,hits=0,misses=0;NSUInteger remainingCount=_contents.count-retiredKeys.count;
    NSMutableDictionary<NSNumber *,NSMutableDictionary<NSString *,NSData *> *> *groups=[NSMutableDictionary new];
    NSMutableDictionary<NSNumber *,NSMutableDictionary<NSString *,NSData *> *> *digestGroups=[NSMutableDictionary new];
    NSMutableDictionary<NSNumber *,NSMutableDictionary<NSString *,NSData *> *> *pageIDGroups=[NSMutableDictionary new];
    NSMutableDictionary<NSData *,NSData *> *additions=[NSMutableDictionary new];uint64_t additionBytes=0,owned=header.record_count*sizeof(ffs_record)+header.retirement_count*sizeof(ffsc_retirement);
    uint64_t receiverDigestBlobs=0,receiverDigestBytes=0,sharedSnapshotBlobs=0,sharedSnapshotBytes=0;
    for(uint32_t i=0;i<header.blob_count;++i){ffsc_blob_entry entry;memcpy(&entry,raw+header.blobs_offset+i*sizeof(entry),sizeof(entry));
        NSString *name=blob_name(&entry);BOOL receiverDigest=(entry.flags&FFSC_BLOB_RECEIVER_DIGEST)!=0;
        BOOL shared=entry.flags==FFSC_BLOB_SHARED_SNAPSHOT;
        if(!name||!entry.length||entry.length>FFSC_MAX_PACKET_BYTES||
           (entry.flags!=FFSC_BLOB_INLINE&&entry.flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_CACHE)&&
            entry.flags!=FFSC_BLOB_CACHED&&entry.flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_RECEIVER_DIGEST)&&!shared))
            return chunk_fail(failure,@"Invalid chunk blob name, flags or extent");
        if(shared&&(!entry.payload_id||!ffsc_shared_snapshot_name(entry.name)||entry.length>FFST_CONTENT_BUFFER_MAX_BYTES||
           entry.offset%FFSA_ALIGNMENT))return chunk_fail(failure,@"Shared snapshot name or bounds differ");
        if(receiverDigest){if(!entry.payload_id||!receiver_digest_name(name))
                return chunk_fail(failure,@"Receiver digest blob name or payload is invalid");
            for(unsigned j=0;j<32;++j)if(entry.sha256[j])
                return chunk_fail(failure,@"Receiver digest blob carries a source digest");}
        NSNumber *payload=@(entry.payload_id);NSMutableDictionary *group=groups[payload];
        if(!group){group=[NSMutableDictionary new];groups[payload]=group;digestGroups[payload]=[NSMutableDictionary new];pageIDGroups[payload]=[NSMutableDictionary new];}
        if(group[name])return chunk_fail(failure,@"Duplicated chunk payload basename");
        NSData *bytes=nil,*pageID=nil;unsigned char resolvedDigest[32];memcpy(resolvedDigest,entry.sha256,32);
        if(shared){bytes=[snapshotLease snapshotAtOffset:entry.offset length:entry.length failure:failure];if(!bytes)return nil;
            if(entry.length>=FFST_CONTENT_PAGE_MIN_BYTES){pageID=ffst_buffer_content_id(bytes.bytes,bytes.length);
                if(!pageID)return chunk_fail(failure,@"Shared snapshot canonical identity failed");}
            else CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,resolvedDigest);
            ++sharedSnapshotBlobs;sharedSnapshotBytes=count_add(sharedSnapshotBytes,entry.length);}
        if(receiverDigest){bytes=[[FFSTChunkSlabSlice alloc] initWithOwner:slab offset:sliceOffsets[i] length:(NSUInteger)entry.length];
            if(!bytes)return chunk_fail(failure,@"Receiver digest blob ownership failed");
            CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,resolvedDigest);
            ++receiverDigestBlobs;receiverDigestBytes=count_add(receiverDigestBytes,bytes.length);}
        NSData *key=shared?nil:content_key(resolvedDigest,entry.length);
        NSData *previous=key&&![retiredKeys containsObject:key]?_contents[key]:nil;
        /* Counters describe descriptor lookups against prior committed cache
         * content, and commit only with the packet (including inline misses). */
        if(previous)++hits;else ++misses;
        if(shared){/* Arena content is never admitted to the transport cache. */}
        else if(entry.flags&FFSC_BLOB_INLINE){if(!receiverDigest){bytes=entry.payload_id?
                (sliceOffsets[i]!=NSNotFound?[[FFSTChunkSlabSlice alloc] initWithOwner:slab offset:sliceOffsets[i] length:(NSUInteger)entry.length]:
                    [[NSData alloc] initWithBytes:raw+entry.offset length:(NSUInteger)entry.length]):manifestData;
                if(entry.payload_id){unsigned char digest[32];CC_SHA256(bytes.bytes,(CC_LONG)bytes.length,digest);
                    if(memcmp(digest,entry.sha256,sizeof(digest)))return chunk_fail(failure,@"Chunk inline blob SHA256 differs");}}
            NSData *prior=previous?:additions[key];if(prior&&![prior isEqual:bytes])return chunk_fail(failure,@"Conflicting cached chunk content");
            if((entry.flags&FFSC_BLOB_CACHE)&&!prior){
                if(remainingCount+additions.count>=_maxBlobs||entry.length>_maxBytes-remainingBytes-additionBytes)
                    return chunk_fail(failure,@"Chunk cache admission limit exceeded");
                additions[key]=bytes;additionBytes+=entry.length;
            }
        }else{bytes=previous;if(!bytes||bytes.length!=entry.length)return chunk_fail(failure,@"Referenced chunk cache content is missing");
            /* Admission hashed an independently copied immutable NSData. The
             * exact content key and length remain valid without rehashing every
             * static vertex/texture blob on every subsequent chunk. */
        }
        if(bytes.length>FFST_NATIVE_FRAME_MAX_BYTES-owned)return chunk_fail(failure,@"Resolved chunk payload byte limit exceeded");
        owned+=bytes.length;group[name]=bytes;
        if(pageID)pageIDGroups[payload][name]=pageID;
        else digestGroups[payload][name]=[NSData dataWithBytes:resolvedDigest length:32];
    }
    NSDictionary *metadata=groups[@0];
    if(metadata.count!=1||!metadata[@"chunk.json"])return chunk_fail(failure,@"Chunk publication manifest is absent or ambiguous");
    NSArray *entries=manifest[@"payloads"],*dependencies=manifest[@"dependencies"];
    if(![entries isKindOfClass:[NSArray class]]||entries.count>FFSC_MAX_BLOBS||![dependencies isKindOfClass:[NSArray class]]||dependencies.count>FFS_MAX_DEPENDENCIES)
        return chunk_fail(failure,@"Invalid chunk publication tables");
    NSMutableSet *dependencyKeys=[NSMutableSet new];
    for(id d in dependencies){uint64_t domain,identity,value,payload;
        if(![d isKindOfClass:[NSDictionary class]]||!integer(d[@"domain"],FFS_EVENT,&domain)||!domain||
           !integer(d[@"id"],UINT64_MAX,&identity)||!identity||!integer(d[@"value"],UINT64_MAX,&value)||
           !integer(d[@"payload_id"],UINT64_MAX,&payload)||!payload)return chunk_fail(failure,@"Invalid completed chunk dependency");
        NSString *key=dependency_key(domain,identity,value,payload);if([dependencyKeys containsObject:key])return chunk_fail(failure,@"Duplicated completed chunk dependency");
        [dependencyKeys addObject:key];
    }
    NSData *records=[[NSData alloc] initWithBytes:raw+header.records_offset length:header.record_count*sizeof(ffs_record)];
    NSMutableDictionary<NSNumber *,NSData *> *encoders=[NSMutableDictionary new];NSMutableSet *usedDependencies=[NSMutableSet new];BOOL foundChunk=NO;
    for(uint32_t i=0;i<header.record_count;++i){ffs_record record;memcpy(&record,(const uint8_t *)records.bytes+i*sizeof(record),sizeof(record));
        if(record.kind==FFS_CHUNK_BEGIN){if(foundChunk||record.data[3]!=header.queue_completion)return chunk_fail(failure,@"Chunk queue completion identity differs");foundChunk=YES;}
        if(record.kind==FFS_ENCODER_BEGIN){
            if(record.data[0]==FFS_NULL){if(record.data[4])return chunk_fail(failure,@"Null encoder has a chunk payload");continue;}
            NSNumber *payload=@(record.data[4]);if(!record.data[4]||!(record.flags&FFS_PAYLOAD)||!category_kind(record.data[0])||encoders[payload])
                return chunk_fail(failure,@"Unsupported or duplicated chunk encoder payload ID");
            encoders[payload]=[NSData dataWithBytes:&record length:sizeof(record)];
        }
        if(record.kind==FFS_DEPENDENCY&&(record.flags&FFS_EXTERNAL)){
            NSString *key=dependency_key(record.data[0],record.data[1],record.data[2],record.data[5]);
            if(record.data[4]!=FFS_WAIT||!(record.flags&FFS_PAYLOAD)||![dependencyKeys containsObject:key])return chunk_fail(failure,@"External chunk dependency is not producer completed");
            [usedDependencies addObject:key];
        }
    }
    if(!foundChunk||entries.count!=encoders.count||groups.count!=encoders.count+1||![dependencyKeys isEqualToSet:usedDependencies])
        return chunk_fail(failure,@"Chunk payload/dependency coverage differs");
    uint64_t identityCount=0,identityPages=0,viewJoins=0,copiedBytes=0,templateHits=0,templateMisses=0;
    if(!reconstruct_segments(manifest,groups,digestGroups,pageIDGroups,encoders,&identityCount,&identityPages,&viewJoins,&copiedBytes,&owned,failure))return nil;
    FFSTChunkPayloadProvider *provider=[FFSTChunkPayloadProvider new];provider.stream=header.stream;provider.frame=header.frame;provider.chunk=header.chunk;
    provider.dependencies=[dependencyKeys copy];provider.imports=[NSMutableDictionary new];provider.executorSession=_executorSession;
    provider.sharedLease=snapshotLease;
    NSMutableDictionary *renders=[NSMutableDictionary new],*operations=[NSMutableDictionary new],*presents=[NSMutableDictionary new];NSMutableSet *seen=[NSMutableSet new];
    NSMutableDictionary<NSData *,NSDictionary *> *newTemplates=[NSMutableDictionary new];
    for(id entry in entries){uint64_t payload;
        if(![entry isKindOfClass:[NSDictionary class]]||!integer(entry[@"payload_id"],UINT64_MAX,&payload)||!payload||[seen containsObject:@(payload)]||!encoders[@(payload)]||
           ![entry[@"directory"] isEqual:[NSString stringWithFormat:@"payload-%llu",(unsigned long long)payload]])return chunk_fail(failure,@"Chunk payload declaration identity differs");
        [seen addObject:@(payload)];ffs_record encoder;memcpy(&encoder,[encoders[@(payload)] bytes],sizeof(encoder));
        NSDictionary *blobs=groups[@(payload)];NSData *templateBytes=blobs[@"replay-template.json"];
        NSData *templateDigest=digestGroups[@(payload)][@"replay-template.json"];
        NSData *templateKey=templateBytes&&templateDigest?content_key(templateDigest.bytes,templateBytes.length):nil;
        NSDictionary *parsedTemplate=templateKey&&![retiredKeys containsObject:templateKey]?_parsedTemplates[templateKey]:nil;
        if(templateKey){if(parsedTemplate)++templateHits;else ++templateMisses;}
        FFSTOwnedBlobs *ownedBlobs=ffst_owned_blobs_with_template_from_decoder(blobs,digestGroups[@(payload)],pageIDGroups[@(payload)],parsedTemplate,failure);
        if(!ownedBlobs)return nil;NSDictionary *bindings=[ownedBlobs jsonDictionary:@"bindings.json"];
        if(!matches(bindings,@"stream",header.stream)||!matches(bindings,@"frame",header.frame)||!matches(bindings,@"chunk",header.chunk)||
           !matches(bindings,@"encoder",encoder.encoder)||!matches(bindings,@"payload_id",payload)||!matches(bindings,@"category",encoder.data[0])||
           ![entry[@"kind"] isEqual:category_kind(encoder.data[0])])return chunk_fail(failure,@"Chunk binding identity or category differs");
        if([entry[@"kind"] isEqual:@"render"]){
            FFSTNativeFramePassPayload *pass=[FFSTNativeFramePassPayload payloadWithOwnedBlobs:ownedBlobs failure:failure];if(!pass)return nil;renders[@(payload)]=pass;
            if(templateKey&&!parsedTemplate&&(_contents[templateKey]||additions[templateKey]))
                newTemplates[templateKey]=[ownedBlobs jsonDictionary:@"replay-template.json"];
        }else if([entry[@"kind"] isEqual:@"operation"]){
            FFSTNativeFrameOperationPayload *operation=[FFSTNativeFrameOperationPayload payloadWithOwnedBlobs:ownedBlobs failure:failure];if(!operation)return nil;operations[@(payload)]=operation;
        }else{
            if(![bindings[@"format"] isEqual:@"bedrock-native-frame-present"]||!matches(bindings,@"version",1))return chunk_fail(failure,@"Invalid chunk Present binding format");
            presents[@(payload)]=bindings;
        }
    }
    provider.renders=[renders copy];provider.operations=[operations copy];provider.presents=[presents copy];
    NSData *retirements=[[NSData alloc] initWithBytes:raw+header.retirements_offset length:header.retirement_count*sizeof(ffsc_retirement)];
    NSMutableArray *retiredRoots=[NSMutableArray new];NSMutableSet *retiredRootKeys=[NSMutableSet new];
    for(uint32_t i=0;i<header.retirement_count;++i){ffsc_retirement r;memcpy(&r,(const uint8_t *)retirements.bytes+i*sizeof(r),sizeof(r));
        NSString *key=[NSString stringWithFormat:@"%u:%llu:%llu",r.kind,(unsigned long long)r.root,(unsigned long long)r.generation];
        if(r.kind<FFS_BUFFER||r.kind>FFS_TEXTURE||!r.root||!r.generation||!r.last_use_serial||r.last_use_serial>header.serial||r.reserved||[retiredRootKeys containsObject:key])
            return chunk_fail(failure,@"Invalid or duplicated chunk retirement identity");
        [retiredRootKeys addObject:key];[retiredRoots addObject:@{@"kind":@(r.kind),@"root":@(r.root),@"allocation_generation":@(r.generation),@"last_use_serial":@(r.last_use_serial)}];
    }
    FFSTNativeChunkRequest *request=[FFSTNativeChunkRequest requestWithRecords:records serial:header.serial retainedBytes:(size_t)owned payloads:provider retiredRoots:retiredRoots failure:failure];
    if(!request)return nil;
    if(request.serial!=header.serial||request.streamID!=header.stream||request.frameID!=header.frame||request.chunkID!=header.chunk||
       request.firstSequence!=header.first_sequence||request.nextSequence!=header.next_sequence||request.recordDigest!=header.record_digest||
       request.beginsFrame!=((header.flags&FFSC_FRAME_BEGIN)!=0)||request.endsFrame!=((header.flags&FFSC_FRAME_END)!=0))
        return chunk_fail(failure,@"Native chunk request and packet identity differ");
    for(NSData *key in retiredKeys){NSDictionary *old=_parsedTemplates[key];if(old){_parsedTemplateBytes-=[_contents[key] length];
        [_parsedTemplates removeObjectForKey:key];[_parsedTemplateOrder removeObject:key];}}
    if(retiredKeys.count||additions.count){NSMutableDictionary *committed=[_contents mutableCopy],*admitted=[_admittedSerials mutableCopy];
        [committed removeObjectsForKeys:retiredKeys.allObjects];[admitted removeObjectsForKeys:retiredKeys.allObjects];
        [committed addEntriesFromDictionary:additions];for(NSData *key in additions)admitted[key]=@(header.serial);
        _contents=committed;_admittedSerials=admitted;}
    _bytes=remainingBytes+additionBytes;_stream=header.stream;++_nextSerial;
    for(NSData *key in newTemplates){NSData *data=_contents[key];if(!data||_parsedTemplates[key])continue;
        if(data.length>8u*1024u*1024u)continue;
        while(_parsedTemplateOrder.count>=1024||data.length>8u*1024u*1024u-_parsedTemplateBytes){
            NSData *oldKey=_parsedTemplateOrder.firstObject;if(!oldKey)break;
            _parsedTemplateBytes-=[_contents[oldKey] length];[_parsedTemplates removeObjectForKey:oldKey];
            [_parsedTemplateOrder removeObjectAtIndex:0];}
        _parsedTemplates[key]=newTemplates[key];[_parsedTemplateOrder addObject:key];_parsedTemplateBytes+=data.length;}
    _parsedTemplateHits=count_add(_parsedTemplateHits,templateHits);
    _parsedTemplateMisses=count_add(_parsedTemplateMisses,templateMisses);
    _hits=count_add(_hits,hits);_misses=count_add(_misses,misses);_admissions=count_add(_admissions,additions.count);
    _evictions=count_add(_evictions,retiredKeys.count);_evictedBytes=count_add(_evictedBytes,retiredBytes);
    _pageIdentities=count_add(_pageIdentities,identityCount);_pageIdentityPages=count_add(_pageIdentityPages,identityPages);
    _receiverDigestBlobs=count_add(_receiverDigestBlobs,receiverDigestBlobs);
    _receiverDigestHashedBytes=count_add(_receiverDigestHashedBytes,receiverDigestBytes);
    _slabCopiedBytes=count_add(_slabCopiedBytes,slabLength);
    _segmentViewJoins=count_add(_segmentViewJoins,viewJoins);
    _segmentCopiedBytes=count_add(_segmentCopiedBytes,copiedBytes);
    _sharedSnapshotBlobs=count_add(_sharedSnapshotBlobs,sharedSnapshotBlobs);
    _sharedSnapshotBytes=count_add(_sharedSnapshotBytes,sharedSnapshotBytes);
    FFSTDecodedNativeChunk *decoded=[FFSTDecodedNativeChunk new];decoded.request=request;decoded.header=header;decoded.retirements=retirements;decoded.ownedBytes=owned;return decoded;
}
@end
