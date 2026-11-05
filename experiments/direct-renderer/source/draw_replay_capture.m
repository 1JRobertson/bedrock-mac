/* Default-off live replay capture for bounded ordinary draws and logical resources.
 * Capture is accepted only on GPU completion; the original draw always runs. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "winemetal.h"
#include "shader_bindings.h"
#include "shared_texture_pass_capture.h"
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define LIB_MAX (8u * 1024u * 1024u)
#define TOTAL_MAX (64u * 1024u * 1024u)
#define N 128
static int dir = -1;
static pthread_mutex_t guard = PTHREAD_MUTEX_INITIALIZER;
static _Atomic int claimed;
static int manual_arm, geometry_profile;
static int pass_mode;
static int frame_mode;
static uint32_t pass_min_draws = 2;
static uint64_t shared_registry_id;
static _Atomic int armed;
static _Atomic int64_t last_arm_check;
static _Atomic size_t total;
static unsigned library_cursor, function_cursor;
static uint64_t pipeline_clock;
enum { D_LIBRARY_LIMIT, D_FUNCTION_MISSING, D_PIPELINE_STATE, D_BINDINGS, D_REFLECTION,
    D_IA_PROVENANCE, D_PSO_LIMIT, D_PASS_STATE, D_DRAW_PIPELINE, D_DRAW_STATE, D_CUT_MISSING, D_PROFILE, D_ACCEPTED, D_COUNT };
static const char *diagnostic_names[D_COUNT] = { "library-budget", "function-provenance", "pipeline-state", "shader-bindings",
    "reflection", "ia-provenance", "pipeline-capacity", "pass-state", "draw-pipeline", "draw-state", "draw-resource-cut", "draw-profile", "accepted" };
static _Atomic uint64_t diagnostics[D_COUNT];
static pthread_mutex_t diagnostic_guard=PTHREAD_MUTEX_INITIALIZER;
static NSMutableSet *rejected_shapes;
static void rejected_pipeline(const char *reason,MTLRenderPipelineDescriptor *d,MTLRenderPipelineReflection *reflection,uint32_t ia_mask) {
    NSMutableString *shape=[NSMutableString stringWithFormat:@"reason=%s samples=%lu depth=%lu stencil=%lu ia=%u colors=",reason,
        (unsigned long)d.rasterSampleCount,(unsigned long)d.depthAttachmentPixelFormat,(unsigned long)d.stencilAttachmentPixelFormat,ia_mask];
    for(unsigned i=0;i<8;++i)[shape appendFormat:@"%lu,",(unsigned long)d.colorAttachments[i].pixelFormat];
    NSArray *stages[] = {reflection.vertexBindings ?: @[],reflection.fragmentBindings ?: @[]};
    for(unsigned stage=0;stage<2;++stage)for(id<MTLBinding> b in stages[stage])if(b.isUsed){
        [shape appendFormat:@" %s[%lu,type%ld,access%lu]",stage?"ps":"vs",(unsigned long)b.index,(long)b.type,(unsigned long)b.access];
        if(b.type==MTLBindingTypeBuffer){id<MTLBufferBinding> buffer=(id)b;[shape appendFormat:@"bytes%lu",(unsigned long)buffer.bufferDataSize];
            unsigned n=0;for(MTLStructMember *m in buffer.bufferStructType.members){if(n++==16){[shape appendString:@"..."];break;}
                [shape appendFormat:@"{%lu:%lu",(unsigned long)m.offset,(unsigned long)m.dataType];
                if(m.dataType==MTLDataTypeTexture){MTLTextureReferenceType *t=m.textureReferenceType;[shape appendFormat:@"/texture%lu/access%lu/depth%d",(unsigned long)t.textureType,(unsigned long)t.access,t.isDepthTexture];}
                if(m.dataType==MTLDataTypePointer){MTLPointerType *p=m.pointerType;[shape appendFormat:@"/pointeraccess%lu/nested%d",(unsigned long)p.access,p.elementIsArgumentBuffer];}[shape appendString:@"}"];}}
    }
    pthread_mutex_lock(&diagnostic_guard);if(!rejected_shapes)rejected_shapes=[[NSMutableSet alloc]init];
    if(rejected_shapes.count<24&&![rejected_shapes containsObject:shape]){[rejected_shapes addObject:shape];fprintf(stderr,"[full-frame-replay-rejected] %s\n",shape.UTF8String);}
    pthread_mutex_unlock(&diagnostic_guard);
}
static void observe(unsigned reason) {
    uint64_t count = atomic_fetch_add(&diagnostics[reason], 1) + 1;
    /* At most ten progress lines per reason, plus one complete exit summary. */
    if (count == 1 || count == 10 || count == 100 || count == 1000 || count == 10000 || count == 100000 || count == 1000000)
        fprintf(stderr, "[full-frame-replay] %s=%llu\n", diagnostic_names[reason], (unsigned long long)count);
}
__attribute__((destructor)) static void replay_summary(void) {
    if (dir < 0) return;
    fprintf(stderr, "[full-frame-replay-summary]");
    for (unsigned i = 0; i < D_COUNT; ++i) fprintf(stderr, " %s=%llu", diagnostic_names[i], (unsigned long long)atomic_load(&diagnostics[i]));
    fputc('\n', stderr);
}
#include "replay_bytes_hash_cache_instrumented.h"
struct lib { id<MTLLibrary> obj; FFReplayBytes *data; };
struct fn { id<MTLFunction> obj; FFReplayBytes *data; NSString *name; };
extern int ff_ia_pipeline_mask(id<MTLRenderPipelineState>, uint32_t *);
struct pso { id<MTLRenderPipelineState> obj; FFReplayBytes *vs, *ps; NSString *vn, *pn; NSUInteger format, topology; int vertex_table; uint32_t ia_mask;
    ff_draw_layout layout; NSDictionary *state; unsigned pins; uint64_t last_used;
    FFSTPassPipelineSnapshot *cached_snapshot; };
struct depth_state { id<MTLDepthStencilState> object; NSDictionary *state; };
static struct depth_state depth_states[N]; static unsigned depth_cursor;
static struct {
    id<MTLCommandBuffer> command;
    const struct wmtcmd_base *draw;
    NSString *identifier;
} resource_cut;
struct pass {
    id<MTLRenderCommandEncoder> encoder;
    id<MTLCommandBuffer> command;
    struct pso *pipeline;
    uint64_t width, height;
    uint64_t device_id, pixel_format;
    double clear[4];
    struct WMTViewport viewport;
    struct WMTScissorRect scissor;
    struct wmtcmd_render_setrasterizerstate raster;
    NSDictionary *attachments, *depth_state;
    float blend[4]; uint32_t stencil_ref;
    int invalid, viewport_set, scissor_set, raster_set;
};
static struct lib libs[N]; static struct fn fns[N]; static struct pso psos[N]; static struct pass passes[N];
#include "pipeline_snapshot_cache.h"
int fullframe_replay_pass_eligible(const struct WMTRenderPassInfo *info);
static const char *frame_pass_ineligible_reason(const struct WMTRenderPassInfo *info);
static void drop_library(unsigned i) { [libs[i].obj release]; [libs[i].data release]; libs[i] = (struct lib){0}; }
static void drop_function(unsigned i) { [fns[i].obj release]; [fns[i].data release]; [fns[i].name release]; fns[i] = (struct fn){0}; }
static void drop_pipeline(struct pso *p) {
    ff_pc_drop(p);
    [p->obj release]; [p->vs release]; [p->ps release]; [p->vn release]; [p->pn release]; [p->state release]; memset(p, 0, sizeof(*p));
}
static struct pso *pipeline_slot(void) {
    struct pso *oldest = NULL;
    for (unsigned i = 0; i < N; ++i) {
        if (!psos[i].obj) return &psos[i];
        if (!psos[i].pins && (!oldest || psos[i].last_used < oldest->last_used)) oldest = &psos[i];
    }
    return oldest;
}
/* Registries retain blobs by reference; a blob leaves the byte budget only
 * after its last library/function/pipeline/callback reference is gone. */
