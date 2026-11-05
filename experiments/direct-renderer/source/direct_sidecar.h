/* Private shadow encoder for already-validated producer references. */
#ifndef PRIVATE_DIRECT_SIDECAR_H
#define PRIVATE_DIRECT_SIDECAR_H
#include "metadata_wire_v1.h"
#include "native_value_validation.h"
#include <CommonCrypto/CommonDigest.h>
#define DS_BUCKETS 2048u
#define DS_MAX_RESOURCES 4096u
#define DS_MAX_SNAPSHOTS 1024u
#define DS_MAX_TEXTURES 128u
#define DS_MAX_ATTACHMENTS 4u
#define DS_MAX_COMMANDS 65536u
struct ds_capture {
    uint64_t identity[5];uint32_t count[5];
    void *body[5];
};
static void ds_free(struct ds_capture *d){
    if(!d)return;for(unsigned i=0;i<5;i++)free(d->body[i]);free(d);
}
static int ds_u32(id value,uint32_t *out){uint64_t n=0;if(!ffst_value_u64(value,UINT32_MAX,&n))return 0;*out=(uint32_t)n;return 1;}
static int ds_opt_u32(id value,uint32_t *out){if(!value){*out=0;return 1;}return ds_u32(value,out);}
static int ds_u64(id value,uint64_t *out){return ffst_value_u64(value,UINT64_MAX,out);}
static int ds_opt_u64(id value,uint64_t *out){if(!value){*out=0;return 1;}return ds_u64(value,out);}
static uint64_t ds_mix(uint64_t x){x^=x>>30;x*=UINT64_C(0xbf58476d1ce4e5b9);x^=x>>27;x*=UINT64_C(0x94d049bb133111eb);return x^(x>>31);}
/* Produce the same base rows as reference(); read the original typed producer
 * integers and the already-validated, effective Metal-view fields. */
static int ds_resource(const ffs_producer_resource *r,NSDictionary *metadata,uint64_t payload,ffmd_sidecar_resource *o){
    if([metadata isMemberOfClass:[FFSourceScalarReference class]])return [(FFSourceScalarReference *)metadata checkedResource:r payload:payload output:o];
    if(!r||![metadata isKindOfClass:[NSDictionary class]]||!o||(r->kind!=FFS_BUFFER&&r->kind!=FFS_TEXTURE)||
       !r->root||!r->view||!r->allocation_generation||!r->input_content_version||
       metadata.count!=(r->kind==FFS_BUFFER?12u:21u))return 0;
    /* Fail closed if any typed value disagrees with the actual dictionary used
     * by the legacy encoder. Effective view properties are validated below. */
#define DS_MATCH(key,expected) do{uint64_t n=0;if(!ds_u64(metadata[@key],&n)||n!=(uint64_t)(expected))return 0;}while(0)
    DS_MATCH("kind",r->kind);DS_MATCH("root",r->root);DS_MATCH("view",r->view);
    DS_MATCH("allocation_generation",r->allocation_generation);DS_MATCH("input_content_version",r->input_content_version);
    DS_MATCH("output_content_version",r->output_content_version);DS_MATCH("payload_id",payload);DS_MATCH("flags",r->flags);
    DS_MATCH("offset",r->offset);DS_MATCH("length",r->length);
#undef DS_MATCH
    *o=(ffmd_sidecar_resource){.kind=r->kind,.root=r->root,.view=r->view,.allocation_generation=r->allocation_generation,
        .input_content_version=r->input_content_version,.output_content_version=r->output_content_version,
        .offset=r->offset,.length=r->length,.flags=r->flags};
    if(r->kind==FFS_BUFFER){
        uint64_t origin=0,capacity=0;
        if(!ds_u64(metadata[@"buffer_base_offset"],&origin)||!ds_u64(metadata[@"buffer_length"],&capacity))return 0;
        o->buffer_base_offset=origin;o->buffer_length=capacity;
    }else{
#define DS_U32_FIELD(key,field) do{uint32_t n=0;if(!ds_u32(metadata[@key],&n))return 0;o->field=n;}while(0)
        DS_U32_FIELD("base_mip",base_mip);DS_U32_FIELD("base_slice",base_slice);
        DS_U32_FIELD("mip_count",mip_count);DS_U32_FIELD("slice_count",slice_count);
        DS_U32_FIELD("format",format);DS_U32_FIELD("type",type);
        DS_U32_FIELD("width",width);DS_U32_FIELD("height",height);
        DS_U32_FIELD("array_length",array_length);DS_U32_FIELD("sample_count",sample_count);
#undef DS_U32_FIELD
        NSArray *sw=metadata[@"swizzle"];if(![sw isKindOfClass:[NSArray class]]||sw.count!=4)return 0;
        for(unsigned j=0;j<4;j++){uint32_t n=0;if(!ds_u32(sw[j],&n))return 0;o->swizzle[j]=n;}
    }
    return 1;
}
/* The producer creates these rows from reference(match) and adds exactly one
 * local id. Verify that coupling without treating a hash or root as proof. */
