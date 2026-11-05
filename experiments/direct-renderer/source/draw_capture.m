/* Default-off, bounded observer for a real DXMT draw and its pipeline creation.
 * This is diagnostic metadata, not a replayable draw or an ownership transfer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include "winemetal.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAX_PIPELINES 64
#define MAX_FUNCTIONS 128
#define MAX_ENCODERS 64
static int dirfd = -1;
static _Atomic int finished;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static uint64_t next_id = 1;
struct function_entry { id<MTLFunction> object; uint64_t id; };
struct pipeline_entry {
    id<MTLRenderPipelineState> object;
    uint64_t id, vertex_id, fragment_id;
    int vertex_present, fragment_present;
    struct WMTRenderPipelineInfo info;
};
struct encoder_entry { id<MTLRenderCommandEncoder> object; id<MTLRenderPipelineState> pipeline; };
static struct function_entry functions[MAX_FUNCTIONS];
static struct pipeline_entry pipelines[MAX_PIPELINES];
static struct encoder_entry encoders[MAX_ENCODERS];

__attribute__((constructor)) static void initialize_draw_capture(void) {
    const char *path = getenv("BEDROCK_FULLFRAME_DRAW_DIR");
    if (!path || path[0] != '/') return;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) {
        close(fd); return;
    }
    dirfd = fd;
}

/* Retaining registered objects prevents pointer recycling while IDs are live.
 * Overflow is explicitly represented as unknown; IDs are never recycled. */
static uint64_t function_id(id<MTLFunction> function) {
    if (!function) return 0;
    for (unsigned i = 0; i < MAX_FUNCTIONS; ++i)
        if (functions[i].object == function) return functions[i].id;
    for (unsigned i = 0; i < MAX_FUNCTIONS; ++i) if (!functions[i].object) {
        functions[i].object = [function retain];
        functions[i].id = next_id++;
        return functions[i].id;
    }
    return 0;
}

void fullframe_register_pipeline(id<MTLRenderPipelineState> pso, const struct WMTRenderPipelineInfo *info) {
    if (dirfd < 0 || atomic_load(&finished) || !pso || !info) return;
    pthread_mutex_lock(&lock);
    if (!atomic_load(&finished)) {
        for (unsigned i = 0; i < MAX_PIPELINES; ++i) if (!pipelines[i].object) {
            struct pipeline_entry *entry = &pipelines[i];
            entry->object = [pso retain]; entry->id = next_id++;
            entry->vertex_present = info->vertex_function != 0;
            entry->fragment_present = info->fragment_function != 0;
            entry->vertex_id = function_id((id<MTLFunction>)info->vertex_function);
            entry->fragment_id = function_id((id<MTLFunction>)info->fragment_function);
            entry->info = *info;
            /* Pointers and handles are never part of the persistent record. */
            entry->info.vertex_function = 0; entry->info.fragment_function = 0;
            entry->info.binary_archive_for_serialization = 0;
            entry->info.binary_archives_for_lookup.ptr = NULL;
            break;
        }
    }
    pthread_mutex_unlock(&lock);
}

void fullframe_draw_encoder_begin(id<MTLRenderCommandEncoder> encoder) {
    if (dirfd < 0 || atomic_load(&finished) || !encoder) return;
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < MAX_ENCODERS; ++i) if (!encoders[i].object) {
        encoders[i] = (struct encoder_entry){ encoder, nil }; break;
    }
    pthread_mutex_unlock(&lock);
}
void fullframe_draw_encoder_end(id encoder) {
    if (dirfd < 0 || !encoder) return;
    pthread_mutex_lock(&lock);
    for (unsigned i = 0; i < MAX_ENCODERS; ++i) if (encoders[i].object == encoder) {
        encoders[i] = (struct encoder_entry){ nil, nil }; break;
    }
    pthread_mutex_unlock(&lock);
}

static NSDictionary *pipeline_record(const struct pipeline_entry *entry) {
    if (!entry) return nil;
    const struct WMTRenderPipelineInfo *p = &entry->info;
    NSMutableArray *colors = [NSMutableArray arrayWithCapacity:8];
    for (unsigned i = 0; i < 8; ++i) {
        const struct WMTColorAttachmentBlendInfo *c = &p->colors[i];
        [colors addObject:@{ @"pixel_format": @(c->pixel_format), @"blend": @(c->blending_enabled),
            @"write_mask": @(c->write_mask), @"rgb_operation": @(c->rgb_blend_operation),
            @"alpha_operation": @(c->alpha_blend_operation), @"src_rgb": @(c->src_rgb_blend_factor),
            @"dst_rgb": @(c->dst_rgb_blend_factor), @"src_alpha": @(c->src_alpha_blend_factor),
            @"dst_alpha": @(c->dst_alpha_blend_factor) }];
    }
    return @{ @"id": @(entry->id), @"vertex_function_id": @(entry->vertex_id),
        @"fragment_function_id": @(entry->fragment_id),
        @"vertex_function_present": @(entry->vertex_present),
        @"fragment_function_present": @(entry->fragment_present), @"colors": colors,
        @"alpha_to_coverage": @(p->alpha_to_coverage_enabled), @"logic_enabled": @(p->logic_operation_enabled),
        @"logic_operation": @(p->logic_operation), @"rasterization": @(p->rasterization_enabled),
        @"samples": @(p->raster_sample_count), @"depth_format": @(p->depth_pixel_format),
        @"stencil_format": @(p->stencil_pixel_format), @"immutable_vertex_buffers": @(p->immutable_vertex_buffers),
        @"immutable_fragment_buffers": @(p->immutable_fragment_buffers), @"topology": @(p->input_primitive_topology),
        @"tessellation_partition": @(p->tessellation_partition_mode), @"max_tessellation_factor": @(p->max_tessellation_factor),
        @"tessellation_winding": @(p->tessellation_output_winding_order), @"tessellation_step": @(p->tessellation_factor_step),
        @"binary_archive_count": @(p->num_binary_archives_for_lookup), @"fail_on_archive_miss": @(p->fail_on_binary_archive_miss) };
}