static int make_room(size_t size) {
    for (unsigned i = 0; size > TOTAL_MAX - atomic_load(&total) && i < N; ++i) drop_library(library_cursor++ % N);
    for (unsigned i = 0; size > TOTAL_MAX - atomic_load(&total) && i < N; ++i) drop_function(function_cursor++ % N);
    for (unsigned i = 0; size > TOTAL_MAX - atomic_load(&total) && i < N; ++i) {
        struct pso *slot = NULL;
        for (unsigned j = 0; j < N; ++j) if (psos[j].obj && !psos[j].pins && (!slot || psos[j].last_used < slot->last_used)) slot = &psos[j];
        if (!slot) break; drop_pipeline(slot);
    }
    return size <= TOTAL_MAX - atomic_load(&total);
}

int fullframe_replay_capture_armed(void) {
    if (dir < 0 || frame_mode || atomic_load(&claimed)) return 0;
    if (!manual_arm || atomic_load(&armed)) return 1;
    struct timespec now; if (clock_gettime(CLOCK_MONOTONIC, &now)) return 0;
    int64_t ms = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
    int64_t previous = atomic_load(&last_arm_check);
    if (ms - previous < 100 || !atomic_compare_exchange_strong(&last_arm_check, &previous, ms)) return 0;
    int fd = openat(dir, "draw.arm", O_RDONLY | O_NOFOLLOW | O_CLOEXEC); struct stat st; char token[4];
    if (fd < 0) return 0;
    int valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == getuid() && st.st_nlink == 1 &&
        !(st.st_mode & 077) && st.st_size == 4 && read(fd, token, sizeof(token)) == sizeof(token) && !memcmp(token, "arm\n", sizeof(token));
    close(fd); if (valid) atomic_store(&armed, 1); return valid;
}