static int ds_reference_matches(NSDictionary *base,NSDictionary *selected,size_t expected_id){
    if([base isMemberOfClass:[FFSourceScalarReference class]]&&[selected isMemberOfClass:[FFSourceScalarReference class]])return [(FFSourceScalarReference *)base matchesSnapshot:(id)selected identity:expected_id];
    if(![base isKindOfClass:[NSDictionary class]]||![selected isKindOfClass:[NSDictionary class]]||
       selected.count!=base.count+1||base[@"id"])return 0;
    uint64_t actual=0;if(!ds_u64(selected[@"id"],&actual)||actual!=expected_id)return 0;
    for(id key in base)if(![base[key] isEqual:selected[key]])return 0;
    return 1;
}
/* snap_matches/tex_matches are indexes into c->resources, computed by the
 * original filter. No producer pointer survives this synchronous call. */
static struct ds_capture *ds_prepare_impl(const ffs_producer_context *c,uint64_t payload,uint64_t cut,
    NSArray *resources,NSArray *snapshots,NSArray *textures,NSArray *attachments,NSArray *commands,
    const uint16_t *snap_matches,const uint16_t *tex_matches,struct ds_capture **partial){
    if(!c||![resources isKindOfClass:[NSArray class]]||![snapshots isKindOfClass:[NSArray class]]||
       ![textures isKindOfClass:[NSArray class]]||![attachments isKindOfClass:[NSArray class]]||
       ![commands isKindOfClass:[NSArray class]]||resources.count!=c->resource_count)return NULL;
    size_t snap_count=snapshots.count,tex_count=textures.count;
    if(
       resources.count>DS_MAX_RESOURCES||snap_count>DS_MAX_SNAPSHOTS||tex_count>DS_MAX_TEXTURES||
       attachments.count>DS_MAX_ATTACHMENTS||commands.count>DS_MAX_COMMANDS||commands.count!=c->command_count||
       (resources.count&&!c->resources.ptr)||(snap_count&&!snap_matches)||(tex_count&&!tex_matches))return NULL;
    const ffs_producer_resource *refs=c->resources.ptr;
    struct ds_capture *d=calloc(1,sizeof(*d));if(!d)return NULL;*partial=d;
    d->identity[0]=c->stream;d->identity[1]=c->frame;d->identity[2]=c->chunk;d->identity[3]=payload;d->identity[4]=cut;
    d->count[0]=(uint32_t)resources.count;d->count[1]=(uint32_t)snap_count;d->count[2]=(uint32_t)tex_count;
    d->count[3]=(uint32_t)attachments.count;d->count[4]=(uint32_t)commands.count;
    const size_t widths[5]={sizeof(ffmd_sidecar_resource),sizeof(ffmd_sidecar_index),sizeof(ffmd_sidecar_index),
        sizeof(ffmd_sidecar_attachment),sizeof(ffmd_sidecar_command)};
    size_t total=sizeof(ffmd_header)+5*sizeof(ffmd_section);
    for(unsigned i=0;i<5;i++){if(d->count[i]>SIZE_MAX/widths[i]||d->count[i]*widths[i]>FFMD_MAX_BYTES-total)goto fail;
        size_t n=d->count[i]*widths[i];total+=n;if(n&&!(d->body[i]=calloc(1,n)))goto fail;}
    ffmd_sidecar_resource *rows=d->body[0];ffmd_sidecar_index *snaps=d->body[1],*tex=d->body[2];
    ffmd_sidecar_attachment *att=d->body[3];ffmd_sidecar_command *cmd=d->body[4];
    uint16_t heads[DS_BUCKETS]={0},next[DS_MAX_RESOURCES]={0},first[DS_MAX_RESOURCES]={0};
    size_t comparisons=0;
    for(size_t i=0;i<resources.count;i++){
        NSDictionary *value=resources[i];if(!ds_resource(&refs[i],value,payload,&rows[i]))goto fail;
        size_t bucket=(size_t)ds_mix(refs[i].root)&(DS_BUCKETS-1);size_t earliest=i;
        /* The original encoder chooses first canonical dictionary equality,
         * even for separate handles; validate full objects, not only a hash. */
        for(uint16_t link=heads[bucket];link;link=next[link-1]){size_t j=link-1;if(++comparisons>16384)goto fail;
            if(refs[j].root==refs[i].root&&[resources[j] isEqual:value]&&j<earliest)earliest=j;}
        first[i]=(uint16_t)earliest;next[i]=heads[bucket];heads[bucket]=(uint16_t)(i+1);
    }
    for(size_t i=0;i<snap_count;i++){if(snap_matches[i]>=resources.count||
        !ds_reference_matches(resources[snap_matches[i]],snapshots[i],i+1))goto fail;
        snaps[i].resource_index=first[snap_matches[i]];}
    for(size_t i=0;i<tex_count;i++){if(tex_matches[i]>=resources.count||
        !ds_reference_matches(resources[tex_matches[i]],textures[i],i+1))goto fail;
        tex[i].resource_index=first[tex_matches[i]];}
    size_t a=0;
    for(size_t i=0;i<resources.count;i++)if(refs[i].role){
        if(a>=attachments.count)goto fail;NSDictionary *v=attachments[a];if(![v isKindOfClass:[NSDictionary class]])goto fail;
        NSMutableDictionary *canonical=[[v mutableCopy] autorelease];
        for(NSString *key in @[@"id",@"role",@"index",@"level",@"slice",@"depth_plane",@"shared_cut_id",@"shared_role",@"shared_index"])
            [canonical removeObjectForKey:key];
        BOOL same=[resources[i] isEqual:canonical];if(!same)goto fail;
        NSString *role=v[@"role"];uint8_t code=[role isEqual:@"color"]?FFMD_ATTACHMENT_COLOR:[role isEqual:@"color_resolve"]?FFMD_ATTACHMENT_COLOR_RESOLVE:
            [role isEqual:@"depth"]?FFMD_ATTACHMENT_DEPTH:[role isEqual:@"stencil"]?FFMD_ATTACHMENT_STENCIL:0;
        uint32_t index=0,level=0,slice=0,depth=0,shared_role=0,shared_index=0;uint64_t shared_cut=0;
        if(!code||!ds_u32(v[@"index"],&index)||index>UINT8_MAX||!ds_u32(v[@"level"],&level)||
           !ds_u32(v[@"slice"],&slice)||!ds_u32(v[@"depth_plane"],&depth)||
           !ds_opt_u64(v[@"shared_cut_id"],&shared_cut)||!ds_opt_u32(v[@"shared_role"],&shared_role)||shared_role>UINT8_MAX||
           !ds_opt_u32(v[@"shared_index"],&shared_index)||shared_index>UINT8_MAX)goto fail;
        att[a].resource_index=first[i];att[a].role=code;att[a].index=(uint8_t)index;
        att[a].level=level;att[a].slice=slice;att[a].depth_plane=depth;
        att[a].shared_cut_id=shared_cut;att[a].shared_role=(uint8_t)shared_role;att[a].shared_index=(uint8_t)shared_index;a++;
    }
    if(a!=attachments.count)goto fail;
    for(size_t i=0;i<commands.count;i++){uint32_t n=0;if(!ds_u32(commands[i],&n))goto fail;cmd[i].command_type=n;}
    return d;
fail:ds_free(d);*partial=NULL;return NULL;
}
/* Match legacy encoder's catch-and-fallback semantics, including partial C
 * allocations. Foundation temporaries belong to the caller's autorelease pool. */
