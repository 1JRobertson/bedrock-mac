/* Private packed draw replay. ARC/MRC. Little-endian fixed-width records. */
#ifndef PRIVATE_PACKED_REPLAY_H
#define PRIVATE_PACKED_REPLAY_H
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if __has_feature(objc_arc)
#define PR_AUTO(x) (x)
#else
#define PR_AUTO(x) [(x) autorelease]
#endif
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error Packed replay requires little-endian source and receiver
#endif
#define PR_MAGIC UINT64_C(0x3130594c50524450) /* PDRPLY01 */
#define PR_LIMIT (4u*1024u*1024u)
#define PR_ROWS 512u
#define PR_DEPTHS 256u
#define PR_DEPTH_KEY @"_packed_depth_states"
#pragma pack(push,1)
typedef struct {
    uint32_t pipeline,resources,depth,stencil;
    float blend[4];double viewport[6];uint32_t scissor[4],raster[4];float bias[3];
    uint64_t draw[5];uint32_t indexed,index_type;int32_t base_vertex;uint32_t material_geometry;
    uint64_t index_count,index_offset;
} pr_row;
typedef struct {uint64_t magic;uint32_t version,total,header_bytes,rows,row_bytes;} pr_header;
#pragma pack(pop)
_Static_assert(sizeof(float)==4&&sizeof(double)==8&&sizeof(pr_header)==28&&sizeof(pr_row)==196,"packed replay ABI");
static int pr_row_valid(const pr_row *r,size_t depths){
    if(!r||r->depth>=depths||r->indexed>1||r->material_geometry>1||r->raster[0]>1||r->raster[1]>2||r->raster[2]>1||r->raster[3]>1)return 0;
    if(!r->indexed&&(r->index_type||r->base_vertex||r->index_count||r->index_offset))return 0;
    for(unsigned i=0;i<4;i++)if(!isfinite(r->blend[i]))return 0;
    for(unsigned i=0;i<6;i++)if(!isfinite(r->viewport[i]))return 0;
    for(unsigned i=0;i<3;i++)if(!isfinite(r->bias[i]))return 0;
    return 1;
}
/* Return the actual NSJSON parse of one source float/double. Callers keep a
 * bounded per-message cache keyed by the source NSNumber type and raw bits. */
static NSNumber *pr_normal_number(NSNumber *n,NSMutableDictionary *cache){
    const char *t=[n objCType];if(!t||!t[0]||t[1])return nil;
    double d=n.doubleValue;if(!isfinite(d))return nil;uint64_t bits;memcpy(&bits,&d,8);
    uint8_t raw[9];raw[0]=(uint8_t)t[0];for(unsigned i=0;i<8;i++)raw[i+1]=(uint8_t)(bits>>(8*i));
    NSData *key=[NSData dataWithBytes:raw length:sizeof(raw)];NSNumber *known=cache[key];if(known)return known;
    if(cache.count>=4096)return nil;NSData *json=[NSJSONSerialization dataWithJSONObject:@[n] options:0 error:nil];
    id parsed=json?[NSJSONSerialization JSONObjectWithData:json options:0 error:nil]:nil;
    if(![parsed isKindOfClass:[NSArray class]]||[parsed count]!=1||![parsed[0] isKindOfClass:[NSNumber class]]||
       CFGetTypeID((__bridge CFTypeRef)parsed[0])==CFBooleanGetTypeID()||!isfinite([parsed[0] doubleValue]))return nil;
    cache[key]=parsed[0];return parsed[0];
}
static NSNumber *pr_float(float x,NSMutableDictionary *cache){NSNumber *n=@(x);return cache?pr_normal_number(n,cache):n;}
static NSNumber *pr_double(double x,NSMutableDictionary *cache){NSNumber *n=@(x);return cache?pr_normal_number(n,cache):n;}
/* cache nil recreates the exact producer box expressions for JSON fallback;
 * nonnil reproduces the JSON-parsed values expected by native consumers. */