static void write_record(NSDictionary *record) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:nil];
    if (!data || data.length > 16384) return;
    int fd = openat(dirfd, "draw.json", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return;
    const uint8_t *bytes = data.bytes; size_t left = data.length;
    while (left) {
        ssize_t n = write(fd, bytes, left);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break;
        bytes += n; left -= (size_t)n;
    }
    int ok = !left && fsync(fd) == 0;
    if (close(fd)) ok = 0;
    if (!ok) unlinkat(dirfd, "draw.json", 0);
}

/* Called on the actual encoder stream before DXMT executes each command.
 * No command is replaced or suppressed. */
void fullframe_observe_draw(id<MTLRenderCommandEncoder> encoder, const struct wmtcmd_base *next) {
    if (dirfd < 0 || atomic_load(&finished) || !encoder || !next) return;
    enum WMTRenderCommandType type = (enum WMTRenderCommandType)next->type;
    if (type != WMTRenderCommandSetPSO && type != WMTRenderCommandDraw && type != WMTRenderCommandDrawIndexed) return;
    pthread_mutex_lock(&lock);
    if (atomic_load(&finished)) { pthread_mutex_unlock(&lock); return; }
    struct encoder_entry *state = NULL;
    for (unsigned i = 0; i < MAX_ENCODERS; ++i) if (encoders[i].object == encoder) { state = &encoders[i]; break; }
    if (type == WMTRenderCommandSetPSO) {
        if (state) state->pipeline = (id<MTLRenderPipelineState>)((const struct wmtcmd_render_setpso *)next)->pso;
        pthread_mutex_unlock(&lock); return;
    }
    const struct pipeline_entry *pipeline = NULL;
    if (state && state->pipeline) for (unsigned i = 0; i < MAX_PIPELINES; ++i)
        if (pipelines[i].object == state->pipeline) { pipeline = &pipelines[i]; break; }
    @autoreleasepool {
        NSMutableDictionary *draw = [NSMutableDictionary dictionary];
        if (type == WMTRenderCommandDraw) {
            const struct wmtcmd_render_draw *d = (const struct wmtcmd_render_draw *)next;
            [draw addEntriesFromDictionary:@{ @"kind": @"draw", @"primitive": @(d->primitive_type),
                @"vertex_start": @(d->vertex_start), @"vertex_count": @(d->vertex_count),
                @"instance_count": @(d->instance_count), @"base_instance": @(d->base_instance) }];
        } else {
            const struct wmtcmd_render_draw_indexed *d = (const struct wmtcmd_render_draw_indexed *)next;
            [draw addEntriesFromDictionary:@{ @"kind": @"draw_indexed", @"primitive": @(d->primitive_type),
                @"index_type": @(d->index_type), @"index_count": @(d->index_count), @"index_offset": @(d->index_buffer_offset),
                @"instance_count": @(d->instance_count), @"base_vertex": @(d->base_vertex), @"base_instance": @(d->base_instance) }];
        }
        NSDictionary *record = @{ @"format": @"bedrock-full-frame-draw-observation", @"version": @1,
            @"status": @"unsupported-for-replay", @"draw": draw,
            @"pipeline": pipeline_record(pipeline) ?: (id)[NSNull null],
            @"encoder_tracked": @(state != NULL),
            @"blockers": @[ @"shader library and function constants", @"resource contents and argument relocation",
                @"attachment contents and prior draws", @"dynamic render state", @"GPU ordering and completion" ] };
        atomic_store(&finished, 1);
        write_record(record);
        for (unsigned i = 0; i < MAX_PIPELINES; ++i) {
            [pipelines[i].object release]; pipelines[i].object = nil;
        }
        for (unsigned i = 0; i < MAX_FUNCTIONS; ++i) {
            [functions[i].object release]; functions[i].object = nil;
        }
    }
    pthread_mutex_unlock(&lock);
}
