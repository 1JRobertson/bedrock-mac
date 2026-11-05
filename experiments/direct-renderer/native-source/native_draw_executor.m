/* ARM64 execution of a single bounded live DXMT draw, never a game replacement. */
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "vertex_resources.h"
#include "shader_bindings.h"
#include "native_presenter.h"
#include "shared_texture_executor.h"
#include "shared_texture_pass_execute.h"
#include "native_frame_worker.h"
#include "native_chunk_worker.h"
#include "chunk_stream.h"
#include "shared_snapshot_arena.h"
#include "readback_stream.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static long present_seconds;

static NSData *read_private(int dir, const char *name, size_t max) {
    int fd = openat(dir, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC); struct stat st;
    if (fd < 0) return nil;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_uid != getuid() || st.st_nlink != 1 ||
        (st.st_mode & 077) || st.st_size <= 0 || (uint64_t)st.st_size > max) { close(fd); return nil; }
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)st.st_size];
    uint8_t *p = data.mutableBytes; size_t left = data.length;
    while (left) { ssize_t n = read(fd, p, left); if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { close(fd); return nil; } p += n; left -= (size_t)n; }
    close(fd); return data;
}
static int write_private(int dir, const char *name, NSData *data) {
    int fd = openat(dir, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break; p += n; left -= (size_t)n; }
    int ok = !left && fsync(fd) == 0; if (close(fd)) ok = 0;
    if (!ok) unlinkat(dir, name, 0); return ok;
}
static int result(int dir, NSString *status, NSString *reason) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{ @"format": @"bedrock-live-draw-result", @"version": @1,
        @"status": status, @"reason": reason } options:0 error:nil];
    return data && write_private(dir, "replay-result.json", data);
}
static int presentation_stop_requested(int directory) {
    NSData *token = read_private(directory, "presentation.stop", 5);
    return token.length == 5 && !memcmp(token.bytes, "stop\n", 5);
}
static int present_output(int directory, id<MTLTexture> texture) {
    if (!present_seconds) return 0;
    char error[256] = {0};
    ff_native_presenter *presenter = ff_presenter_create((void *)texture.device,
        "ARM64 Metal output", (uint32_t)MIN(texture.width, 1200),
        (uint32_t)MIN(texture.height, 800), error, sizeof(error));
    ff_present_stats stats = {0};
    int accepted = presenter && ff_presenter_submit(presenter, (void *)texture, NULL, NULL);
    if (accepted) {
        struct timespec start, now; clock_gettime(CLOCK_MONOTONIC, &start);
        do {
            if (presentation_stop_requested(directory)) break;
            if (!ff_presenter_pump(presenter, 0.01)) break;
            clock_gettime(CLOCK_MONOTONIC, &now);
        } while (now.tv_sec - start.tv_sec < present_seconds);
    }
    if (presenter) {
        ff_presenter_close(presenter);
        for (unsigned i = 0; i < 5000; ++i) {
            ff_presenter_get_stats(presenter, &stats);
            if (!stats.in_flight) break;
            usleep(1000);
        }
        ff_presenter_destroy(presenter);
    }
    BOOL completed = accepted && stats.completed && !stats.gpu_errors && !stats.in_flight;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{
        @"format": @"bedrock-native-draw-presentation", @"version": @1,
        @"status": completed ? @"completed" : @"failed", @"accepted": @(stats.accepted),
        @"completed": @(stats.completed), @"gpu_errors": @(stats.gpu_errors),
        @"in_flight": @(stats.in_flight), @"scope": @"ARM-rendered output; rendering coverage is recorded in replay-result.json"
    } options:0 error:nil];
    return data && write_private(directory, "presentation-result.json", data) && completed ? 0 : 1;
}
static int nums(id obj, NSUInteger count) {
    if (![obj isKindOfClass:[NSArray class]] || [obj count] != count) return 0;
    for (id item in obj) if (![item isKindOfClass:[NSNumber class]] || !isfinite([item doubleValue])) return 0;
    return 1;
}
static int uint_value(id obj, uint64_t maximum, uint64_t *value) {
    if (![obj isKindOfClass:[NSNumber class]]) return 0;
    double number = [obj doubleValue];
    if (!isfinite(number) || number < 0 || floor(number) != number || number > (double)maximum) return 0;
    uint64_t integer = [obj unsignedLongLongValue];
    if (integer > maximum || (double)integer != number) return 0;
    *value = integer; return 1;
}
static int texture_swizzle(id record, ff_texture_snapshot *out) {
    if (!record) return 1;
    if (!nums(record,4)) return 0;
    uint32_t channels[4];
    for (unsigned i=0;i<4;++i) {
        id item=record[i]; const char *type=[item objCType]; uint64_t value;
        if (CFGetTypeID((CFTypeRef)item)==CFBooleanGetTypeID() || !type || !type[0] || type[1] ||
            !strchr("cCsSiIlLqQ",type[0]) || !uint_value(item,MTLTextureSwizzleAlpha,&value)) return 0;
        channels[i]=(uint32_t)value;
    }
    out->has_swizzle=1;memcpy(out->swizzle,channels,sizeof(channels));return 1;
}
static MTLStencilDescriptor *stencil_descriptor(id record) {
    if (!nums(record, 6)) return nil;
    uint64_t value;
    for (NSUInteger i = 0; i < 6; ++i) if (!uint_value(record[i], i < 4 ? 7 : UINT32_MAX, &value)) return nil;
    MTLStencilDescriptor *d = [[[MTLStencilDescriptor alloc] init] autorelease];
    d.stencilCompareFunction = [record[0] unsignedIntegerValue]; d.stencilFailureOperation = [record[1] unsignedIntegerValue];
    d.depthFailureOperation = [record[2] unsignedIntegerValue]; d.depthStencilPassOperation = [record[3] unsignedIntegerValue];
    d.readMask = [record[4] unsignedIntegerValue]; d.writeMask = [record[5] unsignedIntegerValue]; return d;
}
static id<MTLDepthStencilState> depth_state(id<MTLDevice> device, id record) {
    if (![record isKindOfClass:[NSDictionary class]]) return nil;
    uint64_t compare, write;
    if (!uint_value(record[@"compare"], 7, &compare) || !uint_value(record[@"write"], 1, &write)) return nil;
    MTLDepthStencilDescriptor *d = [[[MTLDepthStencilDescriptor alloc] init] autorelease];
    d.depthCompareFunction = compare; d.depthWriteEnabled = write;
    for (NSString *side in @[ @"front", @"back" ]) {
        id r = record[side]; MTLStencilDescriptor *s = r == [NSNull null] ? nil : stencil_descriptor(r);
        if (r != [NSNull null] && !s) return nil;
        if ([side isEqual:@"front"]) d.frontFaceStencil = s; else d.backFaceStencil = s;
    }
    return [device newDepthStencilStateWithDescriptor:d];
}
static int result_completed(int directory, NSDictionary *m, size_t stride, NSNumber *changed) {
    NSMutableDictionary *record = [@{ @"format": @"bedrock-live-draw-result", @"version": @1, @"status": @"completed",
        @"reason": @"captured original shader draw executed on ARM64 with native resource relocation; offscreen output",
        @"width": m[@"width"], @"height": m[@"height"], @"pixel_format": m[@"pixel_format"], @"row_bytes": @(stride),
        @"changed_pixels": changed ?: (id)[NSNull null], @"indexed": @(m[@"indexed"] != nil) } mutableCopy];
    if (m[@"resource_cut_id"]) record[@"resource_cut_id"] = m[@"resource_cut_id"];
    if (m[@"shared_attachment_cut"]) { record[@"shared_attachment_cut"] = m[@"shared_attachment_cut"]; record[@"load_attachments_owned"] = @YES; }
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil]; [record release];
    return data && write_private(directory, "replay-result.json", data);
}
/* Reads only producer-owned immutable snapshots. The resource-cut identifier,
 * exact draw tuple and packed slot mask must all describe this same draw. */
