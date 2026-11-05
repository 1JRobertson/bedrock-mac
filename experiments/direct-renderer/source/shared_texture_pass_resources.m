#import "native_value_validation.h"
#import "shared_texture_pass_resources.h"
#import "native_owned_blobs.h"
#include "native_metadata_wire.h"
#include "frame_stream.h"
#include <CommonCrypto/CommonDigest.h>
#import <CoreFoundation/CoreFoundation.h>
#include <errno.h>
#include <fcntl.h>
#include <float.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>


/* Fixed generated leaf names only. Memory payloads are owned byte snapshots,
 * not filesystem identities: no uid/mode claims or descriptor fallback. */
static NSUInteger ffst_pass_indexed_blob(NSString *name,NSString *prefix,unsigned maximum) {
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
static NSUInteger ffst_pass_blob_limit(NSString *name) {
    if(![name isKindOfClass:[NSString class]]||!name.length||name.length>82)return 0;
    if([name isEqualToString:@"replay.json"]||[name isEqualToString:@"replay-template.json"])return 4u*1024u*1024u;
    if([name isEqualToString:@"bindings.json"]||[name isEqualToString:@"draw-resource-cut.json"])return 8u*1024u*1024u;
    if([name isEqualToString:@"draw-plan.bin"]||[name isEqualToString:@"draw-resource-cut.bin"]||
       [name isEqualToString:@"bindings.bin"])return FFMD_MAX_BYTES;
    if(ffst_pass_indexed_blob(name,@"cut-buffer-",FF_DRAW_RESOURCE_LIMIT)||ffst_pass_indexed_blob(name,@"cut-texture-",FF_TEXTURE_RESOURCE_LIMIT)||
       ffst_pass_indexed_blob(name,@"operation-buffer-",FFS_MAX_RESOURCES))return 32u*1024u*1024u;
    if(name.length!=82||![name hasPrefix:@"pass-lib-"]||![name hasSuffix:@".metallib"])return 0;
    for(NSUInteger i=9;i<73;++i){unichar c=[name characterAtIndex:i];if(!((c>='0'&&c<='9')||(c>='a'&&c<='f')))return 0;}
    return 8u*1024u*1024u;
}
static NSDictionary<NSString *,NSData *> *ffst_pass_blob_snapshot(id source) {
    if(![source isKindOfClass:[NSDictionary class]]||[source count]>8192)return nil;
    NSMutableDictionary<NSString *,NSData *> *result=[NSMutableDictionary dictionary];NSUInteger total=0;
    NSMutableArray<NSArray *> *entries=[NSMutableArray arrayWithCapacity:[source count]];
    /* Validate the complete metadata budget before touching any source bytes.
     * Oversized mmap payloads must not churn allocations on their way to reject. */
    for(id rawKey in source){
        if(![rawKey isKindOfClass:[NSString class]])return nil;
        NSString *name=[rawKey copy];NSUInteger maximum=ffst_pass_blob_limit(name);id value=source[rawKey];
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

#if !__has_feature(objc_arc)
#error shared_texture_pass_resources.m requires ARC
#endif

typedef struct {
    FFSTPassDrawInfo info;
    ff_draw_bindings bindings;
    ff_vertex_binding vertices[FF_VERTEX_RESOURCE_LIMIT];
    ff_vertex_binding constants[2][FF_CONSTANT_RESOURCE_LIMIT];
    ff_argument_binding arguments[2][FF_SHADER_FIELD_LIMIT];
    ff_vertex_binding index;
} FFSTDecodedDraw;
@interface FFSTPassResourceOwner : NSObject {
@public
    ff_vertex_snapshot snapshots[FF_DRAW_RESOURCE_LIMIT];
    ff_texture_snapshot textures[FF_TEXTURE_RESOURCE_LIMIT];
    ff_sampler_snapshot samplers[FF_SAMPLER_RESOURCE_LIMIT];
    uint64_t sourceOffsets[FF_DRAW_RESOURCE_LIMIT];
    BOOL provenance[FF_DRAW_RESOURCE_LIMIT];
    size_t snapshotCount, textureCount, samplerCount, drawCount;
    FFSTDecodedDraw *draws;
}
@property(nonatomic, strong) NSMutableArray<NSData *> *backing;
@end
@implementation FFSTPassResourceOwner
- (void)dealloc { free(draws); }
@end

/* NSNumber's double conversion loses integer identity above 2^53. Accept only
 * integer NSNumber representations, parse decimal bits and reject booleans. */
static BOOL number(id object,uint64_t maximum,uint64_t *out) {return ffst_value_u64(object,maximum,out);}
static BOOL signed32(id object,int32_t *out) {return ffst_value_i32(object,out);}
static BOOL array(id object, size_t maximum) {
    return [object isKindOfClass:[NSArray class]] && [object count] <= maximum;
}
static BOOL record(id object) { return [object isKindOfClass:[NSDictionary class]]; }
static BOOL same_stat(const struct stat *a, const struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino && a->st_mode == b->st_mode &&
        a->st_uid == b->st_uid && a->st_nlink == b->st_nlink && a->st_size == b->st_size &&
        a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec && a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec &&
        a->st_ctimespec.tv_sec == b->st_ctimespec.tv_sec && a->st_ctimespec.tv_nsec == b->st_ctimespec.tv_nsec;
}
typedef struct { int directory; NSDictionary<NSString *,NSData *> *__strong blobs; } FFSTPassSource;
static NSData *read_private_payload(int directory, const char *name, size_t length) {
    int fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat before, after;
    if (fstat(fd, &before) || !S_ISREG(before.st_mode) || before.st_uid != getuid() ||
        before.st_nlink != 1 || (before.st_mode & 077) || before.st_size <= 0 ||
        (uint64_t)before.st_size != length) { close(fd); return nil; }
    uint8_t *bytes = malloc(length); if (!bytes) { close(fd); return nil; }
    size_t consumed = 0; BOOL valid = YES;
    while (consumed < length) {
        ssize_t got = read(fd, bytes + consumed, length - consumed);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { valid = NO; break; }
        consumed += (size_t)got;
    }
    uint8_t extra; ssize_t tail;
    do { tail = read(fd, &extra, 1); } while (tail < 0 && errno == EINTR);
    if (tail || fstat(fd, &after) || !same_stat(&before, &after)) valid = NO;
    if (close(fd)) valid = NO;
    if (!valid) { free(bytes); return nil; }
    return [NSData dataWithBytesNoCopy:bytes length:length freeWhenDone:YES];
}
static NSData *read_payload(FFSTPassSource source,const char *name,size_t length) {
    if(source.blobs){
        NSData *data=source.blobs[@(name)];
        return [data isKindOfClass:[NSData class]]&&data.length==length?data:nil;
    }
    return read_private_payload(source.directory,name,length);
}
static BOOL decode_binding(id object, FFSTPassResourceOwner *owner, ff_vertex_binding *out) {
    if (!record(object)) return NO;
    uint64_t sid, generation, offset, stride, length;
    if (!number(object[@"id"], owner->snapshotCount, &sid) ||
        !number(object[@"generation"], UINT32_MAX, &generation) ||
        !number(object[@"offset"], FF_VERTEX_BYTES_LIMIT, &offset) ||
        !number(object[@"stride"], UINT32_MAX, &stride) ||
        !number(object[@"length"], UINT32_MAX, &length)) return NO;
    if (!sid) {
        if (generation || offset || stride || length) return NO;
    } else {
        const ff_vertex_snapshot *source = &owner->snapshots[sid - 1];
        if (generation != source->generation || offset > source->length || length > source->length - offset) return NO;
    }
    *out = (ff_vertex_binding){sid, generation, offset, (uint32_t)stride, (uint32_t)length}; return YES;
}
static BOOL decode_snapshots(FFSTPassSource source, NSDictionary *graph, FFSTPassResourceOwner *owner) {
    NSArray *records = graph[@"snapshots"]; if (!array(records, FF_DRAW_RESOURCE_LIMIT)) return NO;
    owner->snapshotCount = records.count; size_t total = 0;
    for (size_t i = 0; i < records.count; ++i) {
        NSDictionary *r = records[i]; uint64_t sid, generation, length;
        if (!record(r) || !number(r[@"id"], FF_DRAW_RESOURCE_LIMIT, &sid) || sid != i + 1 ||
            !number(r[@"generation"], UINT32_MAX, &generation) || !generation ||
            !number(r[@"length"], FF_VERTEX_BYTES_LIMIT - total, &length) || !length) return NO;
        char name[32]; snprintf(name, sizeof(name), "cut-buffer-%02u.bin", (unsigned)(i + 1));
        if (![r[@"file"] isKindOfClass:[NSString class]] || ![r[@"file"] isEqualToString:@(name)]) return NO;
        if (r[@"source_incarnation"] || r[@"source_generation"] || r[@"source_offset"]) {
            uint64_t incarnation, sourceGeneration, offset;
            if (!number(r[@"source_incarnation"], UINT64_MAX, &incarnation) ||
                !number(r[@"source_generation"], UINT64_MAX, &sourceGeneration) ||
                !number(r[@"source_offset"], UINT64_MAX, &offset)) return NO;
            owner->provenance[i] = YES; owner->sourceOffsets[i] = offset;
        }
        NSData *data = read_payload(source, name, (size_t)length); if (!data) return NO;
        [owner.backing addObject:data]; total += data.length;
        owner->snapshots[i] = (ff_vertex_snapshot){sid, generation, data.bytes, data.length};
    }
    return YES;
}
static BOOL decode_textures(FFSTPassSource source, NSDictionary *graph, FFSTPassResourceOwner *owner) {
    NSArray *records = graph[@"textures"]; if (!array(records, FF_TEXTURE_RESOURCE_LIMIT)) return NO;
    owner->textureCount = records.count; size_t total = 0;
    for (size_t i = 0; i < records.count; ++i) {
        NSDictionary *r = records[i]; uint64_t sid, length;
        if (!record(r) || !number(r[@"id"], FF_TEXTURE_RESOURCE_LIMIT, &sid) || sid != i + 1 ||
            !number(r[@"length"], FF_TEXTURE_BYTES_LIMIT - total, &length) || !length) return NO;
        ff_texture_snapshot *s = &owner->textures[i]; s->id = sid; s->length = (size_t)length;
        const char *keys[] = {"format", "texture_type", "width", "height", "mip_count", "array_length"};
        uint32_t *values[] = {&s->format, &s->texture_type, &s->width, &s->height, &s->mip_count, &s->array_length};
        for (unsigned k = 0; k < 6; ++k) {
            uint64_t value; if (!number(r[@(keys[k])], UINT32_MAX, &value)) return NO; *values[k] = (uint32_t)value;
        }
        unsigned pixel = ff_texture_pixel_size(s->format);
        if (!pixel || !s->width || !s->height || s->width > 4096 || s->height > 4096 || !s->mip_count ||
            s->mip_count > 13 || s->mip_count > 32 - (uint32_t)__builtin_clz(MAX(s->width, s->height)) ||
            !s->array_length || s->array_length > 8 ||
            (s->texture_type != MTLTextureType2D && s->texture_type != MTLTextureType2DArray && s->texture_type != MTLTextureTypeCube) ||
            (s->texture_type == MTLTextureType2D && s->array_length != 1) ||
            (s->texture_type == MTLTextureTypeCube && (s->array_length != 1 || s->width != s->height))) return NO;
        id swizzle = r[@"swizzle"];
        if (swizzle) {
            if (!array(swizzle,4) || [swizzle count] != 4) return NO;
            s->has_swizzle = 1;
            for (unsigned channel=0;channel<4;++channel) {
                uint64_t value; if (!number(swizzle[channel],MTLTextureSwizzleAlpha,&value)) return NO;
                s->swizzle[channel] = (uint32_t)value;
            }
        }
        /* A cube's descriptor has arrayLength 1, but its six physical face
         * slices each carry the complete mip chain in Metal slice order. */
        uint32_t slices = s->texture_type == MTLTextureTypeCube ? 6 : s->array_length;
        NSArray *planes = r[@"planes"];
        if (!array(planes, FF_TEXTURE_PLANE_LIMIT) || planes.count != s->mip_count * slices) return NO;
        s->plane_count = (uint32_t)planes.count; size_t next = 0;
        for (size_t k = 0; k < planes.count; ++k) {
            NSDictionary *p = planes[k]; uint64_t mip, slice, offset, row, bytes;
            if (!record(p) || !number(p[@"mip"], s->mip_count - 1, &mip) || mip != k % s->mip_count ||
                !number(p[@"slice"], slices - 1, &slice) || slice != k / s->mip_count ||
                !number(p[@"offset"], length, &offset) || offset != next ||
                !number(p[@"row_bytes"], FF_TEXTURE_BYTES_LIMIT, &row) ||
                !number(p[@"length"], length, &bytes)) return NO;
            size_t width = MAX((size_t)1, s->width >> mip), height = MAX((size_t)1, s->height >> mip);
            size_t canonicalRow = (width * pixel + 255) & ~(size_t)255;
            if (row != canonicalRow || bytes != row * height || bytes > length - next) return NO;
            s->planes[k] = (ff_texture_plane){(uint32_t)mip, (uint32_t)slice, next, (size_t)row, (size_t)bytes};
            next += (size_t)bytes;
        }
        if (next != length) return NO;
        char name[32]; snprintf(name, sizeof(name), "cut-texture-%02u.bin", (unsigned)(i + 1));
        if (![r[@"file"] isKindOfClass:[NSString class]] || ![r[@"file"] isEqualToString:@(name)]) return NO;
        NSData *data = read_payload(source, name, (size_t)length); if (!data) return NO;
        [owner.backing addObject:data]; total += data.length; s->bytes = data.bytes;
    }
    return YES;
}
static BOOL decode_samplers(NSDictionary *graph, FFSTPassResourceOwner *owner) {
    NSArray *records = graph[@"samplers"]; if (!array(records, FF_SAMPLER_RESOURCE_LIMIT)) return NO;
    owner->samplerCount = records.count;
    for (size_t i = 0; i < records.count; ++i) {
        NSDictionary *r = records[i]; ff_sampler_snapshot *s = &owner->samplers[i]; uint64_t sid;
        if (!record(r) || !number(r[@"id"], FF_SAMPLER_RESOURCE_LIMIT, &sid) || sid != i + 1 ||
            !array(r[@"address"], 3) || [r[@"address"] count] != 3) return NO;
        s->id = sid;
        for (unsigned k = 0; k < 3; ++k) { uint64_t v; if (!number(r[@"address"][k], 5, &v)) return NO; s->address[k] = (uint32_t)v; }
        const char *keys[] = {"min_filter", "mag_filter", "mip_filter", "compare", "border", "max_anisotropy", "normalized", "lod_average"};
        uint32_t *values[] = {&s->min_filter, &s->mag_filter, &s->mip_filter, &s->compare, &s->border, &s->max_anisotropy, &s->normalized, &s->lod_average};
        const uint64_t limits[] = {1, 1, 2, 7, 2, 16, 1, 1};
        for (unsigned k = 0; k < 8; ++k) { uint64_t v; if (!number(r[@(keys[k])], limits[k], &v)) return NO; *values[k] = (uint32_t)v; }
        if (!s->max_anisotropy || ![r[@"lod_min"] isKindOfClass:[NSNumber class]] || ![r[@"lod_max"] isKindOfClass:[NSNumber class]] ||
            CFGetTypeID((__bridge CFTypeRef)r[@"lod_min"]) == CFBooleanGetTypeID() ||
            CFGetTypeID((__bridge CFTypeRef)r[@"lod_max"]) == CFBooleanGetTypeID()) return NO;
        double minimum = [r[@"lod_min"] doubleValue], maximum = [r[@"lod_max"] doubleValue];
        if (!isfinite(minimum) || !isfinite(maximum) || minimum < 0 || maximum < minimum || maximum > FLT_MAX) return NO;
        s->lod_min = (float)minimum; s->lod_max = (float)maximum;
    }
    return YES;
}
static BOOL decode_draw(NSDictionary *r, FFSTPassResourceOwner *owner, FFSTDecodedDraw *draw) {
    if (!record(r) || !array(r[@"draw"], 5) || [r[@"draw"] count] != 5) return NO;
    uint64_t primitive, mask;
    FFSTPassDrawInfo *info = &draw->info;
    if (!number(r[@"draw"][0], MTLPrimitiveTypeTriangleStrip, &primitive) ||
        !number(r[@"draw"][1], UINT32_MAX, &info->start) || !number(r[@"draw"][2], 10000000, &info->count) ||
        !number(r[@"draw"][3], 1000000, &info->instances) || !number(r[@"draw"][4], UINT32_MAX, &info->base_instance) ||
        !info->count || !info->instances || info->count > 10000000 / info->instances ||
        info->start > UINT32_MAX - info->count || !number(r[@"ia_slot_mask"], UINT32_MAX, &mask)) return NO;
    info->primitive = (uint32_t)primitive; info->ia_slot_mask = (uint32_t)mask;
    NSArray *vertices = r[@"bindings"];
    if (!array(vertices, FF_VERTEX_RESOURCE_LIMIT) || vertices.count != (size_t)__builtin_popcount((uint32_t)mask)) return NO;
    for (size_t i = 0; i < vertices.count; ++i) if (!decode_binding(vertices[i], owner, &draw->vertices[i])) return NO;
    ff_draw_bindings *bindings = &draw->bindings;
    bindings->vertices = draw->vertices; bindings->vertex_count = vertices.count;
    NSArray *constantsKeys = @[@"vertex_constants", @"fragment_constants"];
    NSArray *arguments = r[@"arguments"], *argumentBytes = r[@"argument_bytes"];
    if (!array(arguments, 2) || arguments.count != 2 || !array(argumentBytes, 2) || argumentBytes.count != 2) return NO;
    for (unsigned stage = 0; stage < 2; ++stage) {
        NSArray *constants = r[constantsKeys[stage]], *fields = arguments[stage]; uint64_t bytes;
        if (!array(constants, FF_CONSTANT_RESOURCE_LIMIT) || !array(fields, FF_SHADER_FIELD_LIMIT) ||
            !number(argumentBytes[stage], FF_SHADER_TABLE_BYTES_LIMIT, &bytes) || bytes != fields.count * 8) return NO;
        for (size_t i = 0; i < constants.count; ++i) if (!decode_binding(constants[i], owner, &draw->constants[stage][i])) return NO;
        bindings->constants[stage] = draw->constants[stage]; bindings->constant_count[stage] = constants.count;
        bindings->arguments[stage] = draw->arguments[stage]; bindings->argument_count[stage] = fields.count; bindings->argument_bytes[stage] = (size_t)bytes;
        for (size_t i = 0; i < fields.count; ++i) {
            NSDictionary *field = fields[i]; uint64_t offset, kind, value;
            if (!record(field) || !number(field[@"offset"], bytes, &offset) || (offset & 7) || bytes - offset < 8 ||
                !number(field[@"kind"], FF_FIELD_VALUE, &kind) || !kind || !number(field[@"value"], UINT64_MAX, &value)) return NO;
            for (size_t k = 0; k < i; ++k) if (draw->arguments[stage][k].offset == offset) return NO;
            ff_argument_binding *argument = &draw->arguments[stage][i];
            argument->offset = (uint32_t)offset; argument->kind = (uint32_t)kind; argument->value = value;
            if (kind == FF_FIELD_BUFFER) {
                if (value || !decode_binding(field[@"buffer"], owner, &argument->buffer)) return NO;
            } else if (field[@"buffer"] || (kind == FF_FIELD_TEXTURE && value > owner->textureCount) ||
                (kind == FF_FIELD_SAMPLER && value > owner->samplerCount)) return NO;
        }
    }
    if (r[@"indexed"]) {
        NSDictionary *indexed = r[@"indexed"]; uint64_t type;
        if (!record(indexed) || !number(indexed[@"index_type"], 1, &type) ||
            !signed32(indexed[@"base_vertex"], &info->base_vertex) ||
            !number(indexed[@"index_count"], 10000000, &info->index_count) || info->index_count != info->count || info->start ||
            !number(indexed[@"index_offset"], UINT64_MAX, &info->index_offset) ||
            !decode_binding(r[@"index_binding"], owner, &draw->index) || !draw->index.id || draw->index.stride) return NO;
        size_t width = type ? 4 : 2;
        if (info->index_offset % width || draw->index.offset % width || info->index_count > draw->index.length / width) return NO;
        size_t slot = (size_t)draw->index.id - 1;
        if (owner->provenance[slot] && (owner->sourceOffsets[slot] > UINT64_MAX - draw->index.offset ||
            info->index_offset != owner->sourceOffsets[slot] + draw->index.offset)) return NO;
        info->indexed = 1; info->index_type = (uint32_t)type; bindings->index = &draw->index;
    } else if (r[@"index_binding"]) return NO;
    bindings->textures = owner->textures; bindings->texture_count = owner->textureCount;
    bindings->samplers = owner->samplers; bindings->sampler_count = owner->samplerCount; return YES;
}

/* FFMD1 graph rows are copied into the same validated C owner as v2 JSON.
 * Immutable plan topology is separate from per-frame values and asset bytes. */
static BOOL wire_binding(const ffmd_view *graph,size_t index,FFSTPassResourceOwner *owner,ff_vertex_binding *out) {
    ffmd_graph_binding row;
    if(!ffmd_view_row(graph,2,index,&row,sizeof(row))||row.id>owner->snapshotCount||
       row.offset>FF_VERTEX_BYTES_LIMIT)return NO;
    if(!row.id){if(row.generation||row.offset||row.stride||row.length)return NO;}
    else {const ff_vertex_snapshot *source=&owner->snapshots[row.id-1];
        if(row.generation!=source->generation||row.offset>source->length||row.length>source->length-row.offset)return NO;}
    *out=(ff_vertex_binding){row.id,row.generation,row.offset,row.stride,row.length};return YES;
}
static BOOL wire_snapshots(FFSTPassSource source,const ffmd_view *graph,FFSTPassResourceOwner *owner) {
    size_t count=graph->sections[0].count,total=0;
    if(count>FF_DRAW_RESOURCE_LIMIT)return NO;owner->snapshotCount=count;
    for(size_t i=0;i<count;++i){ffmd_graph_snapshot row;
        if(!ffmd_view_row(graph,0,i,&row,sizeof(row))||!row.generation||
           row.has_provenance>1||(!row.has_provenance&&(row.source_incarnation||row.source_generation||row.source_offset))||
           !row.length||row.length>FF_VERTEX_BYTES_LIMIT-total)return NO;
        char name[32];snprintf(name,sizeof(name),"cut-buffer-%02u.bin",(unsigned)(i+1));
        NSData *data=read_payload(source,name,(size_t)row.length);if(!data)return NO;
        [owner.backing addObject:data];total+=data.length;
        owner->provenance[i]=row.has_provenance;owner->sourceOffsets[i]=row.source_offset;
        owner->snapshots[i]=(ff_vertex_snapshot){i+1,row.generation,data.bytes,data.length};
    }
    return YES;
}
static BOOL wire_textures(FFSTPassSource source,const ffmd_view *graph,FFSTPassResourceOwner *owner) {
    size_t count=graph->sections[4].count,total=0,nextPlane=0;
    if(count>FF_TEXTURE_RESOURCE_LIMIT||graph->sections[5].count>FF_TEXTURE_RESOURCE_LIMIT*FF_TEXTURE_PLANE_LIMIT)return NO;
    owner->textureCount=count;
    for(size_t i=0;i<count;++i){ffmd_graph_texture row;
        if(!ffmd_view_row(graph,4,i,&row,sizeof(row))||!row.length||row.length>FF_TEXTURE_BYTES_LIMIT-total||
           row.has_swizzle>1||(!row.has_swizzle&&(row.swizzle[0]||row.swizzle[1]||row.swizzle[2]||row.swizzle[3]))||
           row.plane_first!=nextPlane||row.plane_count>FF_TEXTURE_PLANE_LIMIT||
           row.plane_count>graph->sections[5].count-nextPlane)return NO;
        ff_texture_snapshot *s=&owner->textures[i];s->id=i+1;s->length=(size_t)row.length;
        s->format=row.format;s->texture_type=row.texture_type;s->width=row.width;s->height=row.height;
        s->mip_count=row.mip_count;s->array_length=row.array_length;s->has_swizzle=row.has_swizzle;
        unsigned pixel=ff_texture_pixel_size(s->format);
        if(!pixel||!s->width||!s->height||s->width>4096||s->height>4096||!s->mip_count||
           s->mip_count>13||s->mip_count>32-(uint32_t)__builtin_clz(MAX(s->width,s->height))||
           !s->array_length||s->array_length>8||
           (s->texture_type!=MTLTextureType2D&&s->texture_type!=MTLTextureType2DArray&&s->texture_type!=MTLTextureTypeCube)||
           (s->texture_type==MTLTextureType2D&&s->array_length!=1)||
           (s->texture_type==MTLTextureTypeCube&&(s->array_length!=1||s->width!=s->height)))return NO;
        for(unsigned k=0;k<4;++k){if(row.swizzle[k]>MTLTextureSwizzleAlpha)return NO;s->swizzle[k]=row.swizzle[k];}
        uint32_t slices=s->texture_type==MTLTextureTypeCube?6:s->array_length;
        if(row.plane_count!=s->mip_count*slices)return NO;
        s->plane_count=row.plane_count;size_t next=0;
        for(size_t k=0;k<row.plane_count;++k){ffmd_graph_texture_plane plane;
            if(!ffmd_view_row(graph,5,nextPlane+k,&plane,sizeof(plane))||
               plane.mip!=k%s->mip_count||plane.slice!=k/s->mip_count||plane.offset!=next)return NO;
            size_t width=MAX((size_t)1,s->width>>plane.mip),height=MAX((size_t)1,s->height>>plane.mip);
            size_t canonicalRow=(width*pixel+255)&~(size_t)255;
            if(plane.row_bytes!=canonicalRow||plane.length!=canonicalRow*height||plane.length>row.length-next)return NO;
            s->planes[k]=(ff_texture_plane){plane.mip,plane.slice,next,(size_t)plane.row_bytes,(size_t)plane.length};
            next+=(size_t)plane.length;
        }
        if(next!=row.length)return NO;nextPlane+=row.plane_count;
        char name[32];snprintf(name,sizeof(name),"cut-texture-%02u.bin",(unsigned)(i+1));
        NSData *data=read_payload(source,name,(size_t)row.length);if(!data)return NO;
        [owner.backing addObject:data];total+=data.length;s->bytes=data.bytes;
    }
    return nextPlane==graph->sections[5].count;
}
static BOOL wire_samplers(const ffmd_view *graph,FFSTPassResourceOwner *owner) {
    size_t count=graph->sections[6].count;if(count>FF_SAMPLER_RESOURCE_LIMIT)return NO;owner->samplerCount=count;
    for(size_t i=0;i<count;++i){ffmd_graph_sampler row;
        if(!ffmd_view_row(graph,6,i,&row,sizeof(row)))return NO;
        ff_sampler_snapshot *s=&owner->samplers[i];s->id=i+1;
        for(unsigned k=0;k<3;++k){if(row.address[k]>5)return NO;s->address[k]=row.address[k];}
        if(row.min_filter>1||row.mag_filter>1||row.mip_filter>2||row.compare>7||row.border>2||
           !row.max_anisotropy||row.max_anisotropy>16||row.normalized>1||row.lod_average>1)return NO;
        s->min_filter=row.min_filter;s->mag_filter=row.mag_filter;s->mip_filter=row.mip_filter;
        s->compare=row.compare;s->border=row.border;s->max_anisotropy=row.max_anisotropy;
        s->normalized=row.normalized;s->lod_average=row.lod_average;
        memcpy(&s->lod_min,&row.lod_min_bits,sizeof(float));memcpy(&s->lod_max,&row.lod_max_bits,sizeof(float));
        if(!isfinite(s->lod_min)||!isfinite(s->lod_max)||s->lod_min<0||s->lod_max<s->lod_min)return NO;
    }
    return YES;
}
static BOOL wire_draws(const ffmd_view *plan,const ffmd_view *graph,FFSTPassResourceOwner *owner) {
    size_t count=plan->sections[0].count;
    if(!count||count>FFST_PASS_DRAW_LIMIT||graph->sections[1].count!=count)return NO;
    owner->drawCount=count;owner->draws=calloc(count,sizeof(*owner->draws));if(!owner->draws)return NO;
    size_t ordinaryEnd=0;
    for(size_t i=0;i<count;++i){ffmd_plan_draw p;
        if(!ffmd_view_row(plan,0,i,&p,sizeof(p))||p.reserved||p.indexed>1||p.index_type>1||
           (!p.indexed&&p.index_type)||p.primitive>MTLPrimitiveTypeTriangleStrip||
           p.vertex_count!=__builtin_popcount(p.ia_slot_mask)||p.vertex_count>FF_VERTEX_RESOURCE_LIMIT||
           p.constant_count[0]>FF_CONSTANT_RESOURCE_LIMIT||p.constant_count[1]>FF_CONSTANT_RESOURCE_LIMIT||
           p.argument_count[0]>FF_SHADER_FIELD_LIMIT||p.argument_count[1]>FF_SHADER_FIELD_LIMIT)return NO;
        size_t width=p.vertex_count+p.constant_count[0]+p.constant_count[1]+p.indexed;
        if(width>graph->sections[2].count-ordinaryEnd)return NO;ordinaryEnd+=width;
    }
    size_t binding=0,argument=0,slot=0,trailing=ordinaryEnd;uint64_t invocations=0;
    for(size_t i=0;i<count;++i){ffmd_plan_draw p;ffmd_graph_draw g;
        if(!ffmd_view_row(plan,0,i,&p,sizeof(p))||!ffmd_view_row(graph,1,i,&g,sizeof(g))||
           g.binding_first!=binding||g.argument_first!=argument||p.argument_slot_first[0]!=slot||
           p.argument_slot_first[1]!=slot+p.argument_count[0]||
           p.argument_count[0]+p.argument_count[1]>plan->sections[1].count-slot||
           p.argument_count[0]+p.argument_count[1]>graph->sections[3].count-argument||
           g.index_binding!=(p.indexed?binding+p.vertex_count+p.constant_count[0]+p.constant_count[1]:FFMD_NO_BINDING))return NO;
        FFSTDecodedDraw *draw=&owner->draws[i];FFSTPassDrawInfo *info=&draw->info;ff_draw_bindings *out=&draw->bindings;
        if(!g.count||g.count>10000000||!g.instances||g.instances>1000000||
           g.count>10000000/g.instances||g.start>UINT32_MAX-g.count||
           g.count*g.instances>10000000-invocations)return NO;
        invocations+=g.count*g.instances;
        info->primitive=p.primitive;info->ia_slot_mask=p.ia_slot_mask;info->start=g.start;info->count=g.count;
        info->instances=g.instances;info->base_instance=g.base_instance;info->indexed=p.indexed;
        info->index_type=p.index_type;info->base_vertex=g.base_vertex;
        info->index_count=g.index_count;info->index_offset=g.index_offset;
        out->vertices=draw->vertices;out->vertex_count=p.vertex_count;
        for(size_t k=0;k<p.vertex_count;++k)if(!wire_binding(graph,binding++,owner,&draw->vertices[k]))return NO;
        for(unsigned stage=0;stage<2;++stage){out->constants[stage]=draw->constants[stage];
            out->constant_count[stage]=p.constant_count[stage];
            for(size_t k=0;k<p.constant_count[stage];++k)
                if(!wire_binding(graph,binding++,owner,&draw->constants[stage][k]))return NO;}
        if(p.indexed){if(g.start||g.index_count!=g.count||
            !wire_binding(graph,binding++,owner,&draw->index)||!draw->index.id||draw->index.stride)return NO;
            size_t width=p.index_type?4:2;
            if(g.index_offset%width||draw->index.offset%width||g.index_count>draw->index.length/width)return NO;
            size_t snapshot=(size_t)draw->index.id-1;
            if(owner->provenance[snapshot]&&(owner->sourceOffsets[snapshot]>UINT64_MAX-draw->index.offset||
               g.index_offset!=owner->sourceOffsets[snapshot]+draw->index.offset))return NO;
            out->index=&draw->index;
        }else if(g.base_vertex||g.index_count||g.index_offset)return NO;
        for(unsigned stage=0;stage<2;++stage){size_t fields=p.argument_count[stage],bytes=fields*8;
            if(bytes>FF_SHADER_TABLE_BYTES_LIMIT)return NO;
            out->arguments[stage]=draw->arguments[stage];out->argument_count[stage]=fields;out->argument_bytes[stage]=bytes;
            for(size_t k=0;k<fields;++k){ffmd_plan_argument_slot a;ffmd_graph_argument_value value;
                if(!ffmd_view_row(plan,1,slot++,&a,sizeof(a))||
                   !ffmd_view_row(graph,3,argument++,&value,sizeof(value))||value.reserved||
                   a.offset%8||a.offset>bytes||bytes-a.offset<8||a.kind<FF_FIELD_BUFFER||a.kind>FF_FIELD_VALUE)return NO;
                for(size_t j=0;j<k;++j)if(draw->arguments[stage][j].offset==a.offset)return NO;
                ff_argument_binding *field=&draw->arguments[stage][k];field->offset=a.offset;
                field->kind=a.kind;field->value=value.value;
                if(a.kind==FF_FIELD_BUFFER){if(value.value||value.buffer_binding!=trailing||
                    !wire_binding(graph,trailing++,owner,&field->buffer))return NO;}
                else if(value.buffer_binding!=FFMD_NO_BINDING||
                    (a.kind==FF_FIELD_TEXTURE&&value.value>owner->textureCount)||
                    (a.kind==FF_FIELD_SAMPLER&&value.value>owner->samplerCount))return NO;
            }
        }
        out->textures=owner->textures;out->texture_count=owner->textureCount;
        out->samplers=owner->samplers;out->sampler_count=owner->samplerCount;
    }
    return binding==ordinaryEnd&&trailing==graph->sections[2].count&&
        argument==graph->sections[3].count&&slot==plan->sections[1].count;
}
static FFSTPassResources ffst_pass_resources_load_wire_source(FFSTPassSource source,NSData *planBytes,NSData *graphBytes) {
    ffmd_view plan,graph;
    if(![planBytes isKindOfClass:[NSData class]]||![graphBytes isKindOfClass:[NSData class]]||
       !ffmd_view_decode(planBytes.bytes,planBytes.length,FFMD_PLAN,&plan)||
       !ffmd_view_decode(graphBytes.bytes,graphBytes.length,FFMD_GRAPH,&graph))return NULL;
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];CC_SHA256(planBytes.bytes,(CC_LONG)planBytes.length,digest);
    if(memcmp(digest,graph.header.plan_sha256,sizeof(digest)))return NULL;
    FFSTPassResourceOwner *owner=[FFSTPassResourceOwner new];owner.backing=[NSMutableArray arrayWithObjects:planBytes,graphBytes,nil];
    if(!wire_snapshots(source,&graph,owner)||!wire_textures(source,&graph,owner)||
       !wire_samplers(&graph,owner)||!wire_draws(&plan,&graph,owner))return NULL;
    return (__bridge_retained void *)owner;
}
static FFSTPassResources ffst_pass_resources_load_source(FFSTPassSource source, NSDictionary *graph) {
    @try {
        struct stat state; uint64_t version;
        BOOL validSource=source.blobs!=nil || (source.directory>=0 && !fstat(source.directory,&state) &&
            S_ISDIR(state.st_mode) && state.st_uid==getuid() && !(state.st_mode&077));
        if (!validSource || !record(graph) || ![graph[@"format"] isKindOfClass:[NSString class]] ||
            ![graph[@"format"] isEqualToString:@"bedrock-draw-resource-cut"] || !number(graph[@"version"], 2, &version) || (version != 1 && version != 2) ||
            !array(graph[@"draws"], FFST_PASS_DRAW_LIMIT) || ![graph[@"draws"] count]) return NULL;
        FFSTPassResourceOwner *owner = [FFSTPassResourceOwner new]; owner.backing = [NSMutableArray array];
        if (!decode_snapshots(source, graph, owner) || !decode_textures(source, graph, owner) || !decode_samplers(graph, owner)) return NULL;
        owner->drawCount = [graph[@"draws"] count]; owner->draws = calloc(owner->drawCount, sizeof(*owner->draws));
        if (!owner->draws) return NULL;
        uint64_t invocations = 0;
        for (size_t i = 0; i < owner->drawCount; ++i) {
            if (!decode_draw(graph[@"draws"][i], owner, &owner->draws[i])) return NULL;
            uint64_t work = owner->draws[i].info.count * owner->draws[i].info.instances;
            if (work > 10000000 - invocations) return NULL; invocations += work;
        }
        return (__bridge_retained void *)owner;
    } @catch (NSException *exception) { (void)exception; return NULL; }
}
FFSTPassResources ffst_pass_resources_load(int directory,NSDictionary *graph) {
    return ffst_pass_resources_load_source((FFSTPassSource){directory,nil},graph);
}
FFSTPassResources ffst_pass_resources_load_blobs(NSDictionary<NSString *,NSData *> *blobs) {
    @try {
        NSDictionary *owned=ffst_pass_blob_snapshot(blobs);if(!owned)return NULL;
        NSData *manifest=owned[@"draw-resource-cut.json"];if(!manifest)return NULL;
        id graph=[NSJSONSerialization JSONObjectWithData:manifest options:0 error:nil];
        return ffst_pass_resources_load_source((FFSTPassSource){-1,owned},graph);
    }@catch(__unused NSException *exception){return NULL;}
}
FFSTPassResources ffst_pass_resources_load_wire_blobs(NSDictionary<NSString *,NSData *> *blobs) {
    @try {NSDictionary *owned=ffst_pass_blob_snapshot(blobs);if(!owned)return NULL;
        return ffst_pass_resources_load_wire_source((FFSTPassSource){-1,owned},
            owned[@"draw-plan.bin"],owned[@"draw-resource-cut.bin"]);
    }@catch(__unused NSException *exception){return NULL;}
}
FFSTPassResources ffst_pass_resources_load_owned(FFSTOwnedBlobs *owned) {
    if(!ffst_owned_blob_bounds(owned,ffst_pass_blob_limit))return NULL;
    NSDictionary *envelope=[owned jsonDictionary:@"draw-resource-cut.json"];
    if([envelope[@"version"] isEqual:@3]){
        if(![envelope[@"wire_blob"] isEqual:@"draw-resource-cut.bin"]||
           ![envelope[@"plan_blob"] isEqual:@"draw-plan.bin"])return NULL;
        NSData *plan=owned.blobs[@"draw-plan.bin"],*graph=owned.blobs[@"draw-resource-cut.bin"];
        NSData *planDigest=plan?[owned verifiedDigestForBytes:plan.bytes length:plan.length]:nil;
        NSData *graphDigest=graph?[owned verifiedDigestForBytes:graph.bytes length:graph.length]:nil;
        if(planDigest.length!=32||graphDigest.length!=32)return NULL;
        const char *names[]={"plan_sha256","wire_sha256"};NSData *digests[]={planDigest,graphDigest};
        for(unsigned k=0;k<2;++k){NSString *hex=envelope[@(names[k])];if(![hex isKindOfClass:[NSString class]]||hex.length!=64)return NULL;
            const uint8_t *raw=digests[k].bytes;for(unsigned i=0;i<32;++i){char pair[3];snprintf(pair,3,"%02x",raw[i]);
                if([hex characterAtIndex:2*i]!=(unichar)pair[0]||[hex characterAtIndex:2*i+1]!=(unichar)pair[1])return NULL;}}
        return ffst_pass_resources_load_wire_source((FFSTPassSource){-1,owned.blobs},plan,graph);
    }
    return ffst_pass_resources_load_source((FFSTPassSource){-1,owned.blobs},[owned jsonDictionary:@"draw-resource-cut.json"]);
}
void ffst_pass_resources_destroy(FFSTPassResources resources) {
    if (!resources) return; id owner = CFBridgingRelease(resources); (void)owner;
}
const ff_vertex_snapshot *ffst_pass_resources_snapshots(FFSTPassResources resources, size_t *count) {
    if (count) *count = 0; if (!resources) return NULL;
    FFSTPassResourceOwner *owner = (__bridge FFSTPassResourceOwner *)resources;
    if (count) *count = owner->snapshotCount; return owner->snapshots;
}
int ffst_pass_resources_snapshot_source_offset(FFSTPassResources resources,size_t index,uint64_t *out) {
    if(!resources||!out)return 0;FFSTPassResourceOwner *owner=(__bridge FFSTPassResourceOwner *)resources;
    if(index>=owner->snapshotCount||!owner->provenance[index])return 0;
    *out=owner->sourceOffsets[index];return 1;
}
const ff_texture_snapshot *ffst_pass_resources_textures(FFSTPassResources resources, size_t *count) {
    if (count) *count = 0; if (!resources) return NULL;
    FFSTPassResourceOwner *owner = (__bridge FFSTPassResourceOwner *)resources;
    if (count) *count = owner->textureCount; return owner->textures;
}
const ff_sampler_snapshot *ffst_pass_resources_samplers(FFSTPassResources resources, size_t *count) {
    if (count) *count = 0; if (!resources) return NULL;
    FFSTPassResourceOwner *owner = (__bridge FFSTPassResourceOwner *)resources;
    if (count) *count = owner->samplerCount; return owner->samplers;
}
size_t ffst_pass_resources_draw_count(FFSTPassResources resources) {
    return resources ? ((__bridge FFSTPassResourceOwner *)resources)->drawCount : 0;
}
int ffst_pass_resources_draw_info(FFSTPassResources resources, size_t index, FFSTPassDrawInfo *out) {
    if (!out) return 0; memset(out, 0, sizeof(*out)); if (!resources) return 0;
    FFSTPassResourceOwner *owner = (__bridge FFSTPassResourceOwner *)resources;
    if (index >= owner->drawCount) return 0; *out = owner->draws[index].info; return 1;
}
int ffst_pass_resources_draw_bindings(FFSTPassResources resources, size_t index,
    const ff_draw_layout *expected, ff_draw_bindings *out) {
    if (!out) return 0; memset(out, 0, sizeof(*out)); if (!resources || !expected) return 0;
    FFSTPassResourceOwner *owner = (__bridge FFSTPassResourceOwner *)resources;
    if (index >= owner->drawCount) return 0; FFSTDecodedDraw *draw = &owner->draws[index];
    if (expected->ia_slot_mask != draw->info.ia_slot_mask) return 0;
    for (unsigned stage = 0; stage < 2; ++stage) {
        const ff_shader_table_layout *table = &expected->arguments[stage];
        if (expected->constant_count[stage] != draw->bindings.constant_count[stage] ||
            table->field_count != draw->bindings.argument_count[stage] || table->field_count > FF_SHADER_FIELD_LIMIT ||
            table->byte_length != draw->bindings.argument_bytes[stage]) return 0;
        for (size_t i = 0; i < table->field_count; ++i) {
            const ff_shader_field *field = &table->fields[i];
            if ((field->offset & 7) || field->offset > table->byte_length || table->byte_length - field->offset < 8 ||
                field->kind < FF_FIELD_BUFFER || field->kind > FF_FIELD_VALUE) return 0;
            for (size_t k = 0; k < i; ++k) if (table->fields[k].offset == field->offset) return 0;
            BOOL found = NO;
            for (size_t k = 0; k < draw->bindings.argument_count[stage]; ++k)
                if (draw->arguments[stage][k].offset == field->offset && draw->arguments[stage][k].kind == field->kind) found = YES;
            if (!found) return 0;
        }
    }
    *out = draw->bindings; return 1;
}