int fullframe_frame_capture_layout(id<MTLRenderPipelineState> pipeline, ff_draw_layout *layout) {
    if (dir < 0 || !pipeline || !layout) return 0;
    int ok = 0; pthread_mutex_lock(&guard);
    for (unsigned i = 0; i < N; ++i) if (psos[i].obj == pipeline) { *layout = psos[i].layout; ok = 1; break; }
    pthread_mutex_unlock(&guard); return ok;
}
int fullframe_replay_cut_layout(id<MTLRenderPipelineState> pipeline, ff_draw_layout *layout) {
    return fullframe_replay_capture_armed() && fullframe_frame_capture_layout(pipeline,layout);
}
int fullframe_replay_draw_eligible(id<MTLRenderPipelineState> pipeline, const struct wmtcmd_base *command) {
    if (!fullframe_replay_capture_armed() || !pipeline || !command) return 0;
    uint64_t count;
    if (command->type == WMTRenderCommandDraw) count = ((const struct wmtcmd_render_draw *)command)->vertex_count;
    else if (command->type == WMTRenderCommandDrawIndexed) count = ((const struct wmtcmd_render_draw_indexed *)command)->index_count;
    else return 0;
    if (!geometry_profile) return count != 0;
    ff_draw_layout layout;
    int eligible = count > 6 && fullframe_replay_cut_layout(pipeline, &layout) && layout.ia_slot_mask && layout.constant_count[0];
    if (!eligible) observe(D_PROFILE); return eligible;
}
static FFSTPassRecord *capture_pass_record(const struct WMTRenderPassInfo *info,
    const struct wmtcmd_base *head,const struct ff_draw_cut *cut) {
    FFSTPassRecord *record=ffst_pass_capture_record(info,head,cut,^FFSTPassPipelineSnapshot *(id<MTLRenderPipelineState> object){
        return ff_pc_resolve(object);
    },^NSDictionary *(id<MTLDepthStencilState> object){
        NSDictionary *state=nil;pthread_mutex_lock(&guard);
        for(unsigned i=0;i<N;++i)if(depth_states[i].object==object){state=[[depth_states[i].state retain]autorelease];break;}
        pthread_mutex_unlock(&guard);return state;
    });
    return record;
}
FFSTPassRecord *fullframe_frame_capture_record(id<MTLCommandBuffer> command,const struct WMTRenderPassInfo *info,
    const struct wmtcmd_base *head,const struct ff_draw_cut *cut) {
    const char *live=getenv("BEDROCK_LIVE_COMMANDS");if(live&&!strcmp(live,"1")){fprintf(stderr,"[live-command-reject] reason=forbidden-pass-capture\n");abort();}
    const char *failure=dir<0?"capture-disabled":!command?"command-missing":!cut?"cut-missing":
        cut->discarded?"cut-discarded":!cut->complete_pass?"cut-incomplete":!fullframe_replay_pass_eligible(info)?"pass-ineligible":NULL;
    if(failure){if(!strcmp(failure,"pass-ineligible"))failure=frame_pass_ineligible_reason(info);
        fprintf(stderr,"[full-frame-capture-reject] cut=%llu stage=eligibility reason=%s\n",(unsigned long long)(cut?cut->capture_id:0),failure);return nil;}
    FFSTPassRecord *record=capture_pass_record(info,head,cut);
    if(!record){fprintf(stderr,"[full-frame-capture-reject] cut=%llu stage=record reason=nil\n",(unsigned long long)cut->capture_id);return nil;}
    if(![record.manifest[@"complete_pass"] boolValue]||[record.manifest[@"draws"] count]!=cut->draw_count){
        fprintf(stderr,"[full-frame-capture-reject] cut=%llu stage=record reason=partial draws=%lu expected=%zu\n",(unsigned long long)cut->capture_id,
            (unsigned long)[record.manifest[@"draws"] count],cut->draw_count);return nil;}
    return record;
}
FFSTPassRecord *fullframe_replay_pass_record(id<MTLCommandBuffer> command,const struct WMTRenderPassInfo *info,
    const struct wmtcmd_base *head,const struct ff_draw_cut *cut) {
    if(!pass_mode||!fullframe_replay_capture_armed()||!command||!cut||cut->discarded||!fullframe_replay_pass_eligible(info))return nil;
    FFSTPassRecord *record=capture_pass_record(info,head,cut);
    if(!record||[record.manifest[@"draws"] count]<pass_min_draws||![record.manifest[@"material_geometry_draw_count"] unsignedIntegerValue]){
        observe(D_PROFILE);return nil;
    }
    return record;
}
int fullframe_replay_pass_claim(FFSTPassRecord *record) {
    if(!pass_mode||!fullframe_replay_capture_armed()||!record||[record.manifest[@"draws"] count]<pass_min_draws||
        ![record.manifest[@"material_geometry_draw_count"] unsignedIntegerValue])return 0;
    int expected=0;if(!atomic_compare_exchange_strong(&claimed,&expected,1))return 0;
    if(manual_arm)(void)unlinkat(dir,"draw.arm",0);observe(D_ACCEPTED);return 1;
}
void fullframe_replay_cut_ready(id<MTLCommandBuffer> command, const struct wmtcmd_base *draw, NSString *identifier) {
    if (dir < 0 || !command || !draw || !identifier.length || identifier.length > 128) return;
    pthread_mutex_lock(&guard);
    if (!atomic_load(&claimed) && !resource_cut.command) {
        resource_cut.command = [command retain]; resource_cut.draw = draw; resource_cut.identifier = [identifier copy];
    }
    pthread_mutex_unlock(&guard);
}
static int color_format(NSUInteger format) {
    return format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatBGRA8Unorm_sRGB ||
           format == MTLPixelFormatRGBA8Unorm || format == MTLPixelFormatRGBA8Unorm_sRGB;
}
int fullframe_replay_pass_eligible(const struct WMTRenderPassInfo *info) {
    if (!info || !info->colors[0].texture || info->visibility_buffer || info->render_target_array_length > 1 || info->tile_width || info->tile_height) return 0;
    id<MTLTexture> texture = (id<MTLTexture>)info->colors[0].texture;
    /* Frame payloads preserve logical versions; native execution resolves an
     * earlier native write or demands an exact external import before Load. */
    int shared_load = frame_mode || (shared_registry_id && texture.device.registryID == shared_registry_id);
    if (!color_format(texture.pixelFormat) || !texture.width || !texture.height || texture.width > 2048 || texture.height > 2048 ||
        (texture.sampleCount != 1 && texture.sampleCount != 2 && texture.sampleCount != 4) ||
        (texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DMultisample) ||
        (info->render_target_width && info->render_target_width != texture.width) ||
        (info->render_target_height && info->render_target_height != texture.height) ||
        info->colors[0].level || info->colors[0].slice || info->colors[0].depth_plane || (info->colors[0].load_action == WMTLoadActionLoad && !shared_load)) return 0;
    for (unsigned i = 1; i < 8; ++i) if (info->colors[i].texture) return 0;
    if (info->depth.texture && ((info->depth.load_action == WMTLoadActionLoad && !shared_load) || info->depth.level || info->depth.slice || info->depth.depth_plane)) return 0;
    if (info->stencil.texture && ((info->stencil.load_action == WMTLoadActionLoad && !shared_load) || info->stencil.level || info->stencil.slice || info->stencil.depth_plane)) return 0;
    id<MTLTexture> depth = (id<MTLTexture>)info->depth.texture, stencil = (id<MTLTexture>)info->stencil.texture;
    if ((depth && (depth.width != texture.width || depth.height != texture.height || depth.sampleCount != texture.sampleCount)) ||
        (stencil && (stencil.width != texture.width || stencil.height != texture.height || stencil.sampleCount != texture.sampleCount))) return 0;
    const struct WMTClearColor *color = &info->colors[0].clear_color;
    if (!isfinite(color->r) || !isfinite(color->g) || !isfinite(color->b) || !isfinite(color->a)) return 0;
    if (depth && (!isfinite(info->depth.clear_depth) || info->depth.clear_depth < 0 || info->depth.clear_depth > 1)) return 0;
    return 1;
}
/* Diagnostic only, called after the unchanged qualification rejected the pass. */
static const char *frame_pass_ineligible_reason(const struct WMTRenderPassInfo *i) {
    if(!i)return "pass-missing";
    if(!i->colors[0].texture)return "color-missing";
    if(i->visibility_buffer)return "visibility-buffer";
    if(i->render_target_array_length>1)return "array-length";
    if(i->tile_width||i->tile_height)return "tile-rendering";
    id<MTLTexture> t=(id<MTLTexture>)i->colors[0].texture;
    if(!color_format(t.pixelFormat))return "color-format";
    if(!t.width||!t.height||t.width>2048||t.height>2048)return "color-size";
    if(t.sampleCount!=1&&t.sampleCount!=2&&t.sampleCount!=4)return "sample-count";
    if(t.textureType!=MTLTextureType2D&&t.textureType!=MTLTextureType2DMultisample)return "texture-type";
    if((i->render_target_width&&i->render_target_width!=t.width)||(i->render_target_height&&i->render_target_height!=t.height))return "target-size";
    if(i->colors[0].level||i->colors[0].slice||i->colors[0].depth_plane)return "color-view";
    int shared_load=frame_mode||(shared_registry_id&&t.device.registryID==shared_registry_id);
    if(i->colors[0].load_action==WMTLoadActionLoad&&!shared_load)return "color-load";
    for(unsigned n=1;n<8;n++)if(i->colors[n].texture)return "multiple-colors";
    if(i->depth.texture&&((i->depth.load_action==WMTLoadActionLoad&&!shared_load)||i->depth.level||i->depth.slice||i->depth.depth_plane))return "depth-view-or-load";
    if(i->stencil.texture&&((i->stencil.load_action==WMTLoadActionLoad&&!shared_load)||i->stencil.level||i->stencil.slice||i->stencil.depth_plane))return "stencil-view-or-load";
    id<MTLTexture> d=(id<MTLTexture>)i->depth.texture,s=(id<MTLTexture>)i->stencil.texture;
    if((d&&(d.width!=t.width||d.height!=t.height||d.sampleCount!=t.sampleCount))||
       (s&&(s.width!=t.width||s.height!=t.height||s.sampleCount!=t.sampleCount)))return "depth-stencil-shape";
    const struct WMTClearColor *c=&i->colors[0].clear_color;
    if(!isfinite(c->r)||!isfinite(c->g)||!isfinite(c->b)||!isfinite(c->a))return "color-clear";
    if(d&&(!isfinite(i->depth.clear_depth)||i->depth.clear_depth<0||i->depth.clear_depth>1))return "depth-clear";
    return "pass-ineligible";
}
static id stencil_record(MTLStencilDescriptor *d) {
    return d ? @[ @(d.stencilCompareFunction), @(d.stencilFailureOperation), @(d.depthFailureOperation), @(d.depthStencilPassOperation), @(d.readMask), @(d.writeMask) ] : (id)[NSNull null];
}
void fullframe_replay_depth_state(id<MTLDepthStencilState> object, MTLDepthStencilDescriptor *d) {
    if (dir < 0 || atomic_load(&claimed) || !object || !d) return;
    NSDictionary *record = @{ @"compare": @(d.depthCompareFunction), @"write": @(d.depthWriteEnabled),
        @"front": stencil_record(d.frontFaceStencil), @"back": stencil_record(d.backFaceStencil) };
    pthread_mutex_lock(&guard); unsigned i = depth_cursor++ % N;
    [depth_states[i].object release]; [depth_states[i].state release];
    depth_states[i] = (struct depth_state){[object retain], [record copy]}; pthread_mutex_unlock(&guard);
}

