/* CPU-owned initialization and ordered copy history. Never reads GPU textures. */
#include "live_startup_wire.h"
static pthread_mutex_t live_history_lock=PTHREAD_MUTEX_INITIALIZER;
static NSMutableDictionary *live_history;
static uint64_t live_history_bytes,live_history_updates,live_history_misses;
#define LIVE_HISTORY_LIMIT (256ull*1024*1024)
static NSString *history_key(uint64_t kind,uint64_t root,uint64_t gen){return [NSString stringWithFormat:@"%llu:%llu:%llu",kind,root,gen];}
static NSMutableDictionary *history_get(uint64_t kind,uint64_t root,uint64_t gen,BOOL create){
 if(!live_history)live_history=[[NSMutableDictionary alloc]init];NSString*k=history_key(kind,root,gen);NSMutableDictionary*r=live_history[k];
 if(!r&&create&&live_history.count<32768){r=[NSMutableDictionary dictionaryWithDictionary:@{@"kind":@(kind),@"root":@(root),@"generation":@(gen),@"planes":[NSMutableDictionary dictionary]}];live_history[k]=r;}return r;
}
static BOOL history_grow(NSMutableDictionary*r,NSUInteger length){NSMutableData*d=r[@"data"];NSUInteger prior=d.length;if(prior>=length)return YES;
 if(length>32u*1024u*1024u||length-prior>LIVE_HISTORY_LIMIT-live_history_bytes)return NO;
 if(!d){d=[NSMutableData dataWithLength:length];r[@"data"]=d;r[@"defined"]=[NSMutableIndexSet indexSet];}else[d setLength:length];live_history_bytes+=length-prior;return d!=nil;
}
void fullframe_live_buffer_write(uint64_t root,uint64_t gen,uint64_t offset,const void*bytes,size_t length){@autoreleasepool{
 if(!live_enabled()||!root||!gen||!bytes||!length||offset>32u*1024u*1024u||length>32u*1024u*1024u-offset)return;
 pthread_mutex_lock(&live_history_lock);NSMutableDictionary*r=history_get(FFS_BUFFER,root,gen,YES);if(r&&history_grow(r,offset+length)){
  memcpy((uint8_t*)[r[@"data"]mutableBytes]+offset,bytes,length);[r[@"defined"]addIndexesInRange:NSMakeRange(offset,length)];live_history_updates++;
 }pthread_mutex_unlock(&live_history_lock);
}}
void fullframe_live_history_retire(uint64_t kind,uint64_t root,uint64_t generation){@autoreleasepool{
 if(!live_enabled())return;pthread_mutex_lock(&live_history_lock);
 NSArray*keys=generation?@[history_key(kind,root,generation)]:[[live_history.allKeys copy]autorelease];
 for(NSString*k in keys){NSDictionary*r=live_history[k];if(!generation&&([r[@"kind"]unsignedLongLongValue]!=kind||[r[@"root"]unsignedLongLongValue]!=root))continue;
  live_history_bytes-=[r[@"data"]length];for(NSDictionary*p in [r[@"planes"]allValues])live_history_bytes-=[p[@"data"]length];[live_history removeObjectForKey:k];[live_created removeObjectForKey:k];}
 pthread_mutex_unlock(&live_history_lock);
}}
static NSData *history_buffer(const ffs_producer_resource*r,uint64_t offset,uint64_t length){
 NSMutableDictionary*known=history_get(FFS_BUFFER,r->root,r->allocation_generation,NO);NSData*d=known[@"data"];
 if(d&&offset<=d.length&&length<=d.length-offset&&[known[@"defined"]containsIndexesInRange:NSMakeRange(offset,length)])return [NSData dataWithBytes:(const uint8_t*)d.bytes+offset length:length];
 if(r->root&UINT64_C(0x8000000000000000)){id<MTLBuffer>b=(id<MTLBuffer>)r->handle;if(b.contents&&offset<=b.length&&length<=b.length-offset)return[NSData dataWithBytes:(uint8_t*)b.contents+offset length:length];return nil;}
 size_t n=0;void*owned=fullframe_direct_journal_copy(r->root,r->allocation_generation,offset,r->handle,length,&n);if(owned){ffjp_record h;memcpy(&h,owned,sizeof(h));NSData*out=h.flags==FFJP_UPDATE?[NSData dataWithBytes:(const uint8_t*)owned+sizeof(h) length:h.bytes]:nil;free(owned);return out;}
 if(r->root&UINT64_C(0x8000000000000000)){id<MTLBuffer>b=(id<MTLBuffer>)r->handle;if(b.contents&&offset<=b.length&&length<=b.length-offset)return[NSData dataWithBytes:(uint8_t*)b.contents+offset length:length];}
 return nil;
}
static NSUInteger history_bpp(NSUInteger format){return ff_texture_pixel_size((uint32_t)format);}
static void history_root_texture(id<MTLTexture> texture,id<MTLTexture>*root,NSUInteger*mip,NSUInteger*slice){
 *mip=*slice=0;while(texture.parentTexture){*mip+=texture.parentRelativeLevel;*slice+=texture.parentRelativeSlice;texture=texture.parentTexture;}*root=texture;
}
static NSMutableDictionary *history_plane(uint64_t root,uint64_t gen,NSUInteger mip,NSUInteger slice,NSUInteger width,NSUInteger height,NSUInteger row,BOOL create){
 NSMutableDictionary*r=history_get(FFS_TEXTURE,root,gen,create),*planes=r[@"planes"];NSString*k=[NSString stringWithFormat:@"%lu:%lu",(unsigned long)mip,(unsigned long)slice];NSMutableDictionary*p=planes[k];
 if(!p&&create&&width&&height&&row&&row<=32u*1024u*1024u/height){p=[NSMutableDictionary dictionaryWithDictionary:@{@"level":@(mip),@"slice":@(slice),@"width":@(width),@"height":@(height),@"row":@(row)}];if(!history_grow(p,row*height))return nil;planes[k]=p;}
 return p;
}
uint32_t fullframe_live_initial_write(uint64_t root,uint64_t gen,uint64_t offset,const void*bytes,uint64_t length,uint64_t handle){@autoreleasepool{
 (void)offset;if(!live_enabled()||!root||!gen||!bytes||length<sizeof(ffli_header))return 0;ffli_header h;memcpy(&h,bytes,sizeof(h));if(h.magic!=FFLI_MAGIC||h.length!=length-sizeof(h)||h.depth!=1||!h.width||!h.height||h.flags>2)return 0;
 if(h.flags==2){if(h.length||h.row||!h.image||(h.image&~6u))return 0;pthread_mutex_lock(&live_history_lock);NSMutableDictionary*r=history_get(FFS_TEXTURE,root,gen,YES);NSString*k=[NSString stringWithFormat:@"%u:%u",h.level,h.slice];r[@"planes"][k]=@{@"level":@(h.level),@"slice":@(h.slice),@"width":@(h.width),@"height":@(h.height),@"clear":@(h.image)};r[@"last_writer"]=@"initializer-clear";pthread_mutex_unlock(&live_history_lock);return 1;}
 id<MTLTexture>texture=(id<MTLTexture>)handle;NSUInteger bpp=history_bpp(texture.pixelFormat);if(!bpp||h.row<h.width*bpp||h.length!=(uint64_t)h.row*h.height)return 0;
 pthread_mutex_lock(&live_history_lock);NSMutableDictionary*p=history_plane(root,gen,h.level,h.slice,h.width,h.height,h.row,YES);int ok=p!=nil;
 if(ok){history_get(FFS_TEXTURE,root,gen,YES)[@"last_writer"]=@"initializer";memcpy([p[@"data"]mutableBytes],(const uint8_t*)bytes+sizeof(h),h.length);[p[@"defined"]addIndexesInRange:NSMakeRange(0,h.length)];live_history_updates++;}
 pthread_mutex_unlock(&live_history_lock);return ok;
}}
static void history_copy_buffer(const ffs_producer_resource*src,uint64_t so,const ffs_producer_resource*dst,uint64_t d,uint64_t n){
 NSData*bytes=history_buffer(src,so,n);NSMutableDictionary*r=history_get(FFS_BUFFER,dst->root,dst->allocation_generation,YES);if(!r||!history_grow(r,d+n))return;
 [r[@"defined"]removeIndexesInRange:NSMakeRange(d,n)];if(bytes){memcpy((uint8_t*)[r[@"data"]mutableBytes]+d,bytes.bytes,n);[r[@"defined"]addIndexesInRange:NSMakeRange(d,n)];live_history_updates++;}else live_history_misses++;
}
static uint64_t live_warm_prepare(struct WMTRenderPassInfo*info,const ffs_producer_context*c){@autoreleasepool{
 pthread_mutex_lock(&live_history_lock);const ffs_producer_resource*rs=c->resources.ptr;
 if(c->category==FFS_BLIT){
  for(const struct wmtcmd_base*cmd=c->commands.ptr;cmd;cmd=cmd->next.ptr){
   if(cmd->type==WMTBlitCommandCopyFromBufferToBuffer){const struct wmtcmd_blit_copy_from_buffer_to_buffer*v=(const void*)cmd;const ffs_producer_resource*s=live_buffer_handle(c,v->src,v->src_offset,v->copy_length,FFS_READ),*d=live_buffer_handle(c,v->dst,v->dst_offset,v->copy_length,FFS_WRITE);if(s&&d)history_copy_buffer(s,v->src_offset,d,v->dst_offset,v->copy_length);}
   else if(cmd->type==WMTBlitCommandCopyFromBufferToTexture){const struct wmtcmd_blit_copy_from_buffer_to_texture*v=(const void*)cmd;const ffs_producer_resource*s=live_buffer_handle(c,v->src,v->src_offset,(uint64_t)v->bytes_per_row*v->size.height*v->size.depth,FFS_READ),*d=live_handle(c,v->dst,FFS_TEXTURE);if(!s||!d)continue;id<MTLTexture>texture=(id<MTLTexture>)d->handle,root;NSUInteger mip,slice;history_root_texture(texture,&root,&mip,&slice);mip+=v->level;slice+=v->slice;NSUInteger bpp=history_bpp(root.pixelFormat),width=MAX((NSUInteger)1,root.width>>mip),height=MAX((NSUInteger)1,root.height>>mip);if(!bpp||v->size.depth!=1||v->origin.x>width||v->size.width>width-v->origin.x||v->origin.y>height||v->size.height>height-v->origin.y)continue;
    NSMutableDictionary*p=history_plane(d->root,d->allocation_generation,mip,slice,width,height,width*bpp,YES);if(!p)continue;for(NSUInteger y=0;y<v->size.height;y++){NSUInteger off=(v->origin.y+y)*width*bpp+v->origin.x*bpp,n=v->size.width*bpp;NSData*row=history_buffer(s,v->src_offset+y*v->bytes_per_row,n);[p[@"defined"]removeIndexesInRange:NSMakeRange(off,n)];if(row){memcpy((uint8_t*)[p[@"data"]mutableBytes]+off,row.bytes,n);[p[@"defined"]addIndexesInRange:NSMakeRange(off,n)];}}
   }else if(cmd->type==WMTBlitCommandCopyFromTextureToTexture){const struct wmtcmd_blit_copy_from_texture_to_texture*v=(const void*)cmd;const ffs_producer_resource*s=live_handle(c,v->src,FFS_TEXTURE),*d=live_handle(c,v->dst,FFS_TEXTURE);if(!s||!d)continue;id<MTLTexture>st,dt;NSUInteger sm,ss,dm,ds;history_root_texture((id<MTLTexture>)s->handle,&st,&sm,&ss);history_root_texture((id<MTLTexture>)d->handle,&dt,&dm,&ds);sm+=v->src_level;ss+=v->src_slice;dm+=v->dst_level;ds+=v->dst_slice;NSUInteger bpp=history_bpp(dt.pixelFormat),sw=MAX((NSUInteger)1,st.width>>sm),dw=MAX((NSUInteger)1,dt.width>>dm),dh=MAX((NSUInteger)1,dt.height>>dm);if(!bpp||dt.pixelFormat!=st.pixelFormat||v->src_size.depth!=1)continue;
    NSMutableDictionary*sp=history_plane(s->root,s->allocation_generation,sm,ss,0,0,0,NO),*dp=history_plane(d->root,d->allocation_generation,dm,ds,dw,dh,dw*bpp,YES);if(!dp)continue;for(NSUInteger y=0;y<v->src_size.height;y++){NSUInteger from=(v->src_origin.y+y)*sw*bpp+v->src_origin.x*bpp,to=(v->dst_origin.y+y)*dw*bpp+v->dst_origin.x*bpp,n=v->src_size.width*bpp;if(to>[dp[@"data"]length]||n>[dp[@"data"]length]-to)break;[dp[@"defined"]removeIndexesInRange:NSMakeRange(to,n)];if(from<=[sp[@"data"]length]&&n<=[sp[@"data"]length]-from&&[sp[@"defined"]containsIndexesInRange:NSMakeRange(from,n)]){memmove((uint8_t*)[dp[@"data"]mutableBytes]+to,(uint8_t*)[sp[@"data"]mutableBytes]+from,n);[dp[@"defined"]addIndexesInRange:NSMakeRange(to,n)];}}
   }else if(cmd->type==WMTBlitCommandCopyFromTextureToBuffer){const struct wmtcmd_blit_copy_from_texture_to_buffer*v=(const void*)cmd;const ffs_producer_resource*d=live_buffer_handle(c,v->dst,v->offset,(uint64_t)v->bytes_per_row*v->size.height*v->size.depth,FFS_WRITE);if(d){NSMutableDictionary*r=history_get(FFS_BUFFER,d->root,d->allocation_generation,NO);[r[@"defined"]removeIndexesInRange:NSMakeRange(v->offset,(NSUInteger)v->bytes_per_row*v->size.height)];}}
  }
 }else if(c->category==FFS_RENDER||c->category==FFS_COMPUTE||c->category==FFS_RESOLVE){
  /* Pre-activation GPU shader writes have no CPU value witness. Never import
   * the old initialization bytes as if they were this later result. */
  for(size_t i=0;i<c->resource_count;i++)if(rs[i].flags&FFS_WRITE){NSMutableDictionary*r=history_get(rs[i].kind,rs[i].root,rs[i].allocation_generation,NO);r[@"last_writer"]=@(c->category);if(rs[i].kind==FFS_BUFFER)[r[@"defined"]removeAllIndexes];else for(NSMutableDictionary*p in [r[@"planes"]allValues]){[p[@"defined"]removeAllIndexes];if(p[@"clear"]){NSMutableDictionary*replacement=[p mutableCopy];[replacement removeObjectForKey:@"clear"];NSString*k=[NSString stringWithFormat:@"%@:%@",p[@"level"],p[@"slice"]];r[@"planes"][k]=replacement;[replacement release];}}}
 }else if(c->category==FFS_CLEAR){(void)info;for(size_t i=0;i<c->resource_count;i++){NSMutableDictionary*r=history_get(rs[i].kind,rs[i].root,rs[i].allocation_generation,NO);for(NSMutableDictionary*p in [r[@"planes"]allValues]){[p[@"defined"]removeAllIndexes];if(p[@"clear"]){NSMutableDictionary*replacement=[p mutableCopy];[replacement removeObjectForKey:@"clear"];NSString*k=[NSString stringWithFormat:@"%@:%@",p[@"level"],p[@"slice"]];r[@"planes"][k]=replacement;[replacement release];}}}}
 pthread_mutex_unlock(&live_history_lock);return 1;
}}
/* Copy only known ranges on a resource's first native use. Later GPU writes
 * belong to the native persistent allocation, not this startup journal. */