static struct ds_capture *ds_prepare(const ffs_producer_context *c,uint64_t payload,uint64_t cut,
    NSArray *resources,NSArray *snapshots,NSArray *textures,NSArray *attachments,NSArray *commands,
    const uint16_t *snap_matches,const uint16_t *tex_matches){
    struct ds_capture *partial=NULL;
    @try{return ds_prepare_impl(c,payload,cut,resources,snapshots,textures,attachments,commands,snap_matches,tex_matches,&partial);}
    @catch(NSException *error){(void)error;ds_free(partial);return NULL;}
}
/* Equivalent to metadata_wire_encode.m's private emit(FFMD_SIDECAR,...). */
static NSData *ds_finish_impl(const struct ds_capture *d,NSData *plan){
    if(!d||![plan isKindOfClass:[NSData class]]||!plan.length||plan.length>UINT32_MAX)return nil;
    const uint16_t types[5]={FFMD_SIDECAR_RESOURCE,FFMD_SIDECAR_SNAPSHOT_INDEX,FFMD_SIDECAR_TEXTURE_INDEX,
        FFMD_SIDECAR_ATTACHMENT,FFMD_SIDECAR_COMMAND_TYPE};
    const uint32_t widths[5]={sizeof(ffmd_sidecar_resource),sizeof(ffmd_sidecar_index),sizeof(ffmd_sidecar_index),
        sizeof(ffmd_sidecar_attachment),sizeof(ffmd_sidecar_command)};
    uint64_t total=sizeof(ffmd_header)+5*sizeof(ffmd_section);
    for(unsigned i=0;i<5;i++){uint64_t n=(uint64_t)d->count[i]*widths[i];if(n>FFMD_MAX_BYTES-total)return nil;total+=n;}
    ffmd_header h={.magic=FFMD_MAGIC,.version=FFMD_VERSION,.kind=FFMD_SIDECAR,.total_bytes=(uint32_t)total,
        .section_count=5,.flags=FFMD_COMPLETE_PASS,.stream=d->identity[0],.frame=d->identity[1],.chunk=d->identity[2],
        .payload_id=d->identity[3],.cut_id=d->identity[4]};
    CC_SHA256(plan.bytes,(CC_LONG)plan.length,h.plan_sha256);
    NSMutableData *wire=[NSMutableData dataWithLength:(NSUInteger)total];if(!wire)return nil;
    unsigned char *bytes=wire.mutableBytes;memcpy(bytes,&h,sizeof(h));uint32_t offset=(uint32_t)(sizeof(h)+5*sizeof(ffmd_section));
    for(unsigned i=0;i<5;i++){
        uint32_t n=d->count[i]*widths[i];ffmd_section s={.type=types[i],.version=1,.stride=widths[i],.count=d->count[i],.offset=offset,.bytes=n};
        memcpy(bytes+sizeof(h)+i*sizeof(s),&s,sizeof(s));if(n)memcpy(bytes+offset,d->body[i],n);offset+=n;
    }
    return [[wire copy] autorelease];
}
static NSData *ds_finish(const struct ds_capture *d,NSData *plan){
    @try{return ds_finish_impl(d,plan);}@catch(NSException *error){(void)error;return nil;}
}
#endif