static __attribute__((unused)) NSDictionary *pr_row_dictionary(const pr_row *r,NSArray *depths,NSMutableDictionary *cache){
    if(!pr_row_valid(r,depths.count))return nil;
    NSNumber *blend[4],*viewport[6],*bias[3];
    for(unsigned i=0;i<4;i++)if(!(blend[i]=pr_float(r->blend[i],cache)))return nil;
    for(unsigned i=0;i<6;i++)if(!(viewport[i]=pr_double(r->viewport[i],cache)))return nil;
    for(unsigned i=0;i<3;i++)if(!(bias[i]=pr_float(r->bias[i],cache)))return nil;
    NSMutableDictionary *v=[@{@"pipeline":@((NSUInteger)r->pipeline),@"resources":@((NSUInteger)r->resources),
        @"depth_state":depths[r->depth],@"stencil_ref":@(r->stencil),
        @"blend_constant":@[blend[0],blend[1],blend[2],blend[3]],
        @"viewport":@[viewport[0],viewport[1],viewport[2],viewport[3],viewport[4],viewport[5]],
        @"scissor":@[@((uint64_t)r->scissor[0]),@((uint64_t)r->scissor[1]),@((uint64_t)r->scissor[2]),@((uint64_t)r->scissor[3])],
        @"raster":@[@(r->raster[0]),@(r->raster[1]),@(r->raster[2]),@(r->raster[3]),bias[0],bias[1],bias[2]],
        @"draw":@[@((uint32_t)r->draw[0]),@(r->draw[1]),@(r->draw[2]),@((uint32_t)r->draw[3]),@((uint32_t)r->draw[4])],
        @"material_geometry":@((int)r->material_geometry)} mutableCopy];
    if(r->indexed)v[@"indexed"]=@{@"index_type":@(r->index_type),@"index_count":@(r->index_count),
        @"base_vertex":@(r->base_vertex),@"index_offset":@(r->index_offset)};
    NSDictionary *out=PR_AUTO([v copy]);
#if !__has_feature(objc_arc)
    [v release];
#endif
    return out;
}
static int pr_budget(NSData *header,NSData *rows,NSArray *depths){
    if(!header||!rows||![depths isKindOfClass:[NSArray class]]||!depths.count||depths.count>PR_DEPTHS||
       rows.length%sizeof(pr_row)||rows.length/sizeof(pr_row)>PR_ROWS||header.length>PR_LIMIT)return 0;
    size_t count=rows.length/sizeof(pr_row);if(count>(PR_LIMIT-header.length)/4096)return 0;
    uint64_t used=header.length+count*UINT64_C(4096);NSUInteger lengths[PR_DEPTHS]={0};
    for(NSUInteger i=0;i<depths.count;i++){
        id depth=depths[i];if(depth!=[NSNull null]&&![depth isKindOfClass:[NSDictionary class]])return 0;
        NSData *json=[NSJSONSerialization dataWithJSONObject:@[depth] options:0 error:nil];if(!json||json.length<2)return 0;lengths[i]=json.length-2;}
    const uint8_t *p=rows.bytes;for(size_t i=0;i<count;i++){
        pr_row r;memcpy(&r,p+i*sizeof(r),sizeof(r));if(!pr_row_valid(&r,depths.count)||lengths[r.depth]>PR_LIMIT-used)return 0;used+=lengths[r.depth];}
    return 1;
}
/* These are invariants of the source's already-validated draw prefix. Do not
 * use arbitrary wire indices to bypass native pass validation. */