__attribute__((constructor)) static void init_replay(void) {
    const char *enabled = getenv("BEDROCK_FULLFRAME_DRAW_REPLAY");
    const char *frame_path=getenv("BEDROCK_FULLFRAME_FRAME_STREAM_DIRECTORY"),*frame_enabled=getenv("DXMT_FRAME_STREAM");
    frame_mode=frame_enabled&&!strcmp(frame_enabled,"1")&&frame_path&&frame_path[0]=='/';
    if ((!enabled || strcmp(enabled, "1"))&&!frame_mode) return;
    const char *cache=getenv("BEDROCK_PRIVATE_PIPELINE_CACHE");
    ff_pipeline_cache_mode=cache&&!strcmp(cache,"1")?1:cache&&!strcmp(cache,"2")?2:0;
    const char *libraryCache=getenv("BEDROCK_PRIVATE_LIBRARY_HASH_CACHE");
    ff_lhc_mode=libraryCache&&!strcmp(libraryCache,"1")?1:libraryCache&&!strcmp(libraryCache,"2")?2:0;
    const char *manual = getenv("BEDROCK_FULLFRAME_DRAW_MANUAL"), *require = getenv("BEDROCK_FULLFRAME_DRAW_REQUIRE_ARM");
    manual_arm = (manual && !strcmp(manual, "1")) || (require && !strcmp(require, "1"));
    const char *profile = getenv("BEDROCK_FULLFRAME_DRAW_PROFILE");
    geometry_profile = profile && !strcmp(profile, "geometry");
    const char *pass=getenv("BEDROCK_FULLFRAME_DRAW_PASS"),*minimum=getenv("BEDROCK_FULLFRAME_PASS_MIN_DRAWS");
    pass_mode=pass&&!strcmp(pass,"1");
    if(minimum&&!frame_mode){char *end=NULL;errno=0;unsigned long n=strtoul(minimum,&end,10);if(errno||!end||*end||!n||n>FF_DRAW_PASS_LIMIT)return;pass_min_draws=(uint32_t)n;}
    const char *service = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_SERVICE"), *token = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_TOKEN");
    const char *registry = getenv("BEDROCK_FULLFRAME_SHARED_TEXTURE_DEVICE");
    if (service && *service && token && strlen(token) >= 32 && registry) {
        char *end = NULL; errno = 0; uint64_t device_id = strtoull(registry, &end, 10);
        if (!errno && end && !*end && device_id) shared_registry_id = device_id;
    }
    const char *path = frame_mode?frame_path:getenv("BEDROCK_FULLFRAME_DRAW_DIR");
    if (!path || path[0] != '/') return;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC); struct stat st;
    if (fd < 0) return;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) { close(fd); return; }
    dir = fd;
}
void fullframe_replay_library(id<MTLLibrary> library, dispatch_data_t data) {
    if (dir < 0 || atomic_load(&claimed) || !library || !data) return;
    size_t size = dispatch_data_get_size(data);
    if (!size || size > LIB_MAX) { observe(D_LIBRARY_LIMIT); return; }
    const void *bytes = NULL; size_t mapped = 0;
    dispatch_data_t map = dispatch_data_create_map(data, &bytes, &mapped);
    if (!map || !bytes || mapped != size) { if (map) dispatch_release(map); return; }
    pthread_mutex_lock(&guard);
    if (!atomic_load(&claimed)) {
        int known = 0;
        for (unsigned i = 0; i < N; ++i) if (libs[i].obj == library) { known = 1; break; }
        if (!known && make_room(size)) {
            FFReplayBytes *copy = [[FFReplayBytes alloc] initWithBytes:bytes length:size];
            if (copy) { unsigned i = library_cursor++ % N; drop_library(i); libs[i] = (struct lib){ [library retain], copy }; }
        } else if (!known) {
            observe(D_LIBRARY_LIMIT);
        }
    }
    pthread_mutex_unlock(&guard); dispatch_release(map);
}
void fullframe_replay_function(id<MTLLibrary> library, id<MTLFunction> function, NSString *name) {
    if (dir < 0 || atomic_load(&claimed) || !library || !function || !name || name.length > 512) return;
    pthread_mutex_lock(&guard);
    if (!atomic_load(&claimed)) for (unsigned i = 0; i < N; ++i) if (libs[i].obj == library) {
        unsigned j = function_cursor++ % N;
        drop_function(j);
        fns[j] = (struct fn){ [function retain], [libs[i].data retain], [name copy] };
        break;
    }
    pthread_mutex_unlock(&guard);
}
void fullframe_replay_pipeline(id<MTLRenderPipelineState> state, MTLRenderPipelineDescriptor *d, int logic) {
    if (dir < 0 || atomic_load(&claimed) || !state || !d) return;
    if (logic) { observe(D_PIPELINE_STATE); rejected_pipeline("logic",d,nil,0); return; }
    if (!d.vertexFunction || !d.fragmentFunction || !d.rasterizationEnabled ||
        (d.rasterSampleCount != 1 && d.rasterSampleCount != 2 && d.rasterSampleCount != 4) ||
        (d.depthAttachmentPixelFormat && d.depthAttachmentPixelFormat != MTLPixelFormatDepth32Float && d.depthAttachmentPixelFormat != MTLPixelFormatDepth32Float_Stencil8) ||
        (d.stencilAttachmentPixelFormat && d.stencilAttachmentPixelFormat != MTLPixelFormatStencil8 && d.stencilAttachmentPixelFormat != MTLPixelFormatDepth32Float_Stencil8) ||
        !color_format(d.colorAttachments[0].pixelFormat)) { observe(D_PIPELINE_STATE); rejected_pipeline("attachment-or-stage",d,nil,0); return; }
    for (unsigned i = 1; i < 8; ++i) if (d.colorAttachments[i].pixelFormat) { observe(D_PIPELINE_STATE); rejected_pipeline("multiple-color-targets",d,nil,0); return; }
    if (d.vertexFunction.stageInputAttributes.count) { observe(D_PIPELINE_STATE); rejected_pipeline("stage-in",d,nil,0); return; }
    /* Qualify before selecting a draw, so a resource-dependent startup pass
     * does not consume the only capture and prevent later supported work. */
    NSError *error = nil; MTLRenderPipelineReflection *reflection = nil; ff_draw_layout layout;
    id<MTLRenderPipelineState> reflected = [state.device newRenderPipelineStateWithDescriptor:d
        options:MTLPipelineOptionBindingInfo | MTLPipelineOptionBufferTypeInfo reflection:&reflection error:&error];
    uint32_t ia_mask = 0; (void)ff_ia_pipeline_mask(state, &ia_mask);
    int eligible = reflected && !error && ff_shader_layout(reflection, ia_mask, &layout);
    [reflected release]; if (!eligible) { observe(reflected && !error ? D_BINDINGS : D_REFLECTION); rejected_pipeline(reflected&&!error?"bindings":"reflection",d,reflection,ia_mask); return; }
    if (geometry_profile && !pass_mode && !frame_mode && (!layout.ia_slot_mask || !layout.constant_count[0])) { observe(D_PROFILE); return; }
    MTLRenderPipelineColorAttachmentDescriptor *color = d.colorAttachments[0];
    NSMutableArray *vertexMutability=[NSMutableArray arrayWithCapacity:31],*fragmentMutability=[NSMutableArray arrayWithCapacity:31];
    for(NSUInteger i=0;i<31;i++){
        [vertexMutability addObject:@(d.vertexBuffers[i].mutability)];
        [fragmentMutability addObject:@(d.fragmentBuffers[i].mutability)];
    }
    NSDictionary *pipeline_state = @{ @"samples": @(d.rasterSampleCount), @"depth_format": @(d.depthAttachmentPixelFormat),
        @"vertex_buffer_mutability":vertexMutability,@"fragment_buffer_mutability":fragmentMutability,
        @"stencil_format": @(d.stencilAttachmentPixelFormat), @"alpha_to_coverage": @(d.alphaToCoverageEnabled),
        @"alpha_to_one": @(d.alphaToOneEnabled), @"blend": @[ @(color.blendingEnabled), @(color.writeMask),
            @(color.rgbBlendOperation), @(color.alphaBlendOperation), @(color.sourceRGBBlendFactor), @(color.destinationRGBBlendFactor),
            @(color.sourceAlphaBlendFactor), @(color.destinationAlphaBlendFactor) ] };
    pthread_mutex_lock(&guard);
    if (!atomic_load(&claimed)) {
        struct fn *v = NULL, *p = NULL;
        for (unsigned i = 0; i < N; ++i) {
            if (fns[i].obj == d.vertexFunction) v = &fns[i];
            if (fns[i].obj == d.fragmentFunction) p = &fns[i];
        }
        int registered = 0;
        if (v && p) {
            struct pso *slot = pipeline_slot();
            if (slot) { drop_pipeline(slot); *slot = (struct pso){ [state retain], [v->data retain], [p->data retain],
                [v->name copy], [p->name copy], d.colorAttachments[0].pixelFormat, d.inputPrimitiveTopology,
                layout.ia_slot_mask != 0, layout.ia_slot_mask, layout, [pipeline_state copy], 0, ++pipeline_clock, nil };
                registered = 1; }
        }
        if (!v || !p) observe(D_FUNCTION_MISSING); else if (!registered) observe(D_PSO_LIMIT);
    }
    pthread_mutex_unlock(&guard);
}
extern id<MTLSamplerState> fullframe_boundary_copy_sampler(uint64_t) __attribute__((weak_import));
extern int fullframe_boundary_native_bind(id,id<MTLRenderCommandEncoder>,NSUInteger) __attribute__((weak_import));
int fullframe_boundary_patch_arguments(id<MTLRenderCommandEncoder> encoder,id<MTLRenderPipelineState> pipeline,
    id<MTLBuffer> vertex,NSUInteger vo,id<MTLBuffer> fragment,NSUInteger fo,NSDictionary *textures,int mode,NSUInteger ordinal,NSMutableArray *owned){
    if(mode>=20&&mode<=22)return fullframe_boundary_native_bind&&fullframe_boundary_native_bind(textures[@"native_tables"],encoder,ordinal);
    if(mode==8||mode==9){
        NSArray *draws=textures[@"state"][@"draws"];if(ordinal>=draws.count||owned.count>1024)return 0;
        NSDictionary *draw=draws[ordinal],*record=draw[@"depth_state"];
        MTLDepthStencilDescriptor *d=[[MTLDepthStencilDescriptor alloc]init];
        d.depthCompareFunction=MTLCompareFunctionAlways;d.depthWriteEnabled=NO;
        if((id)record!=[NSNull null]){
            d.depthCompareFunction=[record[@"compare"] unsignedIntegerValue];d.depthWriteEnabled=[record[@"write"] boolValue];
            for(NSString *key in @[@"front",@"back"]){NSArray *r=record[key];MTLStencilDescriptor *v=nil;
                if((id)r!=[NSNull null]){v=[[MTLStencilDescriptor alloc]init];v.stencilCompareFunction=[r[0] unsignedIntegerValue];v.stencilFailureOperation=[r[1] unsignedIntegerValue];v.depthFailureOperation=[r[2] unsignedIntegerValue];v.depthStencilPassOperation=[r[3] unsignedIntegerValue];v.readMask=[r[4] unsignedIntValue];v.writeMask=[r[5] unsignedIntValue];}
                if([key isEqual:@"front"])d.frontFaceStencil=v;else d.backFaceStencil=v;[v release];}
        }
        id<MTLDepthStencilState> depth=[pipeline.device newDepthStencilStateWithDescriptor:d];[d release];if(!depth)return 0;[owned addObject:depth];[depth release];
        [encoder setDepthStencilState:depth];[encoder setStencilReferenceValue:[draw[@"stencil_ref"] unsignedIntValue]];
        if(mode==9)return 1;
        [encoder setRenderPipelineState:pipeline];NSArray *v=draw[@"viewport"],*c=draw[@"scissor"],*r=draw[@"raster"],*b=draw[@"blend_constant"];
        [encoder setViewport:(MTLViewport){[v[0] doubleValue],[v[1] doubleValue],[v[2] doubleValue],[v[3] doubleValue],[v[4] doubleValue],[v[5] doubleValue]}];
        [encoder setScissorRect:(MTLScissorRect){[c[0] unsignedIntegerValue],[c[1] unsignedIntegerValue],[c[2] unsignedIntegerValue],[c[3] unsignedIntegerValue]}];
        [encoder setTriangleFillMode:[r[0] unsignedIntegerValue]];[encoder setCullMode:[r[1] unsignedIntegerValue]];[encoder setDepthClipMode:[r[2] unsignedIntegerValue]];[encoder setFrontFacingWinding:[r[3] unsignedIntegerValue]];
        [encoder setDepthBias:[r[4] floatValue] slopeScale:[r[5] floatValue] clamp:[r[6] floatValue]];
        [encoder setBlendColorRed:[b[0] floatValue] green:[b[1] floatValue] blue:[b[2] floatValue] alpha:[b[3] floatValue]];
        return 1;
    }
    if(mode==3){
        const struct ff_draw_cut *cut=[textures[@"cut"] pointerValue];
        if(!cut||ordinal>=cut->draw_count||owned.count>2048)return 0;
        const ff_draw_plan *plan=&cut->draws[ordinal];
        struct {uint64_t address;uint32_t stride,length;} vertices[FF_VERTEX_RESOURCE_LIMIT]={0};
        for(unsigned stage=0;stage<3;stage++){
            size_t count=stage?plan->layout.constant_count[stage-1]:plan->binding_count;
            uint64_t constants[FF_CONSTANT_RESOURCE_LIMIT]={0};
            for(size_t i=0;i<count;i++){
                const ff_vertex_binding *b=stage?&plan->constants[stage-1][i]:&plan->bindings[i];uint64_t address=0;
                if(b->id){if(b->id>cut->snapshot_count||b->generation!=1||b->offset>cut->source_length[b->id-1]||b->length>cut->source_length[b->id-1]-b->offset)return 0;
                    id<MTLBuffer> buffer=cut->snapshots[b->id-1];address=buffer.gpuAddress+b->offset;
                    [encoder useResource:buffer usage:MTLResourceUsageRead stages:stage==2?MTLRenderStageFragment:MTLRenderStageVertex];}
                if(stage)constants[i]=address;else {vertices[i].address=address;vertices[i].stride=b->stride;vertices[i].length=b->length;}
            }
            if(!count)continue;
            id<MTLBuffer> table=[pipeline.device newBufferWithBytes:stage?(void *)constants:(void *)vertices length:count*(stage?8:16) options:MTLResourceStorageModeShared];
            if(!table)return 0;[owned addObject:table];[table release];
            if(stage==2)[encoder setFragmentBuffer:table offset:0 atIndex:29];else [encoder setVertexBuffer:table offset:0 atIndex:stage?29:16];
        }
        return 1;
    }
    ff_draw_layout layout;int found=0;pthread_mutex_lock(&guard);
    for(unsigned i=0;i<N;i++)if(psos[i].obj==pipeline){layout=psos[i].layout;found=1;break;}
    pthread_mutex_unlock(&guard);if(!found||owned.count>512)return 0;
    id<MTLBuffer> buffers[2]={vertex,fragment};NSUInteger offsets[2]={vo,fo};
    for(unsigned stage=0;stage<2;stage++){
        ff_shader_table_layout *table=&layout.arguments[stage];if(!table->byte_length)continue;
        id<MTLBuffer> source=buffers[stage];NSUInteger offset=offsets[stage];
        if(!source.contents||offset>source.length||table->byte_length>source.length-offset||table->byte_length>FF_SHADER_TABLE_BYTES_LIMIT)return 0;
        uint64_t values[FF_SHADER_TABLE_BYTES_LIMIT/8]={0};memcpy(values,(char *)source.contents+offset,table->byte_length);
        for(unsigned i=0;i<table->field_count;i++){
            ff_shader_field f=table->fields[i];uint64_t value=values[f.offset/8];if(!value)continue;
            if(mode==1&&f.kind==FF_FIELD_SAMPLER){id<MTLSamplerState> sampler=fullframe_boundary_copy_sampler?fullframe_boundary_copy_sampler(value):nil;if(!sampler)return 0;values[f.offset/8]=sampler.gpuResourceID._impl;}
            if((mode==2||mode==4)&&f.kind==FF_FIELD_TEXTURE){id<MTLTexture> texture=textures[@(value)];if(!texture)return 0;values[f.offset/8]=texture.gpuResourceID._impl;[encoder useResource:texture usage:MTLResourceUsageRead stages:stage?MTLRenderStageFragment:MTLRenderStageVertex];}
        }
        id<MTLBuffer> rebuilt=[pipeline.device newBufferWithBytes:values length:table->byte_length options:MTLResourceStorageModeShared];
        if(!rebuilt)return 0;[owned addObject:rebuilt];[rebuilt release];
        if(stage)[encoder setFragmentBuffer:rebuilt offset:0 atIndex:30];else [encoder setVertexBuffer:rebuilt offset:0 atIndex:30];
    }
    return 1;
}
id<MTLRenderPipelineState> fullframe_boundary_original_pipeline(NSDictionary *record){
    id<MTLRenderPipelineState> result=nil;pthread_mutex_lock(&guard);
    for(unsigned i=0;i<N;i++){struct pso *p=&psos[i];
        if(p->obj&&[p->vn isEqual:record[@"vertex_function"]]&&[p->pn isEqual:record[@"fragment_function"]]&&
           p->topology==[record[@"topology"] unsignedIntegerValue]&&[p->state isEqual:record[@"state"]]){result=[[p->obj retain]autorelease];break;}}
    pthread_mutex_unlock(&guard);return result;
}
NSDictionary *fullframe_boundary_depth_state(id object){
    NSDictionary *result=nil;pthread_mutex_lock(&guard);
    for(unsigned i=0;i<N;i++)if(depth_states[i].object==object){result=[[depth_states[i].state retain]autorelease];break;}
    pthread_mutex_unlock(&guard);return result;
}
/* One captured-frame diagnostic: reconstruct only the pipeline, retaining
 * original input resources in the source-process clone. Default-off caller. */
