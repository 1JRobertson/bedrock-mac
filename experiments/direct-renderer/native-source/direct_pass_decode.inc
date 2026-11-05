/* Direct pass wire reader. No legacy resource graph, snapshot decoder or
 * per-draw Objective-C resource records are constructed. */
#include "direct_pass_journal.h"
#include "packed_replay.h"
@interface FFDPDecoded : NSObject {
@public
 ffmd_view plan,wire;
 ff_vertex_snapshot *buffers;
 ff_texture_snapshot *textures;
 ff_sampler_snapshot *samplers;
 size_t nb,nt,ns,nd;
 ffjp_entry events[FF_DRAW_RESOURCE_LIMIT];
}
@property(nonatomic,strong) NSDictionary *blobs;
@property(nonatomic,strong) NSData *journal;
@end
@implementation FFDPDecoded
- (void)dealloc {free(buffers);free(textures);free(samplers);}
@end
static FFDPDecoded *ffdp_decode(NSDictionary *blobs){
 NSData *p=blobs[@"draw-plan.bin"],*w=blobs[@"draw-resource-cut.bin"];
 FFDPDecoded *d=[FFDPDecoded new];d.blobs=blobs;
 if(!p||!w||!ffmd_view_decode(p.bytes,p.length,FFMD_PLAN,&d->plan)||!ffmd_view_decode(w.bytes,w.length,FFMD_GRAPH,&d->wire))return nil;
 uint8_t digest[32];CC_SHA256(p.bytes,(CC_LONG)p.length,digest);if(memcmp(digest,d->wire.header.plan_sha256,32))return nil;
 d->nb=d->wire.sections[0].count;d->nd=d->wire.sections[1].count;d->nt=d->wire.sections[4].count;d->ns=d->wire.sections[6].count;
 if(d->nb>FF_DRAW_RESOURCE_LIMIT||d->nd>FFST_PASS_DRAW_LIMIT||d->nd!=d->plan.sections[0].count||d->nt>FF_TEXTURE_RESOURCE_LIMIT||d->ns>FF_SAMPLER_RESOURCE_LIMIT)return nil;
 d->buffers=calloc(MAX(1,d->nb),sizeof(*d->buffers));d->textures=calloc(MAX(1,d->nt),sizeof(*d->textures));d->samplers=calloc(MAX(1,d->ns),sizeof(*d->samplers));if(!d->buffers||!d->textures||!d->samplers)return nil;
 d.journal=blobs[@"direct-journal.bin"];ffjp_batch batch;
 if(d.journal.length<sizeof(batch))return nil;memcpy(&batch,d.journal.bytes,sizeof(batch));
 if(batch.magic!=FFJP_BATCH_MAGIC||batch.version!=1||batch.count!=d->nb||batch.reserved||batch.bytes!=d.journal.length||sizeof(batch)+d->nb*sizeof(ffjp_entry)>d.journal.length)return nil;
 uint64_t cursor=sizeof(batch)+d->nb*sizeof(ffjp_entry);
 for(size_t i=0;i<d->nb;i++){ffjp_entry e;memcpy(&e,(const uint8_t*)d.journal.bytes+sizeof(batch)+i*sizeof(e),sizeof(e));if(e.offset!=cursor||e.bytes<sizeof(ffjp_record)||e.bytes>d.journal.length-cursor)return nil;d->events[i]=e;cursor+=e.bytes;}
 if(cursor!=d.journal.length)return nil;
 for(size_t i=0;i<d->nb;i++){ffmd_graph_snapshot s;if(!ffmd_view_row(&d->wire,0,i,&s,sizeof(s))||s.generation!=1||s.has_provenance!=1||!s.source_incarnation||!s.source_generation||!s.length||s.length>FFJP_LIMIT||s.source_offset>UINT64_MAX-s.length)return nil;
  d->buffers[i]=(ff_vertex_snapshot){.id=i+1,.generation=1,.length=s.length};
  ffjp_entry event=d->events[i];ffjp_record r;memcpy(&r,(const uint8_t*)d.journal.bytes+event.offset,sizeof(r));
  if(!ffjp_valid(&r,event.bytes)||r.root!=s.source_incarnation||r.generation!=s.source_generation||s.source_offset<r.offset||s.source_offset-r.offset>r.length||s.length>r.length-(s.source_offset-r.offset))return nil;
 }
 size_t planes=0;uint64_t textureBytes=0;
 for(size_t i=0;i<d->nt;i++){
  ffmd_graph_texture s;if(!ffmd_view_row(&d->wire,4,i,&s,sizeof(s))||!ff_texture_pixel_size(s.format)||!s.width||s.width>8192||!s.height||s.height>8192||!s.mip_count||s.mip_count>14||s.array_length!=1||(s.texture_type!=MTLTextureType2D&&s.texture_type!=MTLTextureTypeCube)||s.has_swizzle>1||s.plane_count>FF_TEXTURE_PLANE_LIMIT||s.plane_first!=planes||s.plane_count!=(s.texture_type==MTLTextureTypeCube?6:1)*s.mip_count||!s.length||s.length>FF_TEXTURE_BYTES_LIMIT-textureBytes)return nil;
  ff_texture_snapshot *t=&d->textures[i];t->id=i+1;t->format=s.format;t->texture_type=s.texture_type;t->width=s.width;t->height=s.height;t->mip_count=s.mip_count;t->array_length=s.array_length;t->has_swizzle=s.has_swizzle;t->length=s.length;t->plane_count=s.plane_count;
  for(unsigned j=0;j<4;j++){if(s.swizzle[j]>5)return nil;t->swizzle[j]=s.swizzle[j];}
  uint64_t cursor=0;
  for(size_t j=0;j<s.plane_count;j++){ffmd_graph_texture_plane q;if(!ffmd_view_row(&d->wire,5,planes+j,&q,sizeof(q))||q.mip!=j%s.mip_count||q.slice!=j/s.mip_count||q.offset!=cursor||q.row_bytes<(uint64_t)MAX(1,s.width>>q.mip)*ff_texture_pixel_size(s.format)||q.row_bytes>UINT64_MAX/MAX(1,s.height>>q.mip)||q.length!=q.row_bytes*MAX(1,s.height>>q.mip)||q.length>s.length-cursor)return nil;
   t->planes[j]=(ff_texture_plane){q.mip,q.slice,q.offset,q.row_bytes,q.length};cursor+=q.length;}
  if(cursor!=s.length)return nil;planes+=s.plane_count;textureBytes+=s.length;
  NSData *ref=blobs[[NSString stringWithFormat:@"journal-texture-%02zu.bin",i+1]],*bytes=blobs[[NSString stringWithFormat:@"cut-texture-%02zu.bin",i+1]];
  if(ref){if(ref.length!=8||bytes)return nil;}else {if(bytes.length!=s.length)return nil;t->bytes=bytes.bytes;}
 }
 if(planes!=d->wire.sections[5].count)return nil;
 for(size_t i=0;i<d->ns;i++){
  ffmd_graph_sampler s;if(!ffmd_view_row(&d->wire,6,i,&s,sizeof(s)))return nil;ff_sampler_snapshot *v=&d->samplers[i];v->id=i+1;
  memcpy(v->address,s.address,sizeof(v->address));v->min_filter=s.min_filter;v->mag_filter=s.mag_filter;v->mip_filter=s.mip_filter;v->compare=s.compare;v->border=s.border;v->max_anisotropy=s.max_anisotropy;v->normalized=s.normalized;v->lod_average=s.lod_average;memcpy(&v->lod_min,&s.lod_min_bits,4);memcpy(&v->lod_max,&s.lod_max_bits,4);
  if(v->min_filter>1||v->mag_filter>1||v->mip_filter>2||v->compare>7||v->border>2||!v->max_anisotropy||v->max_anisotropy>16||v->normalized>1||v->lod_average>1||v->address[0]>5||v->address[1]>5||v->address[2]>5||!isfinite(v->lod_min)||!isfinite(v->lod_max)||v->lod_min<0||v->lod_max<v->lod_min)return nil;
 }
 return d;
}
typedef struct {ff_vertex_binding v[FF_VERTEX_RESOURCE_LIMIT],c[2][FF_CONSTANT_RESOURCE_LIMIT],index;ff_argument_binding a[2][FF_SHADER_FIELD_LIMIT];} FFDPDrawScratch;
static BOOL ffdp_binding(FFDPDecoded *d,size_t n,ff_vertex_binding *b){
 ffmd_graph_binding r;if(!ffmd_view_row(&d->wire,2,n,&r,sizeof(r)))return NO;*b=(ff_vertex_binding){r.id,r.generation,r.offset,r.stride,r.length};
 if(!r.id)return !r.generation&&!r.offset&&!r.stride&&!r.length;
 return r.id<=d->nb&&r.generation==1&&r.offset<=d->buffers[r.id-1].length&&r.length<=d->buffers[r.id-1].length-r.offset;
}
static BOOL ffdp_draw(FFDPDecoded *d,size_t n,const ff_draw_layout *layout,FFSTPassDrawInfo *info,FFDPDrawScratch *scratch,ff_draw_bindings *out){
 ffmd_plan_draw p;ffmd_graph_draw r;
 if(!ffmd_view_row(&d->plan,0,n,&p,sizeof(p))||!ffmd_view_row(&d->wire,1,n,&r,sizeof(r))||p.primitive>4||!r.count||r.count>10000000||!r.instances||r.instances>1000000||r.count>10000000/r.instances||p.indexed>1||p.index_type>1||p.vertex_count>FF_VERTEX_RESOURCE_LIMIT||p.vertex_count!=__builtin_popcount(p.ia_slot_mask)||p.reserved)return NO;
 if(info)*info=(FFSTPassDrawInfo){.primitive=p.primitive,.ia_slot_mask=p.ia_slot_mask,.start=r.start,.count=r.count,.instances=r.instances,.base_instance=r.base_instance,.indexed=p.indexed,.index_type=p.index_type,.base_vertex=r.base_vertex,.index_count=r.index_count,.index_offset=r.index_offset};
 if(p.indexed){if(r.start||r.index_count!=r.count||r.index_binding==FFMD_NO_BINDING||r.index_offset%(p.index_type?4:2))return NO;}
 else if(r.index_binding!=FFMD_NO_BINDING||r.index_count||r.index_offset||r.base_vertex)return NO;
 if(!layout)return YES;if(!scratch||!out||layout->ia_slot_mask!=p.ia_slot_mask)return NO;memset(scratch,0,sizeof(*scratch));memset(out,0,sizeof(*out));
 size_t b=r.binding_first,a=r.argument_first;
 out->vertices=scratch->v;out->vertex_count=p.vertex_count;
 for(size_t j=0;j<p.vertex_count;j++)if(!ffdp_binding(d,b++,&scratch->v[j]))return NO;
 for(unsigned s=0;s<2;s++){
  if(p.constant_count[s]>FF_CONSTANT_RESOURCE_LIMIT||p.argument_count[s]>FF_SHADER_FIELD_LIMIT||p.constant_count[s]!=layout->constant_count[s]||p.argument_count[s]!=layout->arguments[s].field_count||layout->arguments[s].byte_length>FF_SHADER_TABLE_BYTES_LIMIT)return NO;
  out->constants[s]=scratch->c[s];out->constant_count[s]=p.constant_count[s];out->arguments[s]=scratch->a[s];out->argument_count[s]=p.argument_count[s];out->argument_bytes[s]=layout->arguments[s].byte_length;
  for(size_t j=0;j<p.constant_count[s];j++)if(!ffdp_binding(d,b++,&scratch->c[s][j]))return NO;
 }
 if(p.indexed){if(r.index_binding!=b||!ffdp_binding(d,b,&scratch->index)||!scratch->index.id||scratch->index.stride||scratch->index.offset%(p.index_type?4:2)||r.count>scratch->index.length/(p.index_type?4:2))return NO;ffmd_graph_snapshot owner;if(!ffmd_view_row(&d->wire,0,scratch->index.id-1,&owner,sizeof(owner))||owner.source_offset>UINT64_MAX-scratch->index.offset||r.index_offset!=owner.source_offset+scratch->index.offset)return NO;out->index=&scratch->index;}
 for(unsigned s=0;s<2;s++)for(size_t j=0;j<p.argument_count[s];j++){
  ffmd_plan_argument_slot slot;ffmd_graph_argument_value value;
  if(!ffmd_view_row(&d->plan,1,p.argument_slot_first[s]+j,&slot,sizeof(slot))||!ffmd_view_row(&d->wire,3,a++,&value,sizeof(value))||value.reserved||slot.offset!=layout->arguments[s].fields[j].offset||slot.kind!=layout->arguments[s].fields[j].kind||slot.offset%8||slot.offset>=layout->arguments[s].byte_length)return NO;
  ff_argument_binding *f=&scratch->a[s][j];f->offset=slot.offset;f->kind=slot.kind;f->value=value.value;
  if(slot.kind==FF_FIELD_BUFFER){if(value.value||!ffdp_binding(d,value.buffer_binding,&f->buffer))return NO;}
  else if(value.buffer_binding!=FFMD_NO_BINDING||slot.kind<FF_FIELD_TEXTURE||slot.kind>FF_FIELD_VALUE||(slot.kind==FF_FIELD_TEXTURE&&value.value>d->nt)||(slot.kind==FF_FIELD_SAMPLER&&value.value>d->ns))return NO;
 }
 return YES;
}
@interface FFDPTableArena : NSObject {
@public
 uint64_t slots[FFST_PASS_DRAW_LIMIT][5];
 uint64_t indexOffsets[FFST_PASS_DRAW_LIMIT];
}
@property(nonatomic,strong) id<MTLBuffer> arena;
@property(nonatomic,strong) NSArray *held,*indices;
@end
@implementation FFDPTableArena @end
static BOOL ffdp_address(FFDPDecoded *d,ff_vertex_binding b,const ff_native_buffer_override *overrides,size_t count,uint64_t *address,id<MTLBuffer> __strong *buffer,NSUInteger *offset){
 *address=0;if(!b.id)return !b.generation&&!b.offset&&!b.length&&!b.stride;
 if(b.id>d->nb||b.generation!=1||b.offset>d->buffers[b.id-1].length||b.length>d->buffers[b.id-1].length-b.offset)return NO;
 const ff_native_buffer_override *o=NULL;for(size_t i=0;i<count;i++)if(overrides[i].snapshot_id==b.id){o=&overrides[i];break;}
 if(!o||o->base_offset>o->buffer.length||b.offset>o->buffer.length-o->base_offset||b.length>o->buffer.length-o->base_offset-b.offset||!o->buffer.gpuAddress||o->base_offset+b.offset>UINT64_MAX-o->buffer.gpuAddress)return NO;
 *address=o->buffer.gpuAddress+o->base_offset+b.offset;if(buffer)*buffer=o->buffer;if(offset)*offset=o->base_offset+b.offset;return YES;
}
static FFDPTableArena *ffdp_tables(id<MTLDevice> device,FFDPDecoded *d,NSArray<FFSTFrameRenderDraw *> *draws,const ff_native_buffer_override *buffers,size_t nb,const ff_native_texture_override *textures,size_t nt,FFSTNativeSessionCache *cache){
 FFDPTableArena *r=[FFDPTableArena new];NSMutableData *arena=[NSMutableData data];NSMutableArray *held=[NSMutableArray array],*indices=[NSMutableArray array],*samplers=[NSMutableArray array];
 for(size_t i=0;i<nb;i++)[held addObject:buffers[i].buffer];for(size_t i=0;i<nt;i++)[held addObject:textures[i].texture];
 for(size_t i=0;i<d->ns;i++){ff_sampler_snapshot s=d->samplers[i];s.id=0;NSData *key=[NSData dataWithBytes:&s length:sizeof(s)];id<MTLSamplerState> sampler=[cache objectForKey:key];
  if(!sampler){MTLSamplerDescriptor *m=[MTLSamplerDescriptor new];m.sAddressMode=s.address[0];m.tAddressMode=s.address[1];m.rAddressMode=s.address[2];m.minFilter=s.min_filter;m.magFilter=s.mag_filter;m.mipFilter=s.mip_filter;m.compareFunction=s.compare;m.borderColor=s.border;m.maxAnisotropy=s.max_anisotropy;m.lodMinClamp=s.lod_min;m.lodMaxClamp=s.lod_max;m.normalizedCoordinates=s.normalized;m.lodAverage=s.lod_average;m.supportArgumentBuffers=YES;sampler=[device newSamplerStateWithDescriptor:m];if(!sampler||(cache&&![cache setObject:sampler forKey:key cost:1]))return nil;}
  [samplers addObject:sampler];[held addObject:sampler];}
 for(size_t i=0;i<draws.count;i++){
  FFDPDrawScratch scratch;ff_draw_bindings b;ff_draw_layout layout=draws[i].pipeline.layout;
  if(!ffdp_draw(d,i,&layout,NULL,&scratch,&b))return nil;
  for(unsigned j=0;j<5;j++)r->slots[i][j]=UINT64_MAX;
  uint8_t raw[FF_SHADER_TABLE_BYTES_LIMIT]={0};size_t n=b.vertex_count*16;
  for(size_t j=0;j<b.vertex_count;j++){uint64_t address;if(!ffdp_address(d,b.vertices[j],buffers,nb,&address,NULL,NULL))return nil;memcpy(raw+j*16,&address,8);memcpy(raw+j*16+8,&b.vertices[j].stride,4);memcpy(raw+j*16+12,&b.vertices[j].length,4);}
  if(n){r->slots[i][0]=arena.length;[arena appendBytes:raw length:n];}
  for(unsigned s=0;s<2;s++){
   memset(raw,0,sizeof(raw));n=b.constant_count[s]*8;
   for(size_t j=0;j<b.constant_count[s];j++){uint64_t address;if(!ffdp_address(d,b.constants[s][j],buffers,nb,&address,NULL,NULL))return nil;memcpy(raw+j*8,&address,8);}
   if(n){r->slots[i][1+s*2]=arena.length;[arena appendBytes:raw length:n];}
   memset(raw,0,sizeof(raw));n=b.argument_bytes[s];
   for(size_t j=0;j<b.argument_count[s];j++){ff_argument_binding f=b.arguments[s][j];uint64_t value=f.value;
    if(f.kind==FF_FIELD_BUFFER){if(!ffdp_address(d,f.buffer,buffers,nb,&value,NULL,NULL))return nil;}
    else if(f.kind==FF_FIELD_TEXTURE&&value){id<MTLTexture> texture=nil;for(size_t k=0;k<nt;k++)if(textures[k].snapshot_id==value)texture=textures[k].texture;if(!texture)return nil;value=texture.gpuResourceID._impl;}
    else if(f.kind==FF_FIELD_SAMPLER&&value){if(value>samplers.count)return nil;value=[samplers[value-1] gpuResourceID]._impl;}
    memcpy(raw+f.offset,&value,8);
   }
   if(n){r->slots[i][2+s*2]=arena.length;[arena appendBytes:raw length:n];}
  }
  id<MTLBuffer> index=nil;NSUInteger offset=0;uint64_t address;
  if(b.index){if(!ffdp_address(d,*b.index,buffers,nb,&address,&index,&offset))return nil;}
  [indices addObject:(id)index?:[NSNull null]];r->indexOffsets[i]=offset;
  if(arena.length>16u*1024u*1024u)return nil;
 }
 if(arena.length){r.arena=[device newBufferWithBytes:arena.bytes length:arena.length options:MTLResourceStorageModeShared];if(!r.arena)return nil;}
 r.held=held;r.indices=indices;return r;
}
static void ffdp_bind(FFDPTableArena *a,size_t draw,id<MTLRenderCommandEncoder> e){
 const uint64_t *s=a->slots[draw];if(s[0]!=UINT64_MAX)[e setVertexBuffer:a.arena offset:s[0] atIndex:16];
 if(s[1]!=UINT64_MAX)[e setVertexBuffer:a.arena offset:s[1] atIndex:29];if(s[2]!=UINT64_MAX)[e setVertexBuffer:a.arena offset:s[2] atIndex:30];
 if(s[3]!=UINT64_MAX)[e setFragmentBuffer:a.arena offset:s[3] atIndex:29];if(s[4]!=UINT64_MAX)[e setFragmentBuffer:a.arena offset:s[4] atIndex:30];
}