static int buffer_binding(id binding, ff_vertex_binding *out) {
    uint64_t sid, generation, offset, stride, length;
    if (![binding isKindOfClass:[NSDictionary class]] || !uint_value(binding[@"id"], FF_DRAW_RESOURCE_LIMIT, &sid) ||
        !uint_value(binding[@"generation"], UINT32_MAX, &generation) || !uint_value(binding[@"offset"], FF_VERTEX_BYTES_LIMIT, &offset) ||
        !uint_value(binding[@"stride"], UINT32_MAX, &stride) || !uint_value(binding[@"length"], UINT32_MAX, &length)) return 0;
    *out = (ff_vertex_binding){sid, generation, offset, (uint32_t)stride, (uint32_t)length}; return 1;
}
static ff_vertex_resources *vertex_resources(int dir, id<MTLDevice> device, NSDictionary *m, const ff_draw_layout *layout) {
    NSString *identifier = m[@"resource_cut_id"];
    uint64_t mask;
    if (![identifier isKindOfClass:[NSString class]] || !identifier.length || identifier.length > 128 ||
        !uint_value(m[@"ia_slot_mask"], UINT32_MAX, &mask) || mask != layout->ia_slot_mask) return NULL;
    NSData *bytes = read_private(dir, "draw-resource-cut.json", 262144);
    id cut = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    if (![cut isKindOfClass:[NSDictionary class]] || ![cut[@"format"] isEqual:@"bedrock-draw-resource-cut"] ||
        ![cut[@"version"] isEqual:@1] || ![cut[@"cut_id"] isEqual:identifier] ||
        ![cut[@"ia_slot_mask"] isEqual:m[@"ia_slot_mask"]]) return NULL;
    NSArray *draw = m[@"draw"];
    NSArray *keys = @[ @"primitive", @"vertex_start", @"vertex_count", @"instance_count", @"base_instance" ];
    for (NSUInteger i = 0; i < keys.count; ++i) if (![cut[keys[i]] isEqual:draw[i]]) return NULL;
    NSArray *snapshots = cut[@"snapshots"], *bindings = cut[@"bindings"];
    if (![snapshots isKindOfClass:[NSArray class]] || snapshots.count > FF_DRAW_RESOURCE_LIMIT ||
        ![bindings isKindOfClass:[NSArray class]] || bindings.count > FF_VERTEX_RESOURCE_LIMIT ||
        bindings.count != (NSUInteger)__builtin_popcount((uint32_t)mask)) return NULL;
    if ((m[@"indexed"] || cut[@"indexed"]) && ![m[@"indexed"] isEqual:cut[@"indexed"]]) return NULL;
    ff_vertex_snapshot source[FF_DRAW_RESOURCE_LIMIT] = {0};
    ff_vertex_binding bound[FF_VERTEX_RESOURCE_LIMIT] = {0};
    NSMutableArray *owned = [NSMutableArray array]; size_t total = 0;
    for (NSUInteger i = 0; i < snapshots.count; ++i) {
        id snapshot = snapshots[i]; uint64_t sid, generation, length;
        if (![snapshot isKindOfClass:[NSDictionary class]] || !uint_value(snapshot[@"id"], FF_DRAW_RESOURCE_LIMIT, &sid) ||
            sid != i + 1 || !uint_value(snapshot[@"generation"], UINT32_MAX, &generation) || !generation ||
            !uint_value(snapshot[@"length"], FF_VERTEX_BYTES_LIMIT - total, &length) || !length) return NULL;
        char name[32]; snprintf(name, sizeof(name), "cut-buffer-%02lu.bin", (unsigned long)(i + 1));
        if (![snapshot[@"file"] isEqual:[NSString stringWithUTF8String:name]]) return NULL;
        NSData *data = read_private(dir, name, FF_VERTEX_BYTES_LIMIT - total);
        if (!data || data.length != length) return NULL;
        [owned addObject:data]; total += data.length;
        source[i] = (ff_vertex_snapshot){sid, generation, data.bytes, data.length};
    }
    for (NSUInteger i = 0; i < bindings.count; ++i) {
        if (!buffer_binding(bindings[i], &bound[i])) return NULL;
    }
    ff_draw_bindings draw_bindings = {0}; draw_bindings.vertices = bound; draw_bindings.vertex_count = bindings.count;
    ff_vertex_binding constants[2][FF_CONSTANT_RESOURCE_LIMIT] = {0}, index;
    ff_argument_binding arguments[2][FF_SHADER_FIELD_LIMIT] = {0};
    NSArray *constant_keys = @[ @"vertex_constants", @"fragment_constants" ];
    NSArray *argument_arrays = cut[@"arguments"] ?: @[ @[], @[] ];
    NSArray *argument_lengths = cut[@"argument_bytes"] ?: @[ @0, @0 ];
    if (![argument_arrays isKindOfClass:[NSArray class]] || argument_arrays.count != 2 || !nums(argument_lengths, 2)) return NULL;
    for (unsigned stage = 0; stage < 2; ++stage) {
        NSArray *array = cut[constant_keys[stage]] ?: @[];
        if (![array isKindOfClass:[NSArray class]] || array.count != layout->constant_count[stage] || array.count > FF_CONSTANT_RESOURCE_LIMIT) return NULL;
        for (NSUInteger i = 0; i < array.count; ++i) if (!buffer_binding(array[i], &constants[stage][i])) return NULL;
        draw_bindings.constants[stage] = constants[stage]; draw_bindings.constant_count[stage] = array.count;
        NSArray *fields = argument_arrays[stage]; uint64_t bytes;
        if (![fields isKindOfClass:[NSArray class]] || fields.count != layout->arguments[stage].field_count || fields.count > FF_SHADER_FIELD_LIMIT ||
            !uint_value(argument_lengths[stage], FF_SHADER_TABLE_BYTES_LIMIT, &bytes) || bytes != layout->arguments[stage].byte_length) return NULL;
        for (NSUInteger i = 0; i < fields.count; ++i) {
            id field = fields[i]; uint64_t offset, kind, value;
            if (![field isKindOfClass:[NSDictionary class]] || !uint_value(field[@"offset"], FF_SHADER_TABLE_BYTES_LIMIT, &offset) ||
                !uint_value(field[@"kind"], FF_FIELD_VALUE, &kind) || !kind || !uint_value(field[@"value"], UINT64_MAX, &value)) return NULL;
            int found = 0;
            for (NSUInteger j = 0; j < fields.count; ++j) if (layout->arguments[stage].fields[j].offset == offset && layout->arguments[stage].fields[j].kind == kind) found = 1;
            if (!found) return NULL;
            for (NSUInteger j = 0; j < i; ++j) if (arguments[stage][j].offset == offset) return NULL;
            arguments[stage][i] = (ff_argument_binding){.offset=(uint32_t)offset, .kind=(uint32_t)kind, .value=value};
            if (kind == FF_FIELD_BUFFER && !buffer_binding(field[@"buffer"], &arguments[stage][i].buffer)) return NULL;
        }
        draw_bindings.arguments[stage] = arguments[stage]; draw_bindings.argument_count[stage] = fields.count; draw_bindings.argument_bytes[stage] = bytes;
    }
    if (m[@"indexed"]) {
        if (!buffer_binding(cut[@"index_binding"], &index)) return NULL;
        uint64_t type, count, original_offset;
        if (!uint_value(m[@"indexed"][@"index_type"], 1, &type) || !uint_value(m[@"indexed"][@"index_count"], 10000000, &count) ||
            !uint_value(m[@"indexed"][@"index_offset"], UINT64_MAX, &original_offset) || index.stride ||
            index.offset % (type ? 4 : 2) || original_offset % (type ? 4 : 2) || count > index.length / (type ? 4 : 2)) return NULL;
        draw_bindings.index = &index;
    } else if (cut[@"index_binding"]) return NULL;
    NSArray *textures = cut[@"textures"] ?: @[], *samplers = cut[@"samplers"] ?: @[];
    if (![textures isKindOfClass:[NSArray class]] || textures.count > FF_TEXTURE_RESOURCE_LIMIT ||
        ![samplers isKindOfClass:[NSArray class]] || samplers.count > FF_SAMPLER_RESOURCE_LIMIT) return NULL;
    ff_texture_snapshot texture_source[FF_TEXTURE_RESOURCE_LIMIT] = {0}; size_t texture_bytes = 0;
    for (NSUInteger i = 0; i < textures.count; ++i) {
        id texture = textures[i]; uint64_t sid, length;
        if (![texture isKindOfClass:[NSDictionary class]] || !uint_value(texture[@"id"], FF_TEXTURE_RESOURCE_LIMIT, &sid) || sid != i + 1 ||
            !uint_value(texture[@"length"], FF_TEXTURE_BYTES_LIMIT - texture_bytes, &length) || !length) return NULL;
        char name[32]; snprintf(name, sizeof(name), "cut-texture-%02lu.bin", (unsigned long)(i + 1));
        if (![texture[@"file"] isEqual:@(name)]) return NULL;
        NSData *data = read_private(dir, name, FF_TEXTURE_BYTES_LIMIT - texture_bytes); if (!data || data.length != length) return NULL;
        [owned addObject:data]; texture_bytes += data.length;
        ff_texture_snapshot *s = &texture_source[i]; s->id = sid; s->bytes = data.bytes; s->length = data.length;
        const char *keys[] = {"format","texture_type","width","height","mip_count","array_length"};
        uint32_t *dest[] = {&s->format,&s->texture_type,&s->width,&s->height,&s->mip_count,&s->array_length};
        for (unsigned j = 0; j < 6; ++j) { uint64_t value; if (!uint_value(texture[@(keys[j])], UINT32_MAX, &value)) return NULL; *dest[j]=(uint32_t)value; }
        if (!texture_swizzle(texture[@"swizzle"],s)) return NULL;
        NSArray *planes = texture[@"planes"];
        if (![planes isKindOfClass:[NSArray class]] || !planes.count || planes.count > FF_TEXTURE_PLANE_LIMIT) return NULL;
        s->plane_count = (uint32_t)planes.count;
        for (NSUInteger j = 0; j < planes.count; ++j) {
            id p = planes[j]; uint64_t mip, slice, offset, row_bytes, bytes;
            if (![p isKindOfClass:[NSDictionary class]] || !uint_value(p[@"mip"], 31, &mip) || !uint_value(p[@"slice"], UINT32_MAX, &slice) ||
                !uint_value(p[@"offset"], length, &offset) || !uint_value(p[@"row_bytes"], FF_TEXTURE_BYTES_LIMIT, &row_bytes) ||
                !uint_value(p[@"length"], length, &bytes) || bytes > length - offset) return NULL;
            s->planes[j] = (ff_texture_plane){(uint32_t)mip,(uint32_t)slice,(size_t)offset,(size_t)row_bytes,(size_t)bytes};
        }
    }
    ff_sampler_snapshot sampler_source[FF_SAMPLER_RESOURCE_LIMIT] = {0};
    for (NSUInteger i = 0; i < samplers.count; ++i) {
        id sampler = samplers[i]; ff_sampler_snapshot *s = &sampler_source[i]; uint64_t sid;
        if (![sampler isKindOfClass:[NSDictionary class]] || !uint_value(sampler[@"id"], FF_SAMPLER_RESOURCE_LIMIT, &sid) || sid != i + 1 || !nums(sampler[@"address"],3)) return NULL;
        s->id = sid;
        for (unsigned j = 0; j < 3; ++j) { uint64_t value; if (!uint_value(sampler[@"address"][j], UINT32_MAX, &value)) return NULL; s->address[j]=(uint32_t)value; }
        const char *keys[] = {"min_filter","mag_filter","mip_filter","compare","border","max_anisotropy","normalized","lod_average"};
        uint32_t *dest[] = {&s->min_filter,&s->mag_filter,&s->mip_filter,&s->compare,&s->border,&s->max_anisotropy,&s->normalized,&s->lod_average};
        for (unsigned j = 0; j < 8; ++j) { uint64_t value; if (!uint_value(sampler[@(keys[j])], UINT32_MAX, &value)) return NULL; *dest[j]=(uint32_t)value; }
        if (![sampler[@"lod_min"] isKindOfClass:[NSNumber class]] || ![sampler[@"lod_max"] isKindOfClass:[NSNumber class]] ||
            !isfinite([sampler[@"lod_min"] doubleValue]) || !isfinite([sampler[@"lod_max"] doubleValue])) return NULL;
        s->lod_min = [sampler[@"lod_min"] floatValue]; s->lod_max = [sampler[@"lod_max"] floatValue];
    }
    draw_bindings.textures = texture_source; draw_bindings.texture_count = textures.count;
    draw_bindings.samplers = sampler_source; draw_bindings.sampler_count = samplers.count;
    return ff_vertex_resources_create_draw(device, source, snapshots.count, &draw_bindings);
}
static int execute(int dir, NSDictionary *m) {
    FFSTExecutorAttachments shared = NULL;
#define REJECT(reason) do { ffst_executor_release(shared); result(dir, @"rejected", @reason); return 1; } while (0)
    if (![m isKindOfClass:[NSDictionary class]] || ![m[@"format"] isEqual:@"bedrock-live-draw-replay"] ||
        ![m[@"version"] isEqual:@1] || ![m[@"width"] isKindOfClass:[NSNumber class]] ||
        ![m[@"height"] isKindOfClass:[NSNumber class]] || ![m[@"device_id"] isKindOfClass:[NSNumber class]] ||
        ![m[@"pixel_format"] isKindOfClass:[NSNumber class]] ||
        ![m[@"topology"] isKindOfClass:[NSNumber class]] || ![m[@"vertex_function"] isKindOfClass:[NSString class]] ||
        ![m[@"fragment_function"] isKindOfClass:[NSString class]] || !nums(m[@"clear"], 4) ||
        !nums(m[@"viewport"], 6) || !nums(m[@"scissor"], 4) || !nums(m[@"raster"], 7) || !nums(m[@"draw"], 5))
        REJECT("invalid manifest");
    uint64_t w = [m[@"width"] unsignedLongLongValue], h = [m[@"height"] unsignedLongLongValue];
    NSUInteger format = [m[@"pixel_format"] unsignedIntegerValue], topology = [m[@"topology"] unsignedIntegerValue];
    NSArray *v = m[@"viewport"], *s = m[@"scissor"], *r = m[@"raster"], *d = m[@"draw"], *c = m[@"clear"];
    uint64_t checked;
    for (NSString *key in @[ @"width", @"height", @"pixel_format", @"topology" ])
        if (!uint_value(m[key], UINT32_MAX, &checked)) REJECT("non-integral pipeline value");
    for (id value in d) if (!uint_value(value, UINT32_MAX, &checked)) REJECT("non-integral draw value");
    for (id value in s) if (!uint_value(value, UINT32_MAX, &checked)) REJECT("non-integral scissor value");
    for (NSUInteger i = 0; i < 4; ++i) if (!uint_value(r[i], UINT32_MAX, &checked)) REJECT("non-integral raster value");
    if (!w || !h || w > 2048 || h > 2048 || (format != MTLPixelFormatBGRA8Unorm && format != MTLPixelFormatBGRA8Unorm_sRGB &&
        format != MTLPixelFormatRGBA8Unorm && format != MTLPixelFormatRGBA8Unorm_sRGB) ||
        topology > MTLPrimitiveTopologyClassTriangle || [d[0] unsignedIntegerValue] > MTLPrimitiveTypeTriangleStrip ||
        ![d[2] unsignedLongLongValue] || ![d[3] unsignedLongLongValue] || [d[2] unsignedLongLongValue] > 10000000 ||
        [d[3] unsignedLongLongValue] > 1000000 ||
        [d[2] unsignedLongLongValue] > 10000000 / [d[3] unsignedLongLongValue] || [d[1] unsignedLongLongValue] > UINT32_MAX ||
        [d[4] unsignedLongLongValue] > UINT32_MAX || [r[0] unsignedIntegerValue] > 1 ||
        [r[1] unsignedIntegerValue] > 2 || [r[2] unsignedIntegerValue] > 1 || [r[3] unsignedIntegerValue] > 1)
        REJECT("unsupported bounds or pipeline");
    uint64_t sx = [s[0] unsignedLongLongValue], sy = [s[1] unsignedLongLongValue];
    uint64_t sw = [s[2] unsignedLongLongValue], sh = [s[3] unsignedLongLongValue];
    if (sx > w || sy > h || !sw || !sh || sw > w-sx || sh > h-sy || [v[2] doubleValue] <= 0 ||
        [v[3] doubleValue] <= 0 || [v[4] doubleValue] < 0 || [v[5] doubleValue] > 1 || [v[4] doubleValue] > [v[5] doubleValue])
        REJECT("unsupported viewport or scissor");
    NSData *vb = read_private(dir, "vertex.metallib", 8u*1024u*1024u), *fb = read_private(dir, "fragment.metallib", 8u*1024u*1024u);
    if (!vb || !fb) REJECT("shader libraries unavailable");
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device || device.registryID != [m[@"device_id"] unsignedLongLongValue]) REJECT("Metal device differs from producer");
    dispatch_data_t vd = dispatch_data_create(vb.bytes, vb.length, dispatch_get_global_queue(0, 0), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t fd = dispatch_data_create(fb.bytes, fb.length, dispatch_get_global_queue(0, 0), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error = nil;
    id<MTLLibrary> vl = [device newLibraryWithData:vd error:&error], fl = [device newLibraryWithData:fd error:&error];
    dispatch_release(vd); dispatch_release(fd);
    if (!vl || !fl) REJECT("Metal rejected original library");
    id<MTLFunction> vf = [vl newFunctionWithName:m[@"vertex_function"]], ff = [fl newFunctionWithName:m[@"fragment_function"]];
    if (!vf || !ff || vf.functionType != MTLFunctionTypeVertex || ff.functionType != MTLFunctionTypeFragment)
        REJECT("original functions unavailable");
    if (vf.stageInputAttributes.count) REJECT("vertex stage-in attributes not supported");
    MTLRenderPipelineDescriptor *pd = [[MTLRenderPipelineDescriptor alloc] init];
    pd.vertexFunction = vf; pd.fragmentFunction = ff; pd.rasterSampleCount = 1;
    pd.colorAttachments[0].pixelFormat = format; pd.inputPrimitiveTopology = topology;
    NSDictionary *state = m[@"pipeline_state"], *attachments = m[@"attachments"];
    NSUInteger samples = 1, depth_format = 0, stencil_format = 0;
    MTLLoadAction color_load = MTLLoadActionClear, depth_load = MTLLoadActionDontCare, stencil_load = MTLLoadActionDontCare;
    if (state || attachments) {
        if (![state isKindOfClass:[NSDictionary class]] || ![attachments isKindOfClass:[NSDictionary class]] || !nums(state[@"blend"], 8)) REJECT("invalid pipeline state");
        for (NSString *key in @[ @"samples", @"depth_format", @"stencil_format" ]) {
            if (!uint_value(state[key], UINT32_MAX, &checked) || ![state[key] isEqual:attachments[key]]) REJECT("pipeline attachments mismatch");
        }
        samples = [state[@"samples"] unsignedIntegerValue]; depth_format = [state[@"depth_format"] unsignedIntegerValue];
        stencil_format = [state[@"stencil_format"] unsignedIntegerValue];
        if ((samples != 1 && samples != 2 && samples != 4) || ![device supportsTextureSampleCount:samples] ||
            (depth_format && depth_format != MTLPixelFormatDepth32Float && depth_format != MTLPixelFormatDepth32Float_Stencil8) ||
            (stencil_format && stencil_format != MTLPixelFormatStencil8 && stencil_format != MTLPixelFormatDepth32Float_Stencil8)) REJECT("unsupported attachment formats");
        for (NSString *key in @[ @"color_load", @"depth_load", @"stencil_load" ])
            if (!uint_value(attachments[key], MTLLoadActionClear, &checked)) REJECT("invalid attachment load");
        color_load = [attachments[@"color_load"] unsignedIntegerValue]; depth_load = [attachments[@"depth_load"] unsignedIntegerValue];
        stencil_load = [attachments[@"stencil_load"] unsignedIntegerValue];
        if (!uint_value(attachments[@"stencil_clear"], 255, &checked) || ![attachments[@"depth_clear"] isKindOfClass:[NSNumber class]] ||
            !isfinite([attachments[@"depth_clear"] doubleValue]) || [attachments[@"depth_clear"] doubleValue] < 0 || [attachments[@"depth_clear"] doubleValue] > 1) REJECT("invalid attachment clear");
        NSArray *blend = state[@"blend"];
        for (NSUInteger i = 0; i < 8; ++i)
            if (!uint_value(blend[i], i == 0 ? 1 : i == 1 ? 15 : i < 4 ? MTLBlendOperationMax : MTLBlendFactorOneMinusSource1Alpha, &checked)) REJECT("invalid blend state");
        MTLRenderPipelineColorAttachmentDescriptor *a = pd.colorAttachments[0]; a.blendingEnabled = [blend[0] boolValue];
        a.writeMask = [blend[1] unsignedIntegerValue]; a.rgbBlendOperation = [blend[2] unsignedIntegerValue];
        a.alphaBlendOperation = [blend[3] unsignedIntegerValue]; a.sourceRGBBlendFactor = [blend[4] unsignedIntegerValue];
        a.destinationRGBBlendFactor = [blend[5] unsignedIntegerValue]; a.sourceAlphaBlendFactor = [blend[6] unsignedIntegerValue];
        a.destinationAlphaBlendFactor = [blend[7] unsignedIntegerValue];
        if (!uint_value(state[@"alpha_to_coverage"], 1, &checked) || !uint_value(state[@"alpha_to_one"], 1, &checked)) REJECT("invalid sample state");
        pd.alphaToCoverageEnabled = [state[@"alpha_to_coverage"] boolValue]; pd.alphaToOneEnabled = [state[@"alpha_to_one"] boolValue];
        pd.rasterSampleCount = samples; pd.depthAttachmentPixelFormat = depth_format; pd.stencilAttachmentPixelFormat = stencil_format;
    }
    MTLRenderPipelineReflection *reflection = nil;
    id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pd options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo
                                                                         reflection:&reflection error:&error];
    if (!pipeline || !reflection) REJECT("original pipeline could not be rebuilt");
    ff_draw_layout layout; uint64_t ia_mask = 0;
    if (m[@"ia_slot_mask"] && !uint_value(m[@"ia_slot_mask"], UINT32_MAX, &ia_mask)) REJECT("invalid IA slot mask");
    if (!ff_shader_layout(reflection, (uint32_t)ia_mask, &layout))
        REJECT("shader resources or binding reflection not supported");
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:w height:h mipmapped:NO];
    td.storageMode = MTLStorageModePrivate; td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> resolved = [device newTextureWithDescriptor:td];
    td.sampleCount = samples; td.textureType = samples > 1 ? MTLTextureType2DMultisample : MTLTextureType2D;
    id<MTLTexture> target = samples > 1 ? [device newTextureWithDescriptor:td] : resolved;
    id<MTLTexture> depth = nil, stencil = nil;
    if (depth_format) { td.pixelFormat = depth_format; depth = [device newTextureWithDescriptor:td]; }
    if (stencil_format) { td.pixelFormat = stencil_format; stencil = stencil_format == depth_format ? depth : [device newTextureWithDescriptor:td]; }
    int needs_shared = color_load == MTLLoadActionLoad || (depth_format && depth_load == MTLLoadActionLoad) ||
        (stencil_format && stencil_load == MTLLoadActionLoad);
    if (needs_shared) {
        uint64_t cut_id;
        if (!uint_value(m[@"shared_attachment_cut"], UINT64_MAX, &cut_id) || !cut_id ||
            ![m[@"resource_cut_id"] isKindOfClass:[NSString class]] ||
            ![m[@"resource_cut_id"] isEqual:[NSString stringWithFormat:@"draw-cut-%llu", (unsigned long long)cut_id]]) REJECT("invalid shared attachment cut");
        shared = ffst_executor_acquire(device, cut_id, 15);
        if (!shared) REJECT("matching shared attachment bundle unavailable");
        id<MTLTexture> loaded[] = {ffst_executor_texture(shared, FFST_COLOR, 0), ffst_executor_texture(shared, FFST_DEPTH, 0), ffst_executor_texture(shared, FFST_STENCIL, 0)};
        BOOL wanted[] = {color_load == MTLLoadActionLoad, depth_format && depth_load == MTLLoadActionLoad, stencil_format && stencil_load == MTLLoadActionLoad};
        NSUInteger formats[] = {format, depth_format, stencil_format}; size_t count = 0;
        for (unsigned i = 0; i < 3; ++i) {
            if (wanted[i]) {
                id<MTLTexture> t = loaded[i];
                if (!t || t.width != w || t.height != h || t.sampleCount != samples || t.pixelFormat != formats[i] || t.device.registryID != device.registryID) REJECT("shared attachment metadata mismatch");
                ++count;
            } else if (loaded[i]) REJECT("unexpected shared attachment role");
        }
        if (count != ffst_executor_attachment_count(shared)) REJECT("unexpected shared attachment count");
        if (loaded[0]) target = loaded[0];
        if (loaded[1]) depth = loaded[1];
        if (loaded[2]) stencil = loaded[2];
        if ([attachments[@"depth_stencil_alias"] boolValue] && depth_format && stencil_format) {
            if (depth_format != stencil_format || (loaded[1] && loaded[2] && loaded[1] != loaded[2])) REJECT("shared depth stencil alias mismatch");
            if (loaded[1] || loaded[2]) depth = stencil = loaded[1] ?: loaded[2];
        }
    } else if (m[@"shared_attachment_cut"]) REJECT("unexpected shared attachment cut");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    size_t stride = ((size_t)w * 4 + 255) & ~(size_t)255, length = stride * (size_t)h;
    id<MTLBuffer> out = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = [queue commandBuffer];
    if (!target || !resolved || !queue || !out || !cb || (depth_format && !depth) || (stencil_format && !stencil)) REJECT("Metal resource creation failed");
    int needs_resources = layout.ia_slot_mask || layout.constant_count[0] || layout.constant_count[1] ||
        layout.arguments[0].field_count || layout.arguments[1].field_count || m[@"indexed"] || m[@"resource_cut_id"];
    ff_vertex_resources *resources = needs_resources ? vertex_resources(dir, device, m, &layout) : NULL;
    if (needs_resources && !resources) REJECT("matching draw resource cut unavailable or invalid");
    if (!needs_resources && m[@"resource_cut_id"]) REJECT("unexpected draw resource cut");
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = target; pass.colorAttachments[0].loadAction = color_load;
    pass.colorAttachments[0].storeAction = samples > 1 ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    if (samples > 1) pass.colorAttachments[0].resolveTexture = resolved;
    pass.colorAttachments[0].clearColor = MTLClearColorMake([c[0] doubleValue], [c[1] doubleValue], [c[2] doubleValue], [c[3] doubleValue]);
    id<MTLBuffer> baseline = nil;
    if (color_load == MTLLoadActionClear || color_load == MTLLoadActionLoad) {
        baseline = [device newBufferWithLength:length options:MTLResourceStorageModeShared];
        if (!baseline) { ff_vertex_resources_destroy(resources); REJECT("baseline creation failed"); }
        MTLStoreAction final_store = pass.colorAttachments[0].storeAction;
        if (samples > 1 && color_load == MTLLoadActionLoad) pass.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve;
        id<MTLRenderCommandEncoder> clear = [cb renderCommandEncoderWithDescriptor:pass]; [clear endEncoding];
        pass.colorAttachments[0].storeAction = final_store;
        id<MTLBlitCommandEncoder> copy = [cb blitCommandEncoder];
        id<MTLTexture> before = samples > 1 ? resolved : target;
        [copy copyFromTexture:before sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(w,h,1)
            toBuffer:baseline destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:length]; [copy endEncoding];
    }
    pass.depthAttachment.texture = depth; pass.depthAttachment.loadAction = depth_load;
    pass.depthAttachment.storeAction = MTLStoreActionDontCare; pass.depthAttachment.clearDepth = [attachments[@"depth_clear"] doubleValue];
    pass.stencilAttachment.texture = stencil; pass.stencilAttachment.loadAction = stencil_load;
    pass.stencilAttachment.storeAction = MTLStoreActionDontCare; pass.stencilAttachment.clearStencil = [attachments[@"stencil_clear"] unsignedIntegerValue];
    id<MTLDepthStencilState> ds = m[@"depth_state"] && m[@"depth_state"] != [NSNull null] ? depth_state(device, m[@"depth_state"]) : nil;
    if (m[@"depth_state"] && m[@"depth_state"] != [NSNull null] && !ds) { ff_vertex_resources_destroy(resources); REJECT("invalid depth state"); }
    id<MTLRenderCommandEncoder> encoder = [cb renderCommandEncoderWithDescriptor:pass];
    if (!encoder) { ff_vertex_resources_destroy(resources); REJECT("render encoder unavailable"); }
    [encoder setRenderPipelineState:pipeline];
    [encoder setDepthStencilState:ds];
    if (m[@"blend_constant"]) {
        if (!nums(m[@"blend_constant"], 4) || !uint_value(m[@"stencil_ref"], 255, &checked)) { [encoder endEncoding]; ff_vertex_resources_destroy(resources); REJECT("invalid dynamic blend state"); }
        NSArray *b = m[@"blend_constant"]; [encoder setBlendColorRed:[b[0] floatValue] green:[b[1] floatValue] blue:[b[2] floatValue] alpha:[b[3] floatValue]];
        [encoder setStencilReferenceValue:[m[@"stencil_ref"] unsignedIntValue]];
    }
    [encoder setViewport:(MTLViewport){ [v[0] doubleValue], [v[1] doubleValue], [v[2] doubleValue], [v[3] doubleValue], [v[4] doubleValue], [v[5] doubleValue] }];
    [encoder setScissorRect:(MTLScissorRect){ sx, sy, sw, sh }];
    [encoder setTriangleFillMode:[r[0] unsignedIntegerValue]]; [encoder setCullMode:[r[1] unsignedIntegerValue]];
    [encoder setDepthClipMode:[r[2] unsignedIntegerValue]]; [encoder setFrontFacingWinding:[r[3] unsignedIntegerValue]];
    [encoder setDepthBias:[r[4] floatValue] slopeScale:[r[5] floatValue] clamp:[r[6] floatValue]];
    if (resources) ff_vertex_resources_bind(resources, encoder);
    if (m[@"indexed"]) {
        NSDictionary *index = m[@"indexed"]; NSUInteger offset = 0; uint64_t index_type, index_count;
        id<MTLBuffer> buffer = ff_vertex_resources_index(resources, &offset);
        if (![index isKindOfClass:[NSDictionary class]] || !uint_value(index[@"index_type"], 1, &index_type) ||
            !uint_value(index[@"index_count"], 10000000, &index_count) || index_count != [d[2] unsignedLongLongValue] ||
            ![index[@"base_vertex"] isKindOfClass:[NSNumber class]] || [index[@"base_vertex"] longLongValue] < INT32_MIN ||
            [index[@"base_vertex"] longLongValue] > INT32_MAX || !isfinite([index[@"base_vertex"] doubleValue]) ||
            floor([index[@"base_vertex"] doubleValue]) != [index[@"base_vertex"] doubleValue] || !buffer || offset > buffer.length ||
            index_count > (buffer.length - offset) / (index_type ? 4 : 2)) {
            [encoder endEncoding]; ff_vertex_resources_destroy(resources); REJECT("invalid native index binding");
        }
        [encoder drawIndexedPrimitives:[d[0] unsignedIntegerValue] indexCount:index_count indexType:index_type indexBuffer:buffer
            indexBufferOffset:offset instanceCount:[d[3] unsignedIntegerValue] baseVertex:[index[@"base_vertex"] intValue] baseInstance:[d[4] unsignedIntegerValue]];
    } else [encoder drawPrimitives:[d[0] unsignedIntegerValue] vertexStart:[d[1] unsignedIntegerValue]
                vertexCount:[d[2] unsignedIntegerValue] instanceCount:[d[3] unsignedIntegerValue] baseInstance:[d[4] unsignedIntegerValue]];
    [encoder endEncoding];
    id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
    if (!blit) { ff_vertex_resources_destroy(resources); REJECT("readback encoder unavailable"); }
    if (samples == 1 && target != resolved) [blit copyFromTexture:target toTexture:resolved];
    [blit copyFromTexture:resolved sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
               sourceSize:MTLSizeMake(w,h,1) toBuffer:out destinationOffset:0 destinationBytesPerRow:stride destinationBytesPerImage:length];
    [blit endEncoding];
    if (shared && !ffst_executor_finish(shared, cb)) { ff_vertex_resources_destroy(resources); REJECT("shared attachment completion could not be installed"); }
    [cb commit]; [cb waitUntilCompleted];
    ff_vertex_resources_destroy(resources);
    if (cb.status != MTLCommandBufferStatusCompleted) REJECT("native Metal execution failed");
    if (shared && ffst_executor_wait(shared, 15) != FFST_OK) REJECT("shared attachment retirement not acknowledged");
    ffst_executor_release(shared); shared = NULL;
    NSData *image = [NSData dataWithBytes:out.contents length:length];
    if (!write_private(dir, "replay.bgra", image)) REJECT("native output write failed");
    NSNumber *changed = nil;
    if (baseline) {
        uint64_t pixels = 0; const unsigned char *a = out.contents, *b = baseline.contents;
        for (size_t y = 0; y < h; ++y) for (size_t x = 0; x < w; ++x) if (memcmp(a + y*stride + x*4, b + y*stride + x*4, 4)) ++pixels;
        changed = @(pixels);
    }
    if (!result_completed(dir, m, stride, changed)) return 1;
    return present_output(dir, resolved);
