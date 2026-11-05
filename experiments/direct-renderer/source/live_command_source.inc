#include "shader_ia.h"
extern int fullframe_live_has_native_buffer(const ffs_producer_context *,const ffs_producer_resource *);
/* Direct producer: ordered commands and resource updates. No draw cut, graph,
 * source GPU readback, or capture fallback exists in this path. MRC. */
extern FFSTPassPipelineSnapshot *fullframe_live_pipeline(id<MTLRenderPipelineState>);
extern NSDictionary *fullframe_boundary_depth_state(id);
extern int fullframe_live_sampler(uint64_t,ff_sampler_snapshot *);
extern void *fullframe_direct_journal_copy(uint64_t,uint64_t,uint64_t,uint64_t,size_t,size_t *);
static int live_enabled(void){const char *v=getenv("BEDROCK_LIVE_COMMANDS");return v&&!strcmp(v,"1");}
static NSMutableDictionary *live_pipeline_ids,*live_created;
static NSMutableArray *live_pipeline_owners;
static uint64_t live_next_pipeline=1,live_passes,live_draws;
static NSString *live_key(const ffs_producer_resource *r){return [NSString stringWithFormat:@"%llu:%llu:%llu",r->kind,r->root,r->allocation_generation];}
static const ffs_producer_resource *live_handle(const ffs_producer_context *c,uint64_t handle,uint64_t kind){
 const ffs_producer_resource *r=c->resources.ptr;for(size_t i=0;i<c->resource_count;i++)if(r[i].kind==kind&&r[i].handle==handle)return r+i;return NULL;
}
/* Upload heaps reuse one physical buffer for several logical slices. Match
 * the actual command range and access, never the first physical handle. */
