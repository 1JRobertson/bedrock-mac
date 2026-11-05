#import "shared_texture_pass_capture.h"
#import "packed_replay.h"
#import "library_hash_name.h"
extern NSString *ff_replay_private_library_name(NSData *, NSArray *) __attribute__((weak_import));
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#if !__has_feature(objc_arc)
#error shared_texture_pass_capture.m requires ARC
#endif
#define PASS_LIBRARY_LIMIT (64u*1024u*1024u)
#define PASS_MANIFEST_LIMIT (4u*1024u*1024u)
@implementation FFSTPassPipelineSnapshot @end
@interface FFSTPassRecord ()
@property(nonatomic, readwrite, strong) NSDictionary *manifest;
@property(nonatomic, readwrite, strong) NSDictionary<NSString *, NSData *> *libraries;
@property(nonatomic, readwrite, strong) NSArray *byteOwners;
@end
@implementation FFSTPassRecord @end
/* Immutable value view: ordinary JSON fallback materializes each row lazily. */
@interface PRLazyDraws : NSArray
@property(nonatomic,strong) NSData *rows;
@property(nonatomic,strong) NSArray *depths;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,id> *materializedRows;
- (instancetype)initWithRows:(NSData *)rows depths:(NSArray *)depths;
@end
@implementation PRLazyDraws
- (instancetype)initWithRows:(NSData *)rows depths:(NSArray *)depths {
    self=[super init];if(self){_rows=rows;_depths=depths;_materializedRows=[NSMutableDictionary dictionary];}return self;
}
- (NSUInteger)count{return _rows.length/sizeof(pr_row);}
- (id)objectAtIndex:(NSUInteger)index {
    if(index>=self.count)[NSException raise:NSRangeException format:@"Packed draw index out of range"];
    @synchronized(self){
        NSNumber *key=@(index);id value=_materializedRows[key];
        if(!value){pr_row row;memcpy(&row,(const uint8_t *)_rows.bytes+index*sizeof(row),sizeof(row));
            value=pr_row_dictionary(&row,_depths,nil);if(!value)[NSException raise:NSInvalidArgumentException format:@"Invalid packed draw"];
            _materializedRows[key]=value;}
        return value;
    }
}
- (id)copyWithZone:(NSZone *)zone {(void)zone;return self;}
- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state objects:(id __unsafe_unretained [])buffer count:(NSUInteger)length {
    NSUInteger start=state->state,count=self.count;if(start>=count)return 0;NSUInteger n=MIN(length,count-start);
    for(NSUInteger i=0;i<n;i++)buffer[i]=[self objectAtIndex:start+i];
    state->itemsPtr=buffer;state->mutationsPtr=&state->extra[0];state->state=start+n;return n;
}
@end
@interface FFSTPackedPassRecord : FFSTPassRecord
@property(nonatomic) NSUInteger packedMode;
@property(nonatomic,strong) NSData *packedRows;
@property(nonatomic,strong) NSArray *packedDepths;
@end
@implementation FFSTPackedPassRecord
- (NSUInteger)privatePackedReplayMode{return self.packedMode;}
- (NSData *)privatePackedReplayBytes{return packed_replay_encode(self.manifest,self.packedRows,self.packedDepths);}
@end