static BOOL live_seed_resource(const ffs_producer_resource*r,NSMutableArray*events,NSMutableDictionary*blobs){
 pthread_mutex_lock(&live_history_lock);NSMutableDictionary*known=history_get(r->kind,r->root,r->allocation_generation,NO);BOOL seeded=NO;
 if(r->kind==FFS_BUFFER){NSData*d=known[@"data"];NSIndexSet*defined=known[@"defined"];
  [defined enumerateRangesUsingBlock:^(NSRange range,BOOL*stop){(void)stop;NSString*name=[NSString stringWithFormat:@"live-upload-%04lu.bin",(unsigned long)blobs.count];blobs[name]=[NSData dataWithBytes:(const uint8_t*)d.bytes+range.location length:range.length];[events addObject:@{@"op":@"write_buffer",@"ref":live_ref(r,range.location,range.length),@"blob":name,@"epoch":@1}];}];seeded=defined.count>0;
 }else{for(NSDictionary*p in [known[@"planes"]allValues]){if(p[@"clear"]){[events addObject:@{@"op":@"initialize_clear_texture",@"ref":live_ref(r,0,0),@"level":p[@"level"],@"slice":p[@"slice"],@"aspects":p[@"clear"]}];seeded=YES;continue;}NSData*d=p[@"data"];if(!d.length||![p[@"defined"]containsIndexesInRange:NSMakeRange(0,d.length)])continue;NSString*name=[NSString stringWithFormat:@"live-upload-%04lu.bin",(unsigned long)blobs.count];blobs[name]=[NSData dataWithBytes:d.bytes length:d.length];[events addObject:@{@"op":@"initialize_texture",@"ref":live_ref(r,0,0),@"blob":name,@"row":p[@"row"],@"level":p[@"level"],@"slice":p[@"slice"],@"width":p[@"width"],@"height":p[@"height"]}];seeded=YES;}}
 if(r->kind==FFS_TEXTURE){id<MTLTexture>t=(id<MTLTexture>)r->handle;while(t.parentTexture)t=t.parentTexture;NSUInteger complete=0,partial=0;for(NSDictionary*p in [known[@"planes"]allValues]){if([p[@"defined"]containsIndexesInRange:NSMakeRange(0,[p[@"data"]length])])complete++;else partial++;}fprintf(stderr,"[live-command-seed] root=%llu generation=%llu format=%lu width=%lu height=%lu mips=%lu slices=%lu complete=%lu partial=%lu known=%d last=%s history_bytes=%llu\n",r->root,r->allocation_generation,(unsigned long)t.pixelFormat,(unsigned long)t.width,(unsigned long)t.height,(unsigned long)t.mipmapLevelCount,(unsigned long)t.arrayLength,(unsigned long)complete,(unsigned long)partial,known!=nil,[[known[@"last_writer"]description]UTF8String]?:"none",live_history_bytes);}
 if(seeded)known[@"published"]=@YES;
 pthread_mutex_unlock(&live_history_lock);return seeded;
}
static BOOL live_seeded_buffer(const ffs_producer_resource*r){pthread_mutex_lock(&live_history_lock);BOOL result=[history_get(FFS_BUFFER,r->root,r->allocation_generation,NO)[@"published"]boolValue];pthread_mutex_unlock(&live_history_lock);return result;}