static const ffs_producer_resource *live_buffer_handle(const ffs_producer_context*c,uint64_t handle,uint64_t offset,uint64_t length,uint32_t access){
 const ffs_producer_resource*rs=c->resources.ptr,*found=NULL;for(size_t i=0;i<c->resource_count;i++){const ffs_producer_resource*r=rs+i;if(r->kind!=FFS_BUFFER||r->handle!=handle||!(r->flags&access)||offset<r->offset||offset-r->offset>r->length||length>r->length-(offset-r->offset))continue;
  if(found&&(found->root!=r->root||found->allocation_generation!=r->allocation_generation))return NULL;found=r;}return found;
}
static NSDictionary *live_ref(const ffs_producer_resource *r,uint64_t offset,uint64_t length){
 return @{@"kind":@(r->kind),@"root":@(r->root),@"generation":@(r->allocation_generation),@"view":@(r->view),@"offset":@(offset),@"length":@(length),@"version":@(r->input_content_version)};
}
#include "live_startup_journal.inc"
static int live_buffer_event(const ffs_producer_context *c,const ffs_producer_resource *r,uint64_t offset,uint64_t length,NSMutableArray *events,NSMutableDictionary *blobs,NSMutableSet *seen){
 uint64_t capacity=r?(r->buffer_length?:((id<MTLBuffer>)r->handle).length):0;
 if(!r||r->kind!=FFS_BUFFER||!length||length>32u*1024u*1024u||offset<r->buffer_base_offset||offset-r->buffer_base_offset>capacity||length>capacity-(offset-r->buffer_base_offset)){fprintf(stderr,"[live-command-reject] reason=buffer-range offset=%llu length=%llu base=%llu capacity=%llu\n",offset,length,r?r->buffer_base_offset:0,capacity);return 0;}
 NSString *key=[NSString stringWithFormat:@"%@:%llu:%llu",live_key(r),offset,length];if([seen containsObject:key])return 1;
 [seen addObject:key];
 if(fullframe_live_has_native_buffer(c,r)||live_seeded_buffer(r))return 1;
 size_t n=0;void *owned=fullframe_direct_journal_copy(r->root,r->allocation_generation,offset,r->handle,(size_t)length,&n);
 if(owned){ffjp_record j;memcpy(&j,owned,sizeof(j));
  if(!ffjp_valid(&j,n)){free(owned);return 0;}
  if(j.flags==FFJP_UPDATE){NSString *name=[NSString stringWithFormat:@"live-upload-%04lu.bin",(unsigned long)blobs.count];
   blobs[name]=[NSData dataWithBytes:(uint8_t*)owned+sizeof(j) length:j.bytes];
   [events addObject:@{@"op":@"write_buffer",@"ref":live_ref(r,offset,length),@"blob":name,@"epoch":@(j.epoch)}];}
  free(owned);return 1;
 }
 /* Explicit initializer staging allocations are immutable until their queued
  * copy completes. Own those bytes now, before returning to the queue. */
 if(r->root&UINT64_C(0x8000000000000000)){
  id<MTLBuffer> b=(id<MTLBuffer>)r->handle;if(!b.contents||offset>b.length||length>b.length-offset)return 0;
  NSString *name=[NSString stringWithFormat:@"live-upload-%04lu.bin",(unsigned long)blobs.count];blobs[name]=[NSData dataWithBytes:(uint8_t*)b.contents+offset length:length];
  [events addObject:@{@"op":@"write_buffer",@"ref":live_ref(r,offset,length),@"blob":name,@"epoch":@1}];return 1;
 }
 fprintf(stderr,"[live-command-reject] reason=missing-buffer-writer root=%llu generation=%llu offset=%llu length=%llu\n",r->root,r->allocation_generation,offset,length);return 0;
}
typedef struct{uint64_t begin,end,maximum;size_t ordinal;const ffs_producer_resource*resource;}live_address_range;
typedef struct{size_t count;live_address_range*ranges;NSMutableDictionary*textures;}live_pass_lookup;
static int live_compare_address(const void*a,const void*b){const live_address_range*x=a,*y=b;return x->begin<y->begin?-1:x->begin>y->begin?1:x->ordinal<y->ordinal?-1:x->ordinal>y->ordinal;}
static live_pass_lookup *live_build_lookup(const ffs_producer_context*c){
 live_pass_lookup*index=calloc(1,sizeof(*index));if(!index)return NULL;index->textures=[NSMutableDictionary dictionary];index->ranges=calloc(c->resource_count?:1,sizeof(live_address_range));if(!index->ranges){free(index);return NULL;}
 const ffs_producer_resource*rs=c->resources.ptr;for(size_t i=0;i<c->resource_count;i++){const ffs_producer_resource*r=rs+i;
  if(r->kind==FFS_BUFFER&&(r->flags&FFS_READ)){id<MTLBuffer>b=(id<MTLBuffer>)r->handle;uint64_t address=b.gpuAddress;if(!r->length||r->offset>UINT64_MAX-address||r->length>UINT64_MAX-address-r->offset)continue;index->ranges[index->count++]=(live_address_range){address+r->offset,address+r->offset+r->length,0,i,r};}
  else if(r->kind==FFS_TEXTURE){uint64_t identifier=((id<MTLTexture>)r->handle).gpuResourceID._impl;if(identifier&&!index->textures[@(identifier)])index->textures[@(identifier)]=@(i);}
 }
 qsort(index->ranges,index->count,sizeof(live_address_range),live_compare_address);uint64_t maximum=0;for(size_t i=0;i<index->count;i++){maximum=MAX(maximum,index->ranges[i].end);index->ranges[i].maximum=maximum;}return index;
}
static void live_free_lookup(live_pass_lookup*index){if(index){free(index->ranges);free(index);}}
static NSDictionary *live_address(const ffs_producer_context *c,const live_pass_lookup*index,uint64_t address,uint64_t length,NSMutableArray *events,NSMutableDictionary *blobs,NSMutableSet *seen){
 if(!address)return @{@"zero":@YES};if(!index)return nil;const ffs_producer_resource*found=NULL;uint64_t offset=0;size_t selected=0,lo=0,hi=index->count;
 while(lo<hi){size_t mid=lo+(hi-lo)/2;if(index->ranges[mid].begin<=address)lo=mid+1;else hi=mid;}
 while(lo){const live_address_range*range=&index->ranges[--lo];if(range->maximum<=address)break;if(range->end<=address)continue;const ffs_producer_resource*r=range->resource;
  if(found&&(found->root!=r->root||found->allocation_generation!=r->allocation_generation))return nil;if(!found||range->ordinal>selected){found=r;offset=r->offset+address-range->begin;selected=range->ordinal;}
 }
 if(!found)return nil;uint64_t available=found->offset+found->length-offset;if(!length)length=available;if(length>available)return nil;
 if(!live_buffer_event(c,found,offset,length,events,blobs,seen))return nil;return live_ref(found,offset,length);
}
static const void *live_table(uint64_t handle,uint64_t offset,size_t length){if(!length)return "";id<MTLBuffer>b=(id<MTLBuffer>)handle;
 return b&&b.contents&&offset<=b.length&&length<=b.length-offset?(const uint8_t*)b.contents+offset:NULL;}