static NSString *library_name(NSData *data) { return ff_private_library_name(data); }
static NSArray *argument_layout(const ff_shader_table_layout *table) {
    NSMutableArray *fields=[NSMutableArray array];
    for(unsigned i=0;i<table->field_count;++i)[fields addObject:@{@"offset":@(table->fields[i].offset),@"kind":@(table->fields[i].kind)}];
    return fields;
}
static NSDictionary *pipeline_record(FFSTPassPipelineSnapshot *snapshot, NSUInteger identifier,
    NSMutableDictionary<NSString *,NSData *> *libraries, NSMutableArray *owners, uint64_t *bytes, const char **reason) {
    if(!snapshot||!snapshot.vertexLibrary||!snapshot.fragmentLibrary||snapshot.vertexLibrary.length<32||snapshot.fragmentLibrary.length<32||
       snapshot.vertexLibrary.length>8u*1024u*1024u||snapshot.fragmentLibrary.length>8u*1024u*1024u||
       !snapshot.vertexFunction.length||snapshot.vertexFunction.length>512||!snapshot.fragmentFunction.length||snapshot.fragmentFunction.length>512||
       ![snapshot.state isKindOfClass:[NSDictionary class]]||snapshot.topology>MTLPrimitiveTopologyClassTriangle||snapshot.layout.length!=sizeof(ff_draw_layout)||!snapshot.byteOwners.count){*reason="pipeline-metadata";return nil;}
    ff_draw_layout layout;memcpy(&layout,snapshot.layout.bytes,sizeof(layout));
    for(unsigned stage=0;stage<2;++stage)if(layout.constant_count[stage]>FF_CONSTANT_RESOURCE_LIMIT||layout.arguments[stage].field_count>FF_SHADER_FIELD_LIMIT||
        layout.arguments[stage].byte_length!=layout.arguments[stage].field_count*8){*reason="pipeline-layout-bounds";return nil;}
    NSArray *data=@[snapshot.vertexLibrary,snapshot.fragmentLibrary];NSMutableArray *names=[NSMutableArray array];uint64_t added=0;
    for(NSData *blob in data){NSString *name=ff_replay_private_library_name?ff_replay_private_library_name(blob,snapshot.byteOwners):nil;
        if(!name)name=library_name(blob);NSData *existing=libraries[name];
        if(existing&&![existing isEqual:blob]){*reason="library-hash-conflict";return nil;}
        if(!existing&&![names containsObject:name])added+=blob.length;[names addObject:name];}
    if(added>PASS_LIBRARY_LIMIT-*bytes){*reason="library-budget";return nil;}
    NSDictionary *record=@{@"id":@(identifier),@"vertex_file":names[0],@"fragment_file":names[1],
        @"vertex_function":snapshot.vertexFunction,@"fragment_function":snapshot.fragmentFunction,@"state":snapshot.state,@"topology":@(snapshot.topology),
        @"ia_slot_mask":@(layout.ia_slot_mask),@"constant_count":@[@(layout.constant_count[0]),@(layout.constant_count[1])],
        @"argument_bytes":@[@(layout.arguments[0].byte_length),@(layout.arguments[1].byte_length)],
        @"argument_layout":@[argument_layout(&layout.arguments[0]),argument_layout(&layout.arguments[1])]};
    if(![NSJSONSerialization isValidJSONObject:record]){*reason="pipeline-json";return nil;}
    for(NSUInteger i=0;i<data.count;++i)if(!libraries[names[i]])libraries[names[i]]=data[i];
    [owners addObjectsFromArray:snapshot.byteOwners];*bytes+=added;return record;
}
#ifdef FF_LIBRARY_CACHE_FIXTURE
NSDictionary *ff_private_test_pipeline_record(FFSTPassPipelineSnapshot *snapshot, NSUInteger identifier,
    NSMutableDictionary *libraries, NSMutableArray *owners, uint64_t *bytes, const char **reason) {
    return pipeline_record(snapshot,identifier,libraries,owners,bytes,reason);
}
#endif
static NSDictionary *attachment_record(const struct WMTRenderPassInfo *pass,const char **reason) {
    if(!pass||!pass->colors[0].texture||pass->visibility_buffer||pass->render_target_array_length>1||pass->tile_width||pass->tile_height){*reason="attachment-shape";return nil;}
    id<MTLTexture> color=(__bridge id<MTLTexture>)(void *)(uintptr_t)pass->colors[0].texture;
    id<MTLTexture> depth=(__bridge id<MTLTexture>)(void *)(uintptr_t)pass->depth.texture;
    id<MTLTexture> stencil=(__bridge id<MTLTexture>)(void *)(uintptr_t)pass->stencil.texture;
    if(!color.width||!color.height||color.width>8192||color.height>8192||pass->colors[0].level||pass->colors[0].slice||pass->colors[0].depth_plane||
       (pass->render_target_width&&pass->render_target_width!=color.width)||(pass->render_target_height&&pass->render_target_height!=color.height)){*reason="color-size-or-view";return nil;}
    for(unsigned i=1;i<8;++i)if(pass->colors[i].texture){*reason="multiple-colors";return nil;}
    if((depth&&(depth.width!=color.width||depth.height!=color.height||depth.sampleCount!=color.sampleCount||pass->depth.level||pass->depth.slice||pass->depth.depth_plane))||
       (stencil&&(stencil.width!=color.width||stencil.height!=color.height||stencil.sampleCount!=color.sampleCount||pass->stencil.level||pass->stencil.slice||pass->stencil.depth_plane))){*reason="depth-stencil-shape";return nil;}
    const struct WMTClearColor *c=&pass->colors[0].clear_color;
    if(!isfinite(c->r)||!isfinite(c->g)||!isfinite(c->b)||!isfinite(c->a)||!isfinite(pass->depth.clear_depth)){*reason="clear-nonfinite";return nil;}
    return @{@"width":@(color.width),@"height":@(color.height),@"device_id":@(color.device.registryID),@"pixel_format":@(color.pixelFormat),
        @"samples":@(color.sampleCount),@"color_load":@(pass->colors[0].load_action),@"color_store":@(pass->colors[0].store_action),
        @"clear":@[@(c->r),@(c->g),@(c->b),@(c->a)],@"depth_format":@(depth.pixelFormat),@"depth_load":@(pass->depth.load_action),
        @"depth_store":@(pass->depth.store_action),@"depth_clear":@(pass->depth.clear_depth),@"stencil_format":@(stencil.pixelFormat),
        @"stencil_load":@(pass->stencil.load_action),@"stencil_store":@(pass->stencil.store_action),@"stencil_clear":@(pass->stencil.clear_stencil),
        @"depth_stencil_alias":@(depth&&depth==stencil)};
}
static BOOL draw_matches(const ff_draw_plan *plan,const struct wmtcmd_base *command) {
    if(plan->command!=command)return NO;
    if(command->type==WMTRenderCommandDraw){const struct wmtcmd_render_draw *d=(const void *)command;
        return !plan->indexed&&plan->primitive==d->primitive_type&&plan->vertex_start==d->vertex_start&&plan->vertex_count==d->vertex_count&&
            plan->instance_count==d->instance_count&&plan->base_instance==d->base_instance;}
    if(command->type==WMTRenderCommandDrawIndexed){const struct wmtcmd_render_draw_indexed *d=(const void *)command;
        return plan->indexed&&plan->primitive==d->primitive_type&&plan->vertex_count==d->index_count&&plan->index_type==d->index_type&&
            plan->index_offset==d->index_buffer_offset&&plan->base_vertex==d->base_vertex&&plan->instance_count==d->instance_count&&plan->base_instance==d->base_instance;}
    return NO;
}
static void pass_capture_reject(const struct ff_draw_cut *cut,const char *stage,const char *reason,
                                unsigned command_ordinal,uint32_t command_type,NSUInteger draw_ordinal) {
    const char *enabled=getenv("DXMT_FRAME_STREAM");if(!enabled||strcmp(enabled,"1"))return;
    fprintf(stderr,"[full-frame-pass-capture-reject] cut=%llu stage=%s reason=%s command=%u type=%u draw=%lu\n",
            (unsigned long long)(cut?cut->capture_id:0),stage,reason,command_ordinal,command_type,(unsigned long)draw_ordinal);
}
FFSTPassRecord *ffst_pass_capture_record(const struct WMTRenderPassInfo *pass,
    const struct wmtcmd_base *head,const struct ff_draw_cut *resources,FFSTPassPipelineResolver resolve,FFSTPassDepthResolver resolve_depth) {
    if(!head||!resources||!resources->capture_id||!resources->draws||!resources->draw_count||resources->draw_count>FF_DRAW_PASS_LIMIT||!resolve){
        pass_capture_reject(resources,"input","invalid-arguments",0,UINT32_MAX,0);return nil;}
    const char *attachment_reason="unknown";NSDictionary *attachment=attachment_record(pass,&attachment_reason);
    if(!attachment){pass_capture_reject(resources,"attachment",attachment_reason,0,UINT32_MAX,0);return nil;}
    NSMutableArray *pipelines=[NSMutableArray array],*draws=[NSMutableArray array],*owners=[NSMutableArray array],*pipeline_objects=[NSMutableArray array];
    const char *option=getenv("BEDROCK_PRIVATE_PACKED_REPLAY");
    NSUInteger packed_mode=option&&!strcmp(option,"1")?1:option&&!strcmp(option,"2")?2:0;
    NSMutableData *packed=packed_mode?[NSMutableData dataWithLength:resources->draw_count*sizeof(pr_row)]:nil;
    NSMutableArray *depths=packed_mode?[NSMutableArray array]:nil;
    if(packed_mode&&(!packed||!depths))packed_mode=0;NSUInteger packed_count=0;
    NSMutableDictionary *libraries=[NSMutableDictionary dictionary];uint64_t library_bytes=0,invocations=0;
    id<MTLRenderPipelineState> pipeline=nil;id depth=[NSNull null];uint32_t stencil=0;float blend[4]={0};
    struct WMTViewport viewport={0};struct WMTScissorRect scissor={0};struct wmtcmd_render_setrasterizerstate raster={0};unsigned state=0;
    BOOL geometry=NO,failed=NO;const char *failure_reason=NULL;unsigned command_ordinal=0;
    uint32_t material_draws=0,material_geometry_draws=0;const struct wmtcmd_base *next=head;
    unsigned visited=0;for(;next&&next!=resources->stop_command&&visited<65536;next=next->next.ptr,++visited){
        command_ordinal=visited;
        switch((enum WMTRenderCommandType)next->type){
        case WMTRenderCommandNop:case WMTRenderCommandUseResource:case WMTRenderCommandSetVertexBuffer:case WMTRenderCommandSetFragmentBuffer:
        case WMTRenderCommandSetVertexBufferOffset:case WMTRenderCommandSetFragmentBufferOffset:case WMTRenderCommandSetFragmentTexture:case WMTRenderCommandSetFragmentBytes:
        case WMTRenderCommandMemoryBarrier:case WMTRenderCommandWaitForFence:case WMTRenderCommandUpdateFence:break;
        case WMTRenderCommandSetVisibilityMode:if(((const struct wmtcmd_render_setvisibilitymode *)next)->mode){failed=YES;failure_reason="visibility";}break;
        case WMTRenderCommandSetPSO:pipeline=(__bridge id<MTLRenderPipelineState>)(void *)(uintptr_t)((const struct wmtcmd_render_setpso *)next)->pso;break;
        case WMTRenderCommandSetDSSO:{const struct wmtcmd_render_setdsso *d=(const void *)next;stencil=d->stencil_ref;
            depth=d->dsso&&resolve_depth?resolve_depth((__bridge id<MTLDepthStencilState>)(void *)(uintptr_t)d->dsso):(d->dsso?nil:(id)[NSNull null]);if(!depth){failed=YES;failure_reason="depth-state";}break;}
        case WMTRenderCommandSetBlendFactorAndStencilRef:{const struct wmtcmd_render_setblendcolor *b=(const void *)next;
            blend[0]=b->red;blend[1]=b->green;blend[2]=b->blue;blend[3]=b->alpha;stencil=b->stencil_ref;
            for(unsigned i=0;i<4;++i)if(!isfinite(blend[i])){failed=YES;failure_reason="blend-nonfinite";}break;}
        case WMTRenderCommandSetViewport:viewport=((const struct wmtcmd_render_setviewport *)next)->viewport;state|=1;break;
        case WMTRenderCommandSetViewports:{const struct wmtcmd_render_setviewports *v=(const void *)next;if(v->viewport_count!=1||!v->viewports.ptr){failed=YES;failure_reason="viewport-count";break;}
            viewport=*(const struct WMTViewport *)v->viewports.ptr;state|=1;break;}
        case WMTRenderCommandSetScissorRect:scissor=((const struct wmtcmd_render_setscissorrect *)next)->scissor_rect;state|=2;break;
        case WMTRenderCommandSetScissorRects:{const struct wmtcmd_render_setscissorrects *v=(const void *)next;if(v->rect_count!=1||!v->scissor_rects.ptr){failed=YES;failure_reason="scissor-count";break;}
            scissor=*(const struct WMTScissorRect *)v->scissor_rects.ptr;state|=2;break;}
        case WMTRenderCommandSetRasterizerState:raster=*(const struct wmtcmd_render_setrasterizerstate *)next;state|=4;break;
        case WMTRenderCommandDraw:case WMTRenderCommandDrawIndexed:{
            NSUInteger index=packed_mode==2?packed_count:draws.count;
            if(index>=resources->draw_count){failed=YES;failure_reason="draw-count";break;}
            if(state!=7){failed=YES;failure_reason="draw-state";break;}
            if(!pipeline){failed=YES;failure_reason="pipeline-missing";break;}
            const ff_draw_plan *plan=&resources->draws[index];if(!draw_matches(plan,next)){failed=YES;failure_reason="draw-mismatch";break;}
            const double *v=(const double *)&viewport;for(unsigned i=0;i<6;++i)if(!isfinite(v[i])){failed=YES;failure_reason="viewport-nonfinite";}
            uint64_t width=[attachment[@"width"] unsignedLongLongValue],height=[attachment[@"height"] unsignedLongLongValue];
            if(viewport.width<=0||viewport.height<=0||viewport.znear<0||viewport.zfar>1||viewport.znear>viewport.zfar||
               scissor.x>width||scissor.y>height||!scissor.width||!scissor.height||scissor.width>width-scissor.x||scissor.height>height-scissor.y||
               raster.fill_mode>1||raster.cull_mode>2||raster.depth_clip_mode>1||raster.winding>1||!isfinite(raster.depth_bias)||!isfinite(raster.scole_scale)||!isfinite(raster.depth_bias_clamp)||
               plan->primitive>WMTPrimitiveTypeTriangleStrip||plan->vertex_start>UINT32_MAX||!plan->vertex_count||!plan->instance_count||plan->instance_count>1000000||plan->vertex_count>10000000/plan->instance_count||
               plan->vertex_count*plan->instance_count>10000000-invocations){failed=YES;failure_reason="draw-bounds";}
            if(failed)break;
            NSUInteger p=[pipeline_objects indexOfObjectIdenticalTo:pipeline];
            FFSTPassPipelineSnapshot *snapshot=resolve(pipeline);
            if(!snapshot||snapshot.layout.length!=sizeof(plan->layout)||memcmp(snapshot.layout.bytes,&plan->layout,sizeof(plan->layout))){failed=YES;failure_reason="pipeline-layout";break;}
            if(p==NSNotFound){p=pipelines.count;NSDictionary *record=pipeline_record(snapshot,p,libraries,owners,&library_bytes,&failure_reason);
                if(!record){failed=YES;if(!failure_reason)failure_reason="pipeline-record";break;}[pipelines addObject:record];[pipeline_objects addObject:pipeline];}
            BOOL draw_geometry=plan->vertex_count>6&&plan->layout.ia_slot_mask&&plan->layout.constant_count[0],material=NO;
            for(unsigned stage=0;stage<2;++stage)for(unsigned i=0;i<plan->layout.arguments[stage].field_count;++i)
                if(plan->arguments[stage][i].kind==FF_FIELD_TEXTURE&&plan->arguments[stage][i].value)material=YES;
            if(packed_mode){
                NSUInteger di=[depths indexOfObjectIdenticalTo:depth];
                if(di==NSNotFound){di=depths.count;[depths addObject:depth];}
                if(di>=PR_DEPTHS||index>=PR_ROWS){failed=YES;failure_reason="packed-bounds";break;}
                pr_row row={0};row.pipeline=(uint32_t)p;row.resources=(uint32_t)index;row.depth=(uint32_t)di;row.stencil=stencil;
                memcpy(row.blend,blend,sizeof(row.blend));memcpy(row.viewport,v,sizeof(row.viewport));
                row.scissor[0]=(uint32_t)scissor.x;row.scissor[1]=(uint32_t)scissor.y;
                row.scissor[2]=(uint32_t)scissor.width;row.scissor[3]=(uint32_t)scissor.height;
                row.raster[0]=raster.fill_mode;row.raster[1]=raster.cull_mode;row.raster[2]=raster.depth_clip_mode;row.raster[3]=raster.winding;
                row.bias[0]=raster.depth_bias;row.bias[1]=raster.scole_scale;row.bias[2]=raster.depth_bias_clamp;
                row.draw[0]=plan->primitive;row.draw[1]=plan->vertex_start;row.draw[2]=plan->vertex_count;
                row.draw[3]=plan->instance_count;row.draw[4]=plan->base_instance;row.material_geometry=draw_geometry&&material;
                if(plan->indexed){row.indexed=1;row.index_type=plan->index_type;row.base_vertex=plan->base_vertex;
                    row.index_count=plan->vertex_count;row.index_offset=plan->index_offset;}
                memcpy((uint8_t *)packed.mutableBytes+index*sizeof(row),&row,sizeof(row));packed_count++;
            }
            if(packed_mode!=2){
                NSMutableDictionary *record=[@{@"pipeline":@(p),@"resources":@(index),@"depth_state":depth,@"stencil_ref":@(stencil),
                    @"blend_constant":@[@(blend[0]),@(blend[1]),@(blend[2]),@(blend[3])],@"viewport":@[@(v[0]),@(v[1]),@(v[2]),@(v[3]),@(v[4]),@(v[5])],
                    @"scissor":@[@(scissor.x),@(scissor.y),@(scissor.width),@(scissor.height)],
                    @"raster":@[@(raster.fill_mode),@(raster.cull_mode),@(raster.depth_clip_mode),@(raster.winding),@(raster.depth_bias),@(raster.scole_scale),@(raster.depth_bias_clamp)],
                    @"draw":@[@(plan->primitive),@(plan->vertex_start),@(plan->vertex_count),@(plan->instance_count),@(plan->base_instance)]} mutableCopy];
                if(plan->indexed)record[@"indexed"]=@{@"index_type":@(plan->index_type),@"index_count":@(plan->vertex_count),@"base_vertex":@(plan->base_vertex),@"index_offset":@(plan->index_offset)};
                record[@"material_geometry"]=@(draw_geometry&&material);[draws addObject:record];
            }
            if(material)++material_draws;if(draw_geometry&&material)++material_geometry_draws;
            invocations+=plan->vertex_count*plan->instance_count;
            if(draw_geometry)geometry=YES;break;
        }
        default:failed=YES;failure_reason="unsupported-command";break;
        }
        if(failed)break;
    }
    if(!failed&&next)command_ordinal=visited;
    NSUInteger captured=packed_mode==2?packed_count:draws.count;
    if(!captured){pass_capture_reject(resources,"traversal",failure_reason?:"no-draws",command_ordinal,next?next->type:UINT32_MAX,0);return nil;}
    BOOL complete=resources->complete_pass&&!failed&&!next&&captured==resources->draw_count;
    if(!complete)pass_capture_reject(resources,"traversal",failure_reason?:(!resources->complete_pass?"incomplete-cut":next?"unconsumed-command":"draw-count"),command_ordinal,next?next->type:UINT32_MAX,captured);
    NSData *packedRows=nil;NSArray *packedDepths=nil;NSArray *publishedDraws=draws;
    if(packed_mode){[packed setLength:packed_count*sizeof(pr_row)];packedRows=[packed copy];packedDepths=[depths copy];
        if(packed_mode==2)publishedDraws=[[PRLazyDraws alloc]initWithRows:packedRows depths:packedDepths];}
    NSMutableDictionary *manifest=[@{@"format":@"bedrock-native-pass-replay",@"version":@2,@"cut_id":@(resources->capture_id),
        @"resource_cut_id":[NSString stringWithFormat:@"draw-cut-%llu",(unsigned long long)resources->capture_id],
        @"attachments":attachment,@"pipelines":pipelines,@"draws":publishedDraws,@"complete_pass":@(complete),
        @"contains_geometry_candidate":@(geometry),@"material_draw_count":@(material_draws),@"material_geometry_draw_count":@(material_geometry_draws),
        @"vertex_invocations":@(invocations),@"captured_prefix_draws":@(resources->draw_count)} mutableCopy];
    if([attachment[@"color_load"] unsignedIntegerValue]==MTLLoadActionLoad||
       ([attachment[@"depth_format"] unsignedIntegerValue]&&[attachment[@"depth_load"] unsignedIntegerValue]==MTLLoadActionLoad)||
       ([attachment[@"stencil_format"] unsignedIntegerValue]&&[attachment[@"stencil_load"] unsignedIntegerValue]==MTLLoadActionLoad))manifest[@"shared_attachment_cut"]=@(resources->capture_id);
    /* The sink serializes and enforces PASS_MANIFEST_LIMIT. This producer
     * builds only JSON values, so another full graph walk here is redundant. */
    FFSTPassRecord *record=packed_mode?[FFSTPackedPassRecord new]:[FFSTPassRecord new];
    if(packed_mode){FFSTPackedPassRecord *candidate=(FFSTPackedPassRecord *)record;
        candidate.packedMode=packed_mode;candidate.packedRows=packedRows;candidate.packedDepths=packedDepths;}
    record.manifest=manifest;record.libraries=libraries;record.byteOwners=owners;return record;
}
static int write_atomic(int directory,NSString *name,NSData *data) {
    NSString *temporary=[NSString stringWithFormat:@".%@.%@.tmp",name,[NSUUID UUID].UUIDString];
    int fd=openat(directory,temporary.fileSystemRepresentation,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);if(fd<0)return 0;
    const uint8_t *p=data.bytes;size_t left=data.length;
    while(left){ssize_t n=write(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=(size_t)n;}
    int ok=!left&&!fsync(fd);if(close(fd))ok=0;
    if(ok)ok=!linkat(directory,temporary.fileSystemRepresentation,directory,name.fileSystemRepresentation,0);
    unlinkat(directory,temporary.fileSystemRepresentation,0);return ok;
}
int ffst_pass_capture_write(int directory,FFSTPassRecord *record,const char *manifest_name) {
    struct stat st;if(directory<0||!record||!manifest_name||fstat(directory,&st)||!S_ISDIR(st.st_mode)||st.st_uid!=getuid()||(st.st_mode&077))return 0;
    size_t length=strnlen(manifest_name,65);if(!length||length>64||!strcmp(manifest_name,".")||!strcmp(manifest_name,".."))return 0;
    for(size_t i=0;i<length;++i){char c=manifest_name[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||(c>='0'&&c<='9')||c=='_'||c=='-'||c=='.'))return 0;}
    for(NSString *name in [[record.libraries allKeys] sortedArrayUsingSelector:@selector(compare:)])if(!write_atomic(directory,name,record.libraries[name]))return 0;
    NSData *json=[NSJSONSerialization dataWithJSONObject:record.manifest options:0 error:nil];
    return json&&json.length<=PASS_MANIFEST_LIMIT&&write_atomic(directory,@(manifest_name),json)&&!fsync(directory);
}
