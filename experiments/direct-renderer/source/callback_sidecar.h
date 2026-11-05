/* Private callback-time direct sidecar. MRC; callers own the exact-sized lease. */
#ifndef PRIVATE_CALLBACK_SIDECAR_H
#define PRIVATE_CALLBACK_SIDECAR_H
#include "direct_sidecar.h"

typedef struct {
    ffs_producer_context context;
    uint64_t payload,cut;
    size_t size,snapshot_count,texture_count;
    uint16_t *snapshots,*textures;
} cb_sidecar_lease;

static size_t cb_lease_size(size_t resources,size_t snapshots,size_t textures){
    if(resources>DS_MAX_RESOURCES||snapshots>DS_MAX_SNAPSHOTS||textures>DS_MAX_TEXTURES)return 0;
    if(resources>(SIZE_MAX-sizeof(cb_sidecar_lease))/sizeof(ffs_producer_resource))return 0;
    size_t n=sizeof(cb_sidecar_lease)+resources*sizeof(ffs_producer_resource);
    if(snapshots>(SIZE_MAX-n)/sizeof(uint16_t))return 0;n+=snapshots*sizeof(uint16_t);
    if(textures>(SIZE_MAX-n)/sizeof(uint16_t))return 0;return n+textures*sizeof(uint16_t);
}
/* Copy only the scalar fields needed by ds_prepare. The original handles and
 * all borrowed pointers are deliberately absent after this synchronous call. */
static int cb_lease_init(cb_sidecar_lease *lease,size_t size,const ffs_producer_context *c,
    uint64_t payload,uint64_t cut,const uint16_t *snaps,size_t ns,const uint16_t *textures,size_t nt){
    if(!lease||!c||!payload||!cut)return 0;
    size_t expected=cb_lease_size(c->resource_count,ns,nt);
    if(!expected||size!=expected||(c->resource_count&&!c->resources.ptr)||(ns&&!snaps)||
       (nt&&!textures)||c->command_count>DS_MAX_COMMANDS)return 0;
    memset(lease,0,size);lease->size=size;lease->payload=payload;lease->cut=cut;
    lease->snapshot_count=ns;lease->texture_count=nt;
    ffs_producer_context *out=&lease->context;
    out->stream=c->stream;out->frame=c->frame;out->chunk=c->chunk;
    out->encoder=c->encoder;out->category=c->category;out->command_count=c->command_count;out->resource_count=c->resource_count;
    ffs_producer_resource *refs=(ffs_producer_resource *)(lease+1);
    const ffs_producer_resource *source=c->resources.ptr;
    for(size_t i=0;i<c->resource_count;i++){refs[i]=source[i];refs[i].handle=0;}
    out->resources.ptr=refs;
    lease->snapshots=(uint16_t *)(refs+c->resource_count);
    lease->textures=lease->snapshots+ns;
    if(ns)memcpy(lease->snapshots,snaps,ns*sizeof(uint16_t));
    if(nt)memcpy(lease->textures,textures,nt*sizeof(uint16_t));
    return 1;
}
/* Evaluate the same actual bindings values the legacy encoder would read in
 * this callback. A mismatch or exceptional value must use the legacy path. */
static NSData *cb_encode(const cb_sidecar_lease *lease,NSDictionary *bindings,uint64_t cut,NSData *plan){
    struct ds_capture *capture=NULL;NSData *wire=nil;
    @try {
        if(!lease||![bindings isKindOfClass:[NSDictionary class]]||cut!=lease->cut||
           ![bindings[@"format"] isEqual:@"bedrock-native-frame-pass"]||![bindings[@"version"] isEqual:@1])return nil;
        uint64_t identity=0;NSArray *keys=@[@"stream",@"frame",@"chunk",@"payload_id"];
        const uint64_t expected[]={lease->context.stream,lease->context.frame,lease->context.chunk,lease->payload};
        for(unsigned i=0;i<4;i++)if(!ds_u64(bindings[keys[i]],&identity)||identity!=expected[i])return nil;
        NSArray *snaps=bindings[@"snapshots"],*textures=bindings[@"textures"];
        /* Legacy chooses each output table by NSArray pointer identity. It has
         * different semantics if these objects alias, even when both are empty. */
        if(![snaps isKindOfClass:[NSArray class]]||![textures isKindOfClass:[NSArray class]]||
           snaps==textures||snaps.count!=lease->snapshot_count||textures.count!=lease->texture_count)return nil;
        capture=ds_prepare(&lease->context,lease->payload,cut,bindings[@"resources"],snaps,textures,
            bindings[@"attachments"],bindings[@"command_types"],lease->snapshots,lease->textures);
        if(capture)wire=ds_finish(capture,plan);
        ds_free(capture);return wire;
    } @catch(NSException *error) {(void)error;ds_free(capture);return nil;}
}
#endif