static NSDictionary *live_tables(const ffs_producer_context*c,const live_pass_lookup*index,const ff_draw_layout*l,uint64_t b[2][31],uint64_t o[2][31],NSMutableArray*events,NSMutableDictionary*blobs,NSMutableSet*seen){
 NSMutableArray *ia=[NSMutableArray array],*constants=[NSMutableArray array],*arguments=[NSMutableArray array];
 size_t count=__builtin_popcount(l->ia_slot_mask);typedef struct{uint64_t address;uint32_t stride,length;} IA;
 const IA *entries=live_table(b[0][16],o[0][16],count*sizeof(IA));if(!entries)return nil;
 for(size_t i=0;i<count;i++){IA e;memcpy(&e,entries+i,sizeof(e));NSDictionary*r=live_address(c,index,e.address,e.length,events,blobs,seen);if(!r)return nil;[ia addObject:@{@"ref":r,@"stride":@(e.stride),@"length":@(e.length)}];}
 for(unsigned st=0;st<2;st++){
  NSMutableArray *cs=[NSMutableArray array],*as=[NSMutableArray array];const uint64_t *values=live_table(b[st][29],o[st][29],l->constant_count[st]*8);if(!values)return nil;
  for(size_t i=0;i<l->constant_count[st];i++){uint64_t v;memcpy(&v,values+i,8);NSDictionary*r=live_address(c,index,v,0,events,blobs,seen);if(!r)return nil;[cs addObject:r];}
  values=live_table(b[st][30],o[st][30],l->arguments[st].byte_length);if(!values)return nil;
  for(size_t i=0;i<l->arguments[st].field_count;i++){ff_shader_field f=l->arguments[st].fields[i];if((f.offset&7)||f.offset>=l->arguments[st].byte_length)return nil;uint64_t v;memcpy(&v,(const uint8_t*)values+f.offset,8);id value=nil;
   if(f.kind==FF_FIELD_BUFFER)value=live_address(c,index,v,0,events,blobs,seen);
   else if(!v)value=@{@"zero":@YES};
   else if(f.kind==FF_FIELD_VALUE)value=@(v);
   else if(f.kind==FF_FIELD_TEXTURE){const ffs_producer_resource *rs=c->resources.ptr;NSNumber*n=index?index->textures[@(v)]:nil;const ffs_producer_resource*r=n?rs+n.unsignedIntegerValue:NULL;if(r)value=live_ref(r,0,0);}
   else if(f.kind==FF_FIELD_SAMPLER){ff_sampler_snapshot s;if(fullframe_live_sampler(v,&s))value=@{@"address":@[@(s.address[0]),@(s.address[1]),@(s.address[2])],@"filter":@[@(s.min_filter),@(s.mag_filter),@(s.mip_filter)],@"lod":@[@(s.lod_min),@(s.lod_max)],@"anisotropy":@(s.max_anisotropy),@"compare":@(s.compare),@"normalized":@(s.normalized),@"border":@(s.border)};}
   if(!value)return nil;[as addObject:@{@"offset":@(f.offset),@"kind":@(f.kind),@"value":value}];
  }[constants addObject:cs];[arguments addObject:as];
 }
 return @{@"ia":ia,@"constants":constants,@"arguments":arguments};
}
static NSDictionary *live_pipeline(uint64_t handle,NSMutableArray *definitions,NSMutableDictionary *blobs,ff_draw_layout *layout){
 FFSTPassPipelineSnapshot *s=fullframe_live_pipeline((id<MTLRenderPipelineState>)handle);if(!s||s.layout.length!=sizeof(*layout))return nil;memcpy(layout,s.layout.bytes,sizeof(*layout));
 if(!live_pipeline_ids){live_pipeline_ids=[[NSMutableDictionary alloc]init];live_pipeline_owners=[[NSMutableArray alloc]init];}
 NSValue *key=[NSValue valueWithPointer:(void*)(uintptr_t)handle];NSNumber *identifier=live_pipeline_ids[key];
 if(!identifier){if(live_next_pipeline>512)return nil;identifier=@(live_next_pipeline++);live_pipeline_ids[key]=identifier;[live_pipeline_owners addObject:(id)handle];[live_pipeline_owners addObject:s];
  NSString *vn=ff_private_library_name(s.vertexLibrary),*pn=ff_private_library_name(s.fragmentLibrary);if(!vn||!pn)return nil;blobs[vn]=s.vertexLibrary;blobs[pn]=s.fragmentLibrary;
  NSMutableArray *args=[NSMutableArray array];for(unsigned st=0;st<2;st++){NSMutableArray*a=[NSMutableArray array];for(size_t j=0;j<layout->arguments[st].field_count;j++)[a addObject:@{@"offset":@(layout->arguments[st].fields[j].offset),@"kind":@(layout->arguments[st].fields[j].kind)}];[args addObject:a];}
  NSDictionary *record=@{@"id":@0,@"vertex_file":vn,@"fragment_file":pn,@"vertex_function":s.vertexFunction,@"fragment_function":s.fragmentFunction,@"state":s.state,@"topology":@(s.topology),@"ia_slot_mask":@(layout->ia_slot_mask),@"constant_count":@[@(layout->constant_count[0]),@(layout->constant_count[1])],@"argument_bytes":@[@(layout->arguments[0].byte_length),@(layout->arguments[1].byte_length)],@"argument_layout":args};
  struct ff_ia_fetch_layout fetch={0};if(!ff_ia_pipeline_fetch((id<MTLRenderPipelineState>)handle,&fetch)&&layout->ia_slot_mask)return nil;NSMutableArray *slots=[NSMutableArray array];for(unsigned i=0;i<32;i++)[slots addObject:(fetch.known_mask&(1u<<i))?@[@(fetch.slots[i].byte_end),@(fetch.slots[i].step_function),@(fetch.slots[i].step_rate)]:@[]];
  [definitions addObject:@{@"id":identifier,@"record":record,@"fetch":slots}];
 }
 return @{@"op":@"pipeline",@"id":identifier};
}
static NSDictionary *live_attachment(const ffs_producer_context*c,uint64_t handle,uint64_t load,uint64_t store,NSArray*clear){
 const ffs_producer_resource*r=live_handle(c,handle,FFS_TEXTURE);return r?@{@"ref":live_ref(r,0,0),@"load":@(load),@"store":@(store),@"clear":clear}:nil;
}
static uint64_t live_prepare(id<MTLCommandBuffer>command,struct WMTRenderPassInfo*info,const ffs_producer_context*c,uint64_t payload,int directory){
 uint64_t liveBegin=payload_profile_now(),liveResourcesDone=0,liveCommandsDone=0;live_pass_lookup*index=NULL;
 const char *why="unsupported-category";uint64_t ordinal=0;NSMutableArray *instructions=[NSMutableArray array],*events=[NSMutableArray array],*definitions=[NSMutableArray array],*resources=[NSMutableArray array],*types=[NSMutableArray array];
 NSMutableDictionary*blobs=[NSMutableDictionary dictionary];NSMutableSet*seen=[NSMutableSet set];const ffs_producer_resource*rs=c->resources.ptr;
 NSMutableDictionary *record=header(c,payload,@"bedrock-live-commands");record[@"device_id"]=@(command.device.registryID);
 if(!live_created)live_created=[[NSMutableDictionary alloc]init];
 for(size_t i=0;i<c->resource_count;i++){NSDictionary*r=reference_legacy(rs+i,payload);if(!r){why="resource-descriptor";goto reject;}[resources addObject:r];
  if(rs[i].kind!=FFS_BUFFER&&rs[i].kind!=FFS_TEXTURE){why="resource-kind";goto reject;}
  NSString *key=live_key(rs+i);pthread_mutex_lock(&live_history_lock);BOOL created=live_created[key]!=nil,limit=!created&&live_created.count>=65536;if(!created&&!limit)live_created[key]=@YES;pthread_mutex_unlock(&live_history_lock);if(limit){why="resource-limit";goto reject;}if(!created){NSMutableDictionary *event=[NSMutableDictionary dictionaryWithDictionary:@{@"op":@"create",@"resource":r}];if(rs[i].kind==FFS_TEXTURE){id<MTLTexture>tex=(id<MTLTexture>)rs[i].handle;while(tex.parentTexture)tex=tex.parentTexture;event[@"descriptor"]=@{@"type":@(tex.textureType),@"format":@(tex.pixelFormat),@"width":@(tex.width),@"height":@(tex.height),@"mip_count":@(tex.mipmapLevelCount),@"array_length":@(tex.arrayLength),@"sample_count":@(tex.sampleCount),@"usage":@(tex.usage)};}[events addObject:event];(void)live_seed_resource(rs+i,events,blobs);}
 }
 liveResourcesDone=payload_profile_now();
 if(c->category==FFS_RENDER){index=live_build_lookup(c);if(!index){why="address-index-allocation";goto reject;}}
 if(c->category==FFS_RENDER||c->category==FFS_CLEAR||c->category==FFS_RESOLVE){
  if(!info||info->visibility_buffer||info->render_target_array_length>1){why="render-shape";goto reject;}
  for(unsigned i=1;i<8;i++)if(info->colors[i].texture){why="multiple-color-targets";goto reject;}
  NSMutableDictionary *a=[NSMutableDictionary dictionary];NSDictionary*t;
  if(info->colors[0].texture){const struct WMTColorAttachmentInfo *v=info->colors;if(v->level||v->slice||v->depth_plane){why="attachment-view";goto reject;}
   t=live_attachment(c,v->texture,v->load_action,v->store_action,@[@(v->clear_color.r),@(v->clear_color.g),@(v->clear_color.b),@(v->clear_color.a)]);if(!t){why="color-identity";goto reject;}a[@"color"]=t;
   if(v->resolve_texture){const ffs_producer_resource*r=live_handle(c,v->resolve_texture,FFS_TEXTURE);if(!r){why="resolve-identity";goto reject;}a[@"resolve"]=live_ref(r,0,0);}
  }
  if(info->depth.texture){t=live_attachment(c,info->depth.texture,info->depth.load_action,info->depth.store_action,@[@(info->depth.clear_depth)]);if(!t){why="depth-identity";goto reject;}a[@"depth"]=t;}
  if(info->stencil.texture){t=live_attachment(c,info->stencil.texture,info->stencil.load_action,info->stencil.store_action,@[@(info->stencil.clear_stencil)]);if(!t){why="stencil-identity";goto reject;}a[@"stencil"]=t;}
  record[@"attachments"]=a;uint64_t buffers[2][31]={{0}},offsets[2][31]={{0}};ff_draw_layout layout={0};int has_pipeline=0;
  for(unsigned st=0;st<2;st++)for(unsigned slot=0;slot<31;slot++)buffers[st][slot]=info->bedrock_cut_argbuffer;
  const struct wmtcmd_base *head=c->category==FFS_RENDER?info->bedrock_cut_commands.ptr:NULL;
  for(const struct wmtcmd_base *cmd=head;cmd;cmd=cmd->next.ptr){if(ordinal++>=c->command_count){why="command-count";goto reject;}[types addObject:@(cmd->type)];NSDictionary *op=nil;
   switch(cmd->type){
   case WMTRenderCommandNop:case WMTRenderCommandUseResource:case WMTRenderCommandWaitForFence:case WMTRenderCommandUpdateFence:op=@{@"op":@"order"};break;
   case WMTRenderCommandSetPSO:op=live_pipeline(((const struct wmtcmd_render_setpso*)cmd)->pso,definitions,blobs,&layout);has_pipeline=op!=nil;break;
   case WMTRenderCommandSetVertexBuffer:case WMTRenderCommandSetFragmentBuffer:{const struct wmtcmd_render_setbuffer*v=(const void*)cmd;unsigned st=cmd->type==WMTRenderCommandSetFragmentBuffer;if(v->index>=31){why="buffer-slot";goto reject;}buffers[st][v->index]=v->buffer;offsets[st][v->index]=v->offset;op=@{@"op":@"table-source"};break;}
   case WMTRenderCommandSetVertexBufferOffset:case WMTRenderCommandSetFragmentBufferOffset:{const struct wmtcmd_render_setbufferoffset*v=(const void*)cmd;unsigned st=cmd->type==WMTRenderCommandSetFragmentBufferOffset;if(v->index>=31){why="buffer-slot";goto reject;}offsets[st][v->index]=v->offset;op=@{@"op":@"table-source"};break;}
   case WMTRenderCommandSetRasterizerState:{const struct wmtcmd_render_setrasterizerstate*v=(const void*)cmd;op=@{@"op":@"raster",@"v":@[@(v->fill_mode),@(v->cull_mode),@(v->depth_clip_mode),@(v->winding),@(v->depth_bias),@(v->scole_scale),@(v->depth_bias_clamp)]};break;}
   case WMTRenderCommandSetViewport:case WMTRenderCommandSetViewports:{const struct WMTViewport*v;if(cmd->type==WMTRenderCommandSetViewport)v=&((const struct wmtcmd_render_setviewport*)cmd)->viewport;else{const struct wmtcmd_render_setviewports*x=(const void*)cmd;if(x->viewport_count!=1){why="viewport-count";goto reject;}v=x->viewports.ptr;}if(!v){why="viewport";goto reject;}op=@{@"op":@"viewport",@"v":@[@(v->originX),@(v->originY),@(v->width),@(v->height),@(v->znear),@(v->zfar)]};break;}
   case WMTRenderCommandSetScissorRect:case WMTRenderCommandSetScissorRects:{const struct WMTScissorRect*v;if(cmd->type==WMTRenderCommandSetScissorRect)v=&((const struct wmtcmd_render_setscissorrect*)cmd)->scissor_rect;else{const struct wmtcmd_render_setscissorrects*x=(const void*)cmd;if(x->rect_count!=1){why="scissor-count";goto reject;}v=x->scissor_rects.ptr;}if(!v){why="scissor";goto reject;}op=@{@"op":@"scissor",@"v":@[@(v->x),@(v->y),@(v->width),@(v->height)]};break;}
   case WMTRenderCommandSetDSSO:{uint64_t h=((const struct wmtcmd_render_setdsso*)cmd)->dsso;id state=h?fullframe_boundary_depth_state((id)h):(id)[NSNull null];if(state)op=@{@"op":@"depth",@"v":state};break;}
   case WMTRenderCommandSetBlendFactorAndStencilRef:{const struct wmtcmd_render_setblendcolor*v=(const void*)cmd;op=@{@"op":@"blend",@"v":@[@(v->red),@(v->green),@(v->blue),@(v->alpha)],@"stencil":@(v->stencil_ref)};break;}
   case WMTRenderCommandDraw:case WMTRenderCommandDrawIndexed:{if(!has_pipeline){why="pipeline-missing";goto reject;}NSDictionary*tables=live_tables(c,index,&layout,buffers,offsets,events,blobs,seen);if(!tables){why="table-resource-or-writer";goto reject;}NSMutableDictionary*d=[NSMutableDictionary dictionaryWithDictionary:@{@"op":@"draw",@"tables":tables}];
    if(cmd->type==WMTRenderCommandDraw){const struct wmtcmd_render_draw*v=(const void*)cmd;d[@"v"]=@[@(v->primitive_type),@(v->vertex_start),@(v->vertex_count),@(v->instance_count),@(v->base_instance)];}
    else{const struct wmtcmd_render_draw_indexed*v=(const void*)cmd;uint64_t n=v->index_count*(v->index_type?4:2);const ffs_producer_resource*r=live_buffer_handle(c,v->index_buffer,v->index_buffer_offset,n,FFS_READ);if(!r||!live_buffer_event(c,r,v->index_buffer_offset,n,events,blobs,seen)){why="index-writer";goto reject;}d[@"index"]=live_ref(r,v->index_buffer_offset,n);d[@"index_type"]=@(v->index_type);d[@"base_vertex"]=@(v->base_vertex);d[@"v"]=@[@(v->primitive_type),@0,@(v->index_count),@(v->instance_count),@(v->base_instance)];}
    op=d;live_draws++;break;}
   case WMTRenderCommandSetVisibilityMode:if(((const struct wmtcmd_render_setvisibilitymode*)cmd)->mode==WMTVisibilityResultModeDisabled)op=@{@"op":@"order"};break;
   default:break;
   }
   if(!op){why="unsupported-render-command";fprintf(stderr,"[live-command-reject] type=%u\n",cmd->type);goto reject;}[instructions addObject:op];
  }
 }else if(c->category==FFS_BLIT){
  for(const struct wmtcmd_base*cmd=c->commands.ptr;cmd;cmd=cmd->next.ptr){if(ordinal++>=c->command_count){why="command-count";goto reject;}[types addObject:@(cmd->type)];NSDictionary*op=nil;
   if(cmd->type==WMTBlitCommandNop||cmd->type==WMTBlitCommandWaitForFence||cmd->type==WMTBlitCommandUpdateFence)op=@{@"op":@"order"};
   else if(cmd->type==WMTBlitCommandCopyFromBufferToBuffer){const struct wmtcmd_blit_copy_from_buffer_to_buffer*v=(const void*)cmd;const ffs_producer_resource*src=live_buffer_handle(c,v->src,v->src_offset,v->copy_length,FFS_READ),*dst=live_buffer_handle(c,v->dst,v->dst_offset,v->copy_length,FFS_WRITE);if(!src||!dst||!live_buffer_event(c,src,v->src_offset,v->copy_length,events,blobs,seen)){why="copy-buffer-writer";goto reject;}op=@{@"op":@"copy_buffer",@"source":live_ref(src,v->src_offset,v->copy_length),@"destination":live_ref(dst,v->dst_offset,v->copy_length)};}
   else if(cmd->type==WMTBlitCommandCopyFromBufferToTexture){const struct wmtcmd_blit_copy_from_buffer_to_texture*v=(const void*)cmd;const ffs_producer_resource*src=live_buffer_handle(c,v->src,v->src_offset,(uint64_t)v->bytes_per_row*v->size.height*v->size.depth,FFS_READ),*dst=live_handle(c,v->dst,FFS_TEXTURE);uint64_t n=(uint64_t)v->bytes_per_row*v->size.height*v->size.depth;if(!src||!dst||!live_buffer_event(c,src,v->src_offset,n,events,blobs,seen)){why="texture-upload-writer";goto reject;}op=@{@"op":@"upload_texture",@"source":live_ref(src,v->src_offset,n),@"destination":live_ref(dst,0,0),@"row":@(v->bytes_per_row),@"image":@(v->bytes_per_image),@"size":@[@(v->size.width),@(v->size.height),@(v->size.depth)],@"origin":@[@(v->origin.x),@(v->origin.y),@(v->origin.z)],@"slice":@(v->slice),@"level":@(v->level)};}
   else if(cmd->type==WMTBlitCommandCopyFromTextureToBuffer){const struct wmtcmd_blit_copy_from_texture_to_buffer*v=(const void*)cmd;const ffs_producer_resource*src=live_handle(c,v->src,FFS_TEXTURE),*dst=live_buffer_handle(c,v->dst,v->offset,(uint64_t)v->bytes_per_row*v->size.height*v->size.depth,FFS_WRITE);uint64_t n=(uint64_t)v->bytes_per_row*v->size.height*v->size.depth;if(!src||!dst||!fullframe_chunk_readback_register(c,payload,(uint32_t)(ordinal-1),(uint32_t)(dst-rs),v->offset,v->bytes_per_row,v->size.width*ff_texture_pixel_size(((id<MTLTexture>)src->handle).pixelFormat),v->size.height)){why="readback-register";goto reject;}if(src&&dst)op=@{@"op":@"read_texture",@"command":@(ordinal-1),@"source":live_ref(src,0,0),@"destination":live_ref(dst,v->offset,n),@"row":@(v->bytes_per_row),@"image":@(v->bytes_per_image),@"size":@[@(v->size.width),@(v->size.height),@(v->size.depth)],@"origin":@[@(v->origin.x),@(v->origin.y),@(v->origin.z)],@"slice":@(v->slice),@"level":@(v->level)};}
   else if(cmd->type==WMTBlitCommandCopyFromTextureToTexture){const struct wmtcmd_blit_copy_from_texture_to_texture*v=(const void*)cmd;const ffs_producer_resource*src=live_handle(c,v->src,FFS_TEXTURE),*dst=live_handle(c,v->dst,FFS_TEXTURE);if(src&&dst)op=@{@"op":@"copy_texture",@"source":live_ref(src,0,0),@"destination":live_ref(dst,0,0),@"source_slice":@(v->src_slice),@"source_level":@(v->src_level),@"source_origin":@[@(v->src_origin.x),@(v->src_origin.y),@(v->src_origin.z)],@"size":@[@(v->src_size.width),@(v->src_size.height),@(v->src_size.depth)],@"destination_slice":@(v->dst_slice),@"destination_level":@(v->dst_level),@"destination_origin":@[@(v->dst_origin.x),@(v->dst_origin.y),@(v->dst_origin.z)]};}
   if(!op){why="unsupported-blit-command";goto reject;}[instructions addObject:op];
  }
 }else if(c->category==FFS_TIMESTAMP||c->category==FFS_SIGNAL_EVENT){record[@"readback_index"]=@(c->readback_index);record[@"query_count"]=@(c->query_count);const ffs_producer_dependency*d=c->dependencies.ptr;NSMutableArray*deps=[NSMutableArray array];for(size_t i=0;i<c->dependency_count;i++)[deps addObject:@{@"domain":@(d[i].domain),@"id":@(d[i].id),@"value":@(d[i].value),@"action":@(d[i].action)}];record[@"dependencies"]=deps;if(c->category==FFS_TIMESTAMP)record[@"operations"]=@[@{@"op":@"timestamp",@"mode":@"command-buffer-end-ns",@"readback_index":@(c->readback_index),@"query_count":@(c->query_count)}];else{NSMutableArray*query=[NSMutableArray array];for(NSDictionary*dep in deps)if([dep[@"domain"]unsignedIntegerValue]==FFS_EVENT&&[dep[@"action"]unsignedIntegerValue]==FFS_SIGNAL){NSMutableDictionary*q=[NSMutableDictionary dictionaryWithDictionary:dep];q[@"op"]=@"signal_event";[query addObject:q];}record[@"operations"]=query;}
 }else goto reject;
 liveCommandsDone=payload_profile_now();
 if(ordinal!=c->command_count){why="command-count-final";goto reject;}
 record[@"resources"]=resources;record[@"command_types"]=types;record[@"instructions"]=instructions;record[@"events"]=events;record[@"pipelines"]=definitions;
 for(NSString*name in blobs)if(!write_bytes(directory,name.UTF8String,[blobs[name] bytes],[blobs[name] length])){why="blob-write";goto reject;}
 if(!write_json(directory,"bindings.json",record)){why="command-write";goto reject;}
 {uint64_t bytes=directory_bytes(directory);pthread_mutex_lock(&guard);int ok=bytes!=UINT64_MAX&&!failed&&budget_allows_locked(bytes);if(ok){stored_bytes+=bytes;reserved_bytes+=bytes;register_payload(directory,payload,c->category==FFS_RENDER||c->category==FFS_CLEAR||c->category==FFS_RESOLVE?"render":"operation");}else failed=1;pthread_mutex_unlock(&guard);payload_close(directory);if(!ok){live_free_lookup(index);return 0;}}
 live_free_lookup(index);index=NULL;
 live_passes++;if(live_passes<=4||!(live_passes%128))fprintf(stderr,"[live-command-cost] payloads=%llu resources=%llu commands=%llu resource_ns=%llu command_ns=%llu publish_ns=%llu\n",live_passes,c->resource_count,c->command_count,liveResourcesDone-liveBegin,liveCommandsDone-liveResourcesDone,payload_profile_now()-liveCommandsDone);if(live_passes<=4||!(live_passes%128))fprintf(stderr,"[live-command] payloads=%llu draws=%llu capture_calls=0 reconstruction_calls=0\n",live_passes,live_draws);return payload;
reject:
 live_free_lookup(index);
 fprintf(stderr,"[live-command-reject] reason=%s category=%u ordinal=%llu commands=%llu resources=%llu\n",why,c->category,ordinal,c->command_count,c->resource_count);payload_close(directory);payload_fail_fast(directory);return 0;
}