#undef REJECT
}
static int execute_pass(int directory,NSDictionary *manifest) {
    NSString *failure=nil;
    FFSTPassExecution *output=ffst_pass_execute(directory,manifest,nil,^BOOL{return presentation_stop_requested(directory)!=0;},&failure);
    if(!output){result(directory,@"rejected",failure?:@"native ordered pass failed");return 1;}
    if(!write_private(directory,"replay.bgra",output.pixels)){result(directory,@"rejected",@"native pass output write failed");return 1;}
    NSData *metrics=[NSJSONSerialization dataWithJSONObject:output.metrics options:0 error:nil];
    if(!metrics||!write_private(directory,"replay-result.json",metrics))return 1;
    return present_output(directory,output.texture);
}
static int initialize_readback_stream(const char *path) {
    if (!path || path[0] != '/') return 2;
    int fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 2;
    enum ffrb_result code = ffrb_create(fd, 2, FFRB_MAX_BYTES);
    BOOL ok = code == FFRB_OK && !fsync(fd);
    close(fd);
    if (!ok) unlink(path);
    return ok ? 0 : 1;
}
static int initialize_shared_snapshots(const char *path) {
    if(!path||path[0]!='/')return 2;
    int fd=open(path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return 2;
    ffsa_result result=ffsa_create(fd,FFSA_MAX_SLOT_BYTES);
    BOOL ok=result==FFSA_OK&&!fsync(fd);close(fd);
    if(!ok)unlink(path);return ok?0:1;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if(argc==3&&!strcmp(argv[1],"--initialize-chunk-stream"))return ffst_native_chunk_initialize(argv[2]);
        if(argc==3&&!strcmp(argv[1],"--initialize-readback-stream"))return initialize_readback_stream(argv[2]);
        if(argc==3&&!strcmp(argv[1],"--initialize-shared-snapshots"))return initialize_shared_snapshots(argv[2]);
        if (argc != 5 || strcmp(argv[1], "--directory") || argv[2][0] != '/' || strcmp(argv[3], "--timeout")) return 2;
        char *end = NULL; long timeout = strtol(argv[4], &end, 10);
        if (!end || *end || timeout < 0 || timeout > 600) return 2;
        const char *session = getenv("BEDROCK_FULLFRAME_SESSION_UNTIL_QUIT");
        BOOL until_quit = session && !strcmp(session, "1");
        if ((timeout == 0) != until_quit) return 2;
        const char *presentation = getenv("BEDROCK_FULLFRAME_DRAW_PRESENT_SECONDS");
        if (presentation) {
            present_seconds = strtol(presentation, &end, 10);
            if (!*presentation || !end || *end || present_seconds < 1 || present_seconds > 600) return 2;
        }
        int dir = open(argv[2], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); struct stat st;
        if (dir < 0 || fstat(dir, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) { if (dir >= 0) close(dir); return 2; }
        const char *chunk_endpoint=getenv(FFSC_ENDPOINT_ENV);
        const char *presentation_enabled=getenv("BEDROCK_FULLFRAME_DRAW_PRESENT");
        if(presentation_enabled&&strcmp(presentation_enabled,"1")){close(dir);return 2;}
        BOOL present = present_seconds != 0 || (presentation_enabled && !strcmp(presentation_enabled,"1"));
        /* Zero is private session mode, never an unlimited one-frame replay. */
        if(until_quit&&(!chunk_endpoint||!*chunk_endpoint||!present)){close(dir);return 2;}
        if(chunk_endpoint){int code=ffst_native_chunk_worker(dir,chunk_endpoint,timeout,present);close(dir);return code;}
        const char *frame_mode = getenv("BEDROCK_FULLFRAME_NATIVE_FRAMES");
        if (frame_mode && !strcmp(frame_mode, "1")) {
            int code = ffst_native_frame_worker(dir, timeout, present_seconds != 0); close(dir); return code;
        }
        struct timespec started; clock_gettime(CLOCK_MONOTONIC, &started);
        for (;;) {
            @autoreleasepool {
                if (presentation_stop_requested(dir)) {
                    result(dir, @"cancelled", @"owned game session ended before capture");
                    close(dir); return 1;
                }
                NSData *data = read_private(dir, "replay.json", 2u*1024u*1024u);
                if (data) {
                    id manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
                    if ([manifest isKindOfClass:[NSDictionary class]] && [manifest[@"resource_cut_id"] isKindOfClass:[NSString class]] &&
                        !read_private(dir, "draw-resource-cut.json", 8u*1024u*1024u)) {
                        struct timespec current; clock_gettime(CLOCK_MONOTONIC, &current);
                        if (current.tv_sec - started.tv_sec < timeout) { usleep(100000); continue; }
                    }
                    int code = [manifest isKindOfClass:[NSDictionary class]]&&[manifest[@"format"] isEqual:@"bedrock-native-pass-replay"]?
                        execute_pass(dir,manifest):execute(dir,manifest); close(dir); return code;
                }
            }
            struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
            if (now.tv_sec - started.tv_sec >= timeout) { result(dir, @"rejected", @"no eligible completed game draw observed"); close(dir); return 1; }
            usleep(100000);
        }
    }
}