static int pr_schema(NSDictionary *head,NSData *rows){
    NSArray *pipelines=head[@"pipelines"];
    if(![pipelines isKindOfClass:[NSArray class]]||pipelines.count>PR_ROWS||rows.length%sizeof(pr_row))return 0;
    const uint8_t *p=rows.bytes;size_t count=rows.length/sizeof(pr_row);
    for(size_t i=0;i<count;i++){
        pr_row r;memcpy(&r,p+i*sizeof(r),sizeof(r));
        if(r.pipeline>=pipelines.count||r.resources!=i||r.stencil>UINT8_MAX||r.draw[0]>4||
           r.draw[1]>UINT32_MAX||!r.draw[2]||r.draw[2]>10000000||!r.draw[3]||r.draw[3]>1000000||
           r.draw[3]>UINT32_MAX||r.draw[4]>UINT32_MAX||r.draw[2]>10000000/r.draw[3]||
           (r.indexed&&(r.index_type>1||r.index_count!=r.draw[2])))return 0;
    }return 1;
}
static __attribute__((unused)) NSData *packed_replay_encode(NSDictionary *manifest,NSData *rows,NSArray *depths){
    @try {
        if(![manifest isKindOfClass:[NSDictionary class]]||manifest[PR_DEPTH_KEY]||
           ![manifest[@"draws"] isKindOfClass:[NSArray class]]||rows.length%sizeof(pr_row)||
           [manifest[@"draws"] count]!=rows.length/sizeof(pr_row))return nil;
        NSMutableDictionary *head=[manifest mutableCopy];[head removeObjectForKey:@"draws"];head[PR_DEPTH_KEY]=depths;
        BOOL shape=pr_schema(head,rows);NSData *json=shape?[NSJSONSerialization dataWithJSONObject:head options:0 error:nil]:nil;
#if !__has_feature(objc_arc)
        [head release];
#endif
        if(!pr_budget(json,rows,depths)||json.length>PR_LIMIT-sizeof(pr_header)||rows.length>PR_LIMIT-sizeof(pr_header)-json.length)return nil;
        pr_header h={.magic=PR_MAGIC,.version=1,.total=(uint32_t)(sizeof(h)+json.length+rows.length),
            .header_bytes=(uint32_t)json.length,.rows=(uint32_t)(rows.length/sizeof(pr_row)),.row_bytes=sizeof(pr_row)};
        NSMutableData *wire=[NSMutableData dataWithCapacity:h.total];[wire appendBytes:&h length:sizeof(h)];[wire appendData:json];[wire appendData:rows];return PR_AUTO([wire copy]);
    }@catch(NSException *error){(void)error;return nil;}
}
static __attribute__((unused)) NSDictionary *packed_replay_decode(NSData *wire){
    @try {
        if(![wire isKindOfClass:[NSData class]]||wire.length<sizeof(pr_header)||wire.length>PR_LIMIT)return nil;
        pr_header h;memcpy(&h,wire.bytes,sizeof(h));if(h.magic!=PR_MAGIC||h.version!=1||h.total!=wire.length||
            h.rows>PR_ROWS||h.row_bytes!=sizeof(pr_row)||h.header_bytes>wire.length-sizeof(h)||
            (uint64_t)h.rows*sizeof(pr_row)!=wire.length-sizeof(h)-h.header_bytes)return nil;
        NSData *json=[NSData dataWithBytes:(const uint8_t *)wire.bytes+sizeof(h) length:h.header_bytes];
        id object=[NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
        if(![object isKindOfClass:[NSDictionary class]]||object[@"draws"]||![object[PR_DEPTH_KEY] isKindOfClass:[NSArray class]])return nil;
        NSArray *depths=object[PR_DEPTH_KEY];NSData *rows=[NSData dataWithBytes:(const uint8_t *)wire.bytes+sizeof(h)+h.header_bytes length:(NSUInteger)h.rows*sizeof(pr_row)];
        if(!pr_budget(json,rows,depths)||!pr_schema(object,rows))return nil;
        NSMutableArray *draws=[NSMutableArray arrayWithCapacity:h.rows];NSMutableDictionary *cache=[NSMutableDictionary dictionary];
        const uint8_t *p=rows.bytes;for(uint32_t i=0;i<h.rows;i++){
            pr_row row;memcpy(&row,p+i*sizeof(row),sizeof(row));if(cache.count>4096-13)[cache removeAllObjects];NSDictionary *draw=pr_row_dictionary(&row,depths,cache);if(!draw)return nil;[draws addObject:draw];}
        NSMutableDictionary *out=[object mutableCopy];[out removeObjectForKey:PR_DEPTH_KEY];out[@"draws"]=[draws copy];
#if !__has_feature(objc_arc)
        [out[@"draws"] autorelease];
#endif
        NSDictionary *copy=PR_AUTO([out copy]);
#if !__has_feature(objc_arc)
        [out release];
#endif
        return copy;
    }@catch(NSException *error){(void)error;return nil;}
}
@interface NSObject (PrivatePackedReplaySelectors)
- (NSUInteger)privatePackedReplayMode;
- (NSData *)privatePackedReplayBytes;
@end

/* Eligibility only: call after packed_replay_decode succeeded on these same
 * immutable bytes. Ineligible inputs retain the original full-policy walk. */
static __attribute__((unused)) BOOL pr_policy_header_utf8(NSData *wire) {
    if (![wire isKindOfClass:[NSData class]] || wire.length < sizeof(pr_header) || wire.length > PR_LIMIT) return NO;
    pr_header h; memcpy(&h, wire.bytes, sizeof(h));
    if (h.magic != PR_MAGIC || h.version != 1 || h.total != wire.length || h.rows > PR_ROWS ||
        h.row_bytes != sizeof(pr_row) || h.header_bytes > wire.length - sizeof(h) ||
        (uint64_t)h.rows * sizeof(pr_row) != wire.length - sizeof(h) - h.header_bytes) return NO;
    const uint8_t *p = (const uint8_t *)wire.bytes + sizeof(h); size_t n = h.header_bytes, i = 0;
    while (i < n) {
        /* Most headers are ASCII: skip eight nonzero ASCII bytes at once. */
        if (n - i >= 8) {
            uint64_t w; memcpy(&w, p + i, sizeof(w));
            const uint64_t high = UINT64_C(0x8080808080808080), ones = UINT64_C(0x0101010101010101);
            if (!(w & high) && !((w - ones) & ~w & high)) { i += 8; continue; }
        }
        uint8_t c = p[i];
        if (c < 0x80) { if (!c) return NO; ++i; continue; }
        if (c >= 0xc2 && c <= 0xdf) {
            if (n - i < 2 || (p[i+1] & 0xc0) != 0x80) return NO;
            i += 2; continue;
        }
        if (c >= 0xe0 && c <= 0xef) {
            if (n - i < 3 || (p[i+1] & 0xc0) != 0x80 || (p[i+2] & 0xc0) != 0x80 ||
                (c == 0xe0 && p[i+1] < 0xa0) || (c == 0xed && p[i+1] >= 0xa0)) return NO;
            i += 3; continue;
        }
        if (c >= 0xf0 && c <= 0xf4) {
            if (n - i < 4 || (p[i+1] & 0xc0) != 0x80 || (p[i+2] & 0xc0) != 0x80 ||
                (p[i+3] & 0xc0) != 0x80 || (c == 0xf0 && p[i+1] < 0x90) ||
                (c == 0xf4 && p[i+1] >= 0x90)) return NO;
            i += 4; continue;
        }
        return NO;
    }
    return YES;
}

#endif
