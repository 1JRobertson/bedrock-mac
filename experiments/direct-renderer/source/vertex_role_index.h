#ifndef BEDROCK_VERTEX_ROLE_INDEX_H
#define BEDROCK_VERTEX_ROLE_INDEX_H
/* One immutable pass census. No content, generation or GPU authority is cached. */
#include <stdint.h>
#include <string.h>
#define FF_VERTEX_ROLE_BUCKETS 2048u
_Static_assert(FF_DRAW_RESOURCE_LIMIT<=1024,"bounded vertex-role census");
typedef struct {
 uint16_t buckets[FF_VERTEX_ROLE_BUCKETS];
 uint16_t roots[FF_DRAW_RESOURCE_LIMIT];
 uint8_t used[FF_DRAW_RESOURCE_LIMIT],forbidden[FF_DRAW_RESOURCE_LIMIT];
} ff_vertex_role_index;
static inline uint32_t ff_vertex_role_hash(uint64_t root,uint64_t generation){
 uint64_t x=root^(generation+UINT64_C(0x9e3779b97f4a7c15)+(root<<6)+(root>>2));
 x^=x>>30;x*=UINT64_C(0xbf58476d1ce4e5b9);x^=x>>27;x*=UINT64_C(0x94d049bb133111eb);x^=x>>31;
 return (uint32_t)x&(FF_VERTEX_ROLE_BUCKETS-1);
}
static inline int ff_vertex_role_forbid(ff_vertex_role_index *out,size_t count,uint64_t id){
 if(!id)return 1;if(id>count)return 0;
 out->forbidden[out->roots[id-1]]=1;return 1;
}
static inline int ff_vertex_roles_build(const struct ff_draw_cut *cut,ff_vertex_role_index *out){
 memset(out,0,sizeof(*out));
 if(!cut||!cut->draws||!cut->draw_count||cut->draw_count>FF_DRAW_PASS_LIMIT||cut->snapshot_count>FF_DRAW_RESOURCE_LIMIT)return 0;
 for(size_t i=0;i<cut->snapshot_count;i++){
  uint64_t root=cut->source_incarnation[i],generation=cut->source_generation[i];
  uint32_t bucket=ff_vertex_role_hash(root,generation);
  for(uint32_t probe=0;;probe++,bucket=(bucket+1)&(FF_VERTEX_ROLE_BUCKETS-1)){
   if(probe==FF_VERTEX_ROLE_BUCKETS)return 0;
   uint16_t entry=out->buckets[bucket];
   if(!entry){out->buckets[bucket]=(uint16_t)(i+1);out->roots[i]=(uint16_t)i;break;}
   size_t j=entry-1;
   if(cut->source_incarnation[j]==root&&cut->source_generation[j]==generation){out->roots[i]=(uint16_t)j;break;}
  }
 }
 for(size_t n=0;n<cut->draw_count;n++){
  const ff_draw_plan *d=&cut->draws[n];
  if(d->binding_count>FF_VERTEX_RESOURCE_LIMIT)return 0;
  for(size_t j=0;j<d->binding_count;j++){
   uint64_t id=d->bindings[j].id;
   if(id&&id<=cut->snapshot_count&&d->bindings[j].length)out->used[id-1]=1;
  }
  if(!ff_vertex_role_forbid(out,cut->snapshot_count,d->index_binding.id))return 0;
  for(unsigned stage=0;stage<2;stage++){
   if(d->layout.constant_count[stage]>FF_CONSTANT_RESOURCE_LIMIT||d->layout.arguments[stage].field_count>FF_SHADER_FIELD_LIMIT)return 0;
   for(size_t j=0;j<d->layout.constant_count[stage];j++)
    if(!ff_vertex_role_forbid(out,cut->snapshot_count,d->constants[stage][j].id))return 0;
   for(size_t j=0;j<d->layout.arguments[stage].field_count;j++)
    if(d->arguments[stage][j].kind==FF_FIELD_BUFFER&&!ff_vertex_role_forbid(out,cut->snapshot_count,d->arguments[stage][j].buffer.id))return 0;
  }
 }
 return 1;
}
static inline int ff_vertex_role_only(const ff_vertex_role_index *roles,size_t count,size_t index){
 return index<count&&roles->used[index]&&!roles->forbidden[roles->roots[index]];
}
#endif