id<MTLRenderPipelineState> fullframe_boundary_rebuild_pipeline(id<MTLRenderPipelineState> original){
    static NSMutableDictionary *cache;
    pthread_mutex_lock(&guard);
    if(!cache)cache=[[NSMutableDictionary alloc]init];
    NSValue *key=[NSValue valueWithPointer:original];id<MTLRenderPipelineState> cached=cache[key];
    if(cached){pthread_mutex_unlock(&guard);return cached;}
    struct pso *p=NULL;for(unsigned i=0;i<N;i++)if(psos[i].obj==original){p=&psos[i];break;}
    if(!p||cache.count>=64){pthread_mutex_unlock(&guard);return nil;}
    NSData *vb=[p->vs.payload retain],*pb=[p->ps.payload retain];NSString *vn=[p->vn retain],*pn=[p->pn retain];
    NSDictionary *state=[p->state retain];NSUInteger format=p->format,topology=p->topology;
    pthread_mutex_unlock(&guard);
    dispatch_data_t vd=dispatch_data_create(vb.bytes,vb.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    dispatch_data_t pd=dispatch_data_create(pb.bytes,pb.length,NULL,DISPATCH_DATA_DESTRUCTOR_DEFAULT);
    NSError *error=nil;id<MTLLibrary> vl=[original.device newLibraryWithData:vd error:&error],pl=[original.device newLibraryWithData:pd error:&error];
    id<MTLFunction> vf=[vl newFunctionWithName:vn],pf=[pl newFunctionWithName:pn];
    MTLRenderPipelineDescriptor *d=[[MTLRenderPipelineDescriptor alloc]init];d.vertexFunction=vf;d.fragmentFunction=pf;
    d.inputPrimitiveTopology=topology;d.rasterSampleCount=[state[@"samples"] unsignedIntegerValue];
    d.depthAttachmentPixelFormat=[state[@"depth_format"] unsignedIntegerValue];d.stencilAttachmentPixelFormat=[state[@"stencil_format"] unsignedIntegerValue];
    d.alphaToCoverageEnabled=[state[@"alpha_to_coverage"] boolValue];d.alphaToOneEnabled=[state[@"alpha_to_one"] boolValue];
    for(unsigned i=0;i<31;i++){d.vertexBuffers[i].mutability=[state[@"vertex_buffer_mutability"][i] unsignedIntegerValue];d.fragmentBuffers[i].mutability=[state[@"fragment_buffer_mutability"][i] unsignedIntegerValue];}
    NSArray *b=state[@"blend"];MTLRenderPipelineColorAttachmentDescriptor *c=d.colorAttachments[0];c.pixelFormat=format;
    c.blendingEnabled=[b[0] boolValue];c.writeMask=[b[1] unsignedIntegerValue];c.rgbBlendOperation=[b[2] unsignedIntegerValue];c.alphaBlendOperation=[b[3] unsignedIntegerValue];
    c.sourceRGBBlendFactor=[b[4] unsignedIntegerValue];c.destinationRGBBlendFactor=[b[5] unsignedIntegerValue];c.sourceAlphaBlendFactor=[b[6] unsignedIntegerValue];c.destinationAlphaBlendFactor=[b[7] unsignedIntegerValue];
    id<MTLRenderPipelineState> rebuilt=vf&&pf?[original.device newRenderPipelineStateWithDescriptor:d error:&error]:nil;
    [d release];[vf release];[pf release];[vl release];[pl release];dispatch_release(vd);dispatch_release(pd);
    [vb release];[pb release];[vn release];[pn release];[state release];
    pthread_mutex_lock(&guard);if(rebuilt)cache[key]=rebuilt;pthread_mutex_unlock(&guard);[rebuilt release];return rebuilt;
}
void fullframe_replay_begin(id<MTLRenderCommandEncoder> encoder, id<MTLCommandBuffer> command, MTLRenderPassDescriptor *d) {
    if (pass_mode || !fullframe_replay_capture_armed() || !encoder || !command || !d) return;
    pthread_mutex_lock(&guard);
    for (unsigned i = 0; i < N; ++i) if (!passes[i].encoder) {
        struct pass *p = &passes[i]; memset(p, 0, sizeof(*p)); p->encoder = encoder; p->command = [command retain];
        MTLRenderPassColorAttachmentDescriptor *color = d.colorAttachments[0]; id<MTLTexture> texture = color.texture;
        int shared_load = shared_registry_id && texture.device.registryID == shared_registry_id;
        p->invalid = !texture || (color.loadAction == MTLLoadActionLoad && !shared_load) || color.level || color.slice || color.depthPlane ||
            d.visibilityResultBuffer || d.renderTargetArrayLength > 1 || d.tileWidth || d.tileHeight ||
            (d.depthAttachment.texture && ((d.depthAttachment.loadAction == MTLLoadActionLoad && !shared_load) || d.depthAttachment.level || d.depthAttachment.slice || d.depthAttachment.depthPlane)) ||
            (d.stencilAttachment.texture && ((d.stencilAttachment.loadAction == MTLLoadActionLoad && !shared_load) || d.stencilAttachment.level || d.stencilAttachment.slice || d.stencilAttachment.depthPlane));
        for (unsigned j = 1; j < 8; ++j) if (d.colorAttachments[j].texture) p->invalid = 1;
        if (texture) {
            p->width = texture.width; p->height = texture.height;
            p->device_id = texture.device.registryID; p->pixel_format = texture.pixelFormat;
            if (!p->width || !p->height || p->width > 2048 || p->height > 2048 || !color_format(texture.pixelFormat) ||
                (texture.sampleCount != 1 && texture.sampleCount != 2 && texture.sampleCount != 4) ||
                (texture.textureType != MTLTextureType2D && texture.textureType != MTLTextureType2DMultisample) || (d.renderTargetWidth && d.renderTargetWidth != p->width) ||
                (d.renderTargetHeight && d.renderTargetHeight != p->height)) p->invalid = 1;
        }
        id<MTLTexture> depth = d.depthAttachment.texture, stencil = d.stencilAttachment.texture;
        if ((depth && (depth.width != p->width || depth.height != p->height || depth.sampleCount != texture.sampleCount)) ||
            (stencil && (stencil.width != p->width || stencil.height != p->height || stencil.sampleCount != texture.sampleCount))) p->invalid = 1;
        p->attachments = [@{ @"color_load": @(color.loadAction), @"depth_format": @(depth.pixelFormat), @"stencil_format": @(stencil.pixelFormat),
            @"depth_load": @(d.depthAttachment.loadAction), @"depth_clear": @(d.depthAttachment.clearDepth),
            @"stencil_load": @(d.stencilAttachment.loadAction), @"stencil_clear": @(d.stencilAttachment.clearStencil),
            @"samples": @(texture.sampleCount), @"depth_stencil_alias": @(depth && depth == stencil) } copy];
        p->clear[0] = color.clearColor.red; p->clear[1] = color.clearColor.green;
        p->clear[2] = color.clearColor.blue; p->clear[3] = color.clearColor.alpha;
        for (unsigned j = 0; j < 4; ++j) if (!isfinite(p->clear[j])) p->invalid = 1;
        if (p->invalid) {
            observe(D_PASS_STATE);
            static _Atomic unsigned details;
            if (atomic_fetch_add(&details, 1) < 8) fprintf(stderr,
                "[full-frame-replay-pass] format=%lu samples=%lu color_load=%lu depth_format=%lu depth_load=%lu stencil_format=%lu stencil_load=%lu size=%llux%llu\n",
                (unsigned long)texture.pixelFormat, (unsigned long)texture.sampleCount, (unsigned long)color.loadAction,
                (unsigned long)depth.pixelFormat, (unsigned long)d.depthAttachment.loadAction,
                (unsigned long)stencil.pixelFormat, (unsigned long)d.stencilAttachment.loadAction,
                (unsigned long long)p->width, (unsigned long long)p->height);
        }
        break;
    }
    pthread_mutex_unlock(&guard);
}
void fullframe_replay_end(id encoder) {
    if (dir < 0 || !encoder) return;
    pthread_mutex_lock(&guard);
    for (unsigned i = 0; i < N; ++i) if (passes[i].encoder == encoder) {
        if (passes[i].pipeline) passes[i].pipeline->pins--;
        [passes[i].command release]; [passes[i].attachments release]; [passes[i].depth_state release]; memset(&passes[i], 0, sizeof(passes[i])); break;
    }
    pthread_mutex_unlock(&guard);
}
static int write_file(const char *temp, const char *final, NSData *data) {
    int fd = openat(dir, temp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    const uint8_t *p = data.bytes; size_t left = data.length;
    while (left) { ssize_t n = write(fd, p, left); if (n < 0 && errno == EINTR) continue;
        if (n <= 0) break; p += n; left -= (size_t)n; }
    int ok = !left && fsync(fd) == 0; if (close(fd)) ok = 0;
    if (ok) ok = linkat(dir, temp, dir, final, 0) == 0;
    unlinkat(dir, temp, 0); return ok;
}
static void submit_after_completion(struct pass *p, const struct wmtcmd_base *command) {
    const struct wmtcmd_render_draw *plain = (const void *)command;
    const struct wmtcmd_render_draw_indexed *index = command->type == WMTRenderCommandDrawIndexed ? (const void *)command : NULL;
    struct wmtcmd_render_draw normalized = {0};
    if (index) { normalized.primitive_type = index->primitive_type; normalized.vertex_count = index->index_count;
        normalized.instance_count = index->instance_count; normalized.base_instance = index->base_instance; plain = &normalized; }
    const struct wmtcmd_render_draw *draw = plain;
    struct pso *s = p->pipeline;
    if (!s) { observe(D_DRAW_PIPELINE); return; }
    if (geometry_profile && (draw->vertex_count <= 6 || !s->layout.ia_slot_mask || !s->layout.constant_count[0])) { observe(D_PROFILE); return; }
    if (!s || !p->device_id || p->pixel_format != s->format || !p->viewport_set || !p->scissor_set || !p->raster_set || p->invalid ||
        !draw->vertex_count || !draw->instance_count || draw->vertex_start > UINT32_MAX ||
        draw->instance_count > 1000000 || draw->vertex_count > 10000000 / draw->instance_count ||
        draw->primitive_type > WMTPrimitiveTypeTriangleStrip) { observe(D_DRAW_STATE); return; }
    if (p->scissor.x > p->width || p->scissor.y > p->height || p->scissor.width > p->width - p->scissor.x ||
        p->scissor.height > p->height - p->scissor.y || !p->scissor.width || !p->scissor.height) return;
    double *viewport = (double *)&p->viewport;
    for (unsigned i = 0; i < 6; ++i) if (!isfinite(viewport[i])) return;
    if (p->viewport.width <= 0 || p->viewport.height <= 0 || p->viewport.znear < 0 || p->viewport.zfar > 1 ||
        p->viewport.znear > p->viewport.zfar || p->raster.fill_mode > 1 || p->raster.cull_mode > 2 ||
        p->raster.depth_clip_mode > 1 || p->raster.winding > 1 || !isfinite(p->raster.depth_bias) ||
        !isfinite(p->raster.scole_scale) || !isfinite(p->raster.depth_bias_clamp)) return;
    int has_load = [p->attachments[@"color_load"] unsignedIntegerValue] == MTLLoadActionLoad ||
        ([p->attachments[@"depth_format"] unsignedIntegerValue] && [p->attachments[@"depth_load"] unsignedIntegerValue] == MTLLoadActionLoad) ||
        ([p->attachments[@"stencil_format"] unsignedIntegerValue] && [p->attachments[@"stencil_load"] unsignedIntegerValue] == MTLLoadActionLoad);
    int resources = has_load || index || s->layout.ia_slot_mask || s->layout.constant_count[0] || s->layout.constant_count[1] ||
        s->layout.arguments[0].field_count || s->layout.arguments[1].field_count;
    if (resources && (resource_cut.command != p->command || resource_cut.draw != command)) { observe(D_CUT_MISSING); return; }
    if (![s->state[@"samples"] isEqual:p->attachments[@"samples"]] ||
        ![s->state[@"depth_format"] isEqual:p->attachments[@"depth_format"]] ||
        ![s->state[@"stencil_format"] isEqual:p->attachments[@"stencil_format"]]) { observe(D_DRAW_STATE); return; }
    @autoreleasepool {
        NSMutableDictionary *manifest = [@{ @"format": @"bedrock-live-draw-replay", @"version": @1,
            @"width": @(p->width), @"height": @(p->height), @"device_id": @(p->device_id), @"pixel_format": @(s->format), @"topology": @(s->topology),
            @"vertex_function": s->vn, @"fragment_function": s->pn,
            @"pipeline_state": s->state, @"attachments": p->attachments,
            @"depth_state": p->depth_state ?: (id)[NSNull null], @"stencil_ref": @(p->stencil_ref),
            @"blend_constant": @[ @(p->blend[0]), @(p->blend[1]), @(p->blend[2]), @(p->blend[3]) ],
            @"clear": @[ @(p->clear[0]), @(p->clear[1]), @(p->clear[2]), @(p->clear[3]) ],
            @"viewport": @[ @(viewport[0]), @(viewport[1]), @(viewport[2]), @(viewport[3]), @(viewport[4]), @(viewport[5]) ],
            @"scissor": @[ @(p->scissor.x), @(p->scissor.y), @(p->scissor.width), @(p->scissor.height) ],
            @"raster": @[ @(p->raster.fill_mode), @(p->raster.cull_mode), @(p->raster.depth_clip_mode), @(p->raster.winding),
                @(p->raster.depth_bias), @(p->raster.scole_scale), @(p->raster.depth_bias_clamp) ],
            @"draw": @[ @(draw->primitive_type), @(draw->vertex_start), @(draw->vertex_count), @(draw->instance_count), @(draw->base_instance) ] } mutableCopy];
        if (resources) { manifest[@"resource_cut_id"] = resource_cut.identifier; manifest[@"ia_slot_mask"] = @(s->ia_mask); }
        if (has_load) {
            if (![resource_cut.identifier hasPrefix:@"draw-cut-"]) { [manifest release]; return; }
            const char *text = [resource_cut.identifier UTF8String] + 9; char *end = NULL; errno = 0; uint64_t cut = strtoull(text, &end, 10);
            if (errno || !end || *end || !cut) { [manifest release]; return; }
            manifest[@"shared_attachment_cut"] = @(cut);
        }
        if (index) manifest[@"indexed"] = @{ @"index_type": @(index->index_type), @"base_vertex": @(index->base_vertex),
            @"index_count": @(index->index_count), @"index_offset": @(index->index_buffer_offset) };
        NSData *json = [NSJSONSerialization dataWithJSONObject:manifest options:0 error:nil];
        [manifest release];
        if (!json || json.length > 16384) return;
        FFReplayBytes *vs = s->vs, *ps = s->ps; int expected = 0;
        if (!atomic_compare_exchange_strong(&claimed, &expected, 1)) return;
        if (manual_arm) (void)unlinkat(dir, "draw.arm", 0);
        observe(D_ACCEPTED);
        [p->command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
            if (completed.status != MTLCommandBufferStatusCompleted) return;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                @autoreleasepool {
                    if (write_file(".vertex.tmp", "vertex.metallib", vs.payload) &&
                        write_file(".fragment.tmp", "fragment.metallib", ps.payload))
                        (void)write_file(".replay.tmp", "replay.json", json);
                }
            });
        }];
    }
}
void fullframe_replay_command(id<MTLRenderCommandEncoder> encoder, const struct wmtcmd_base *next) {
    if (dir < 0 || atomic_load(&claimed) || !encoder || !next) return;
    pthread_mutex_lock(&guard);
    struct pass *p = NULL; for (unsigned i = 0; i < N; ++i) if (passes[i].encoder == encoder) { p = &passes[i]; break; }
    if (!p || p->invalid || atomic_load(&claimed)) { pthread_mutex_unlock(&guard); return; }
    switch ((enum WMTRenderCommandType)next->type) {
    case WMTRenderCommandNop: case WMTRenderCommandUseResource: case WMTRenderCommandSetVertexBuffer:
    case WMTRenderCommandSetVertexBufferOffset: case WMTRenderCommandSetFragmentBuffer:
    case WMTRenderCommandSetFragmentBufferOffset: case WMTRenderCommandSetFragmentTexture:
    case WMTRenderCommandSetFragmentBytes: case WMTRenderCommandMemoryBarrier:
    case WMTRenderCommandWaitForFence: case WMTRenderCommandUpdateFence: break;
    case WMTRenderCommandSetDSSO: {
        const struct wmtcmd_render_setdsso *d = (const void *)next; [p->depth_state release]; p->depth_state = nil;
        p->stencil_ref = d->stencil_ref;
        if (d->dsso) {
            for (unsigned i = 0; i < N; ++i) if (depth_states[i].object == (id)d->dsso) { p->depth_state = [depth_states[i].state retain]; break; }
            if (!p->depth_state) p->invalid = 1;
        }
        break;
    }
    case WMTRenderCommandSetBlendFactorAndStencilRef: {
        const struct wmtcmd_render_setblendcolor *b = (const void *)next;
        p->blend[0] = b->red; p->blend[1] = b->green; p->blend[2] = b->blue; p->blend[3] = b->alpha;
        p->stencil_ref = b->stencil_ref;
        for (unsigned i = 0; i < 4; ++i) if (!isfinite(p->blend[i])) p->invalid = 1;
        break;
    }
    case WMTRenderCommandSetVisibilityMode:
        if (((const struct wmtcmd_render_setvisibilitymode *)next)->mode) p->invalid = 1; break;
    case WMTRenderCommandSetPSO: {
        id obj = (id)((const struct wmtcmd_render_setpso *)next)->pso;
        if (p->pipeline) p->pipeline->pins--; p->pipeline = NULL;
        for (unsigned i = 0; i < N; ++i) if (psos[i].obj == obj) { p->pipeline = &psos[i]; psos[i].pins++; psos[i].last_used = ++pipeline_clock; break; } break;
    }
    case WMTRenderCommandSetRasterizerState:
        p->raster = *(const struct wmtcmd_render_setrasterizerstate *)next; p->raster_set = 1; break;
    case WMTRenderCommandSetViewport:
        p->viewport = ((const struct wmtcmd_render_setviewport *)next)->viewport; p->viewport_set = 1; break;
    case WMTRenderCommandSetViewports: {
        const struct wmtcmd_render_setviewports *v = (const struct wmtcmd_render_setviewports *)next;
        if (v->viewport_count != 1 || !v->viewports.ptr) p->invalid = 1;
        else { p->viewport = *(const struct WMTViewport *)v->viewports.ptr; p->viewport_set = 1; } break;
    }
    case WMTRenderCommandSetScissorRect:
        p->scissor = ((const struct wmtcmd_render_setscissorrect *)next)->scissor_rect; p->scissor_set = 1; break;
    case WMTRenderCommandSetScissorRects: {
        const struct wmtcmd_render_setscissorrects *s = (const struct wmtcmd_render_setscissorrects *)next;
        if (s->rect_count != 1 || !s->scissor_rects.ptr) p->invalid = 1;
        else { p->scissor = *(const struct WMTScissorRect *)s->scissor_rects.ptr; p->scissor_set = 1; } break;
    }
    case WMTRenderCommandDraw: case WMTRenderCommandDrawIndexed:
        submit_after_completion(p, next); p->invalid = 1; break;
    default: p->invalid = 1; break; /* Includes every other draw form. */
    }
    pthread_mutex_unlock(&guard);
}

FFSTPassPipelineSnapshot *fullframe_live_pipeline(id<MTLRenderPipelineState> object){return ff_pc_resolve(object);}
