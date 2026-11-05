#import "draw_resource_cut.h"
#import "metadata_wire_encode.h"
#import "native_value_validation.h"
#include "metadata_wire_v1.h"
#include <CommonCrypto/CommonDigest.h>
#include <math.h>
#include <string.h>

#if !__has_feature(objc_arc)
#error metadata_wire_encode.m requires ARC
#endif
#if __BYTE_ORDER__ != __ORDER_LITTLE_ENDIAN__
#error FFMD1 requires explicit little-endian conversion on this architecture
#endif

static uint64_t number(id value){uint64_t result=0;
    if(!ffst_value_u64(value,UINT64_MAX,&result))@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"FFMD1 integer" userInfo:nil];
    return result;}
static uint64_t optional_number(id value){return value?number(value):0;}
static uint32_t u32(id value){uint64_t result=number(value);
    if(result>UINT32_MAX)@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"FFMD1 u32" userInfo:nil];
    return (uint32_t)result;}
static uint32_t optional_u32(id value){return value?u32(value):0;}
static uint8_t u8(id value){uint32_t result=u32(value);
    if(result>UINT8_MAX)@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"FFMD1 u8" userInfo:nil];
    return (uint8_t)result;}
static uint8_t optional_u8(id value){return value?u8(value):0;}
static void add(NSMutableData *data,const void *row,size_t length) {[data appendBytes:row length:length];}
static NSData *emit(uint16_t kind,const uint64_t identity[5],const uint8_t digest[32],
    const uint16_t *types,const uint32_t *strides,NSArray<NSData *> *bodies){
    NSUInteger n=bodies.count;if(!n||n>FFMD_MAX_SECTIONS)return nil;
    uint64_t length=sizeof(ffmd_header)+n*sizeof(ffmd_section);
    for(NSUInteger i=0;i<n;i++){
        if(!strides[i]||bodies[i].length%strides[i]||bodies[i].length>UINT32_MAX||
           bodies[i].length/strides[i]>UINT32_MAX)return nil;
        length+=bodies[i].length;
    }
    if(length>FFMD_MAX_BYTES)return nil;
    ffmd_header h={.magic=FFMD_MAGIC,.version=FFMD_VERSION,.kind=kind,
        .total_bytes=(uint32_t)length,.section_count=(uint32_t)n,
        .flags=kind==FFMD_PLAN?0:FFMD_COMPLETE_PASS};
    if(identity){h.stream=identity[0];h.frame=identity[1];h.chunk=identity[2];
        h.payload_id=identity[3];h.cut_id=identity[4];}
    if(digest)memcpy(h.plan_sha256,digest,32);
    NSMutableData *wire=[NSMutableData dataWithCapacity:(NSUInteger)length];add(wire,&h,sizeof(h));
    uint32_t offset=(uint32_t)(sizeof(h)+n*sizeof(ffmd_section));
    for(NSUInteger i=0;i<n;i++){
        ffmd_section s={.type=types[i],.version=1,.stride=strides[i],
            .count=(uint32_t)(bodies[i].length/strides[i]),.offset=offset,.bytes=(uint32_t)bodies[i].length};
        add(wire,&s,sizeof(s));offset+=s.bytes;
    }
    for(NSData *body in bodies)[wire appendData:body];
    return [wire copy];
}
static ffmd_graph_binding binding(NSDictionary *row){
    return (ffmd_graph_binding){.id=number(row[@"id"]),.generation=number(row[@"generation"]),
        .offset=number(row[@"offset"]),.stride=u32(row[@"stride"]),.length=u32(row[@"length"])};
}
static NSDictionary *canonical_reference(NSDictionary *row){
    NSMutableDictionary *copy=[row mutableCopy];
    for(NSString *key in @[@"id",@"role",@"index",@"level",@"slice",@"depth_plane",
        @"shared_cut_id",@"shared_role",@"shared_index"])[copy removeObjectForKey:key];
    return [copy copy];
}
BOOL ffmd_encode_graph(NSDictionary *graph,NSDictionary *sidecar,NSData **plan,NSData **dynamic){
    if(plan)*plan=nil;if(dynamic)*dynamic=nil;
    @try {
    if(![graph isKindOfClass:[NSDictionary class]]||![sidecar isKindOfClass:[NSDictionary class]]||
       ![graph[@"format"] isEqual:@"bedrock-draw-resource-cut"]||![graph[@"version"] isEqual:@2]||
       ![sidecar[@"format"] isEqual:@"bedrock-native-frame-pass"]||![sidecar[@"version"] isEqual:@1]||
       ![graph[@"complete_pass"] boolValue])return NO;
    NSArray *drawRows=graph[@"draws"],*snapshotRows=graph[@"snapshots"],*textureRows=graph[@"textures"],*samplerRows=graph[@"samplers"];
    if(![drawRows isKindOfClass:[NSArray class]]||drawRows.count>FF_DRAW_PASS_LIMIT||
       ![snapshotRows isKindOfClass:[NSArray class]]||snapshotRows.count>1024||
       ![textureRows isKindOfClass:[NSArray class]]||textureRows.count>128||
       ![samplerRows isKindOfClass:[NSArray class]]||samplerRows.count>32)return NO;
    NSString *cutText=graph[@"cut_id"];
    if(![cutText isKindOfClass:[NSString class]]||![cutText hasPrefix:@"draw-cut-"])return NO;
    NSString *digits=[cutText substringFromIndex:9];
    if(!digits.length||[digits characterAtIndex:0]=='0')return NO;
    uint64_t cut=0;for(NSUInteger i=0;i<digits.length;i++){
        unichar c=[digits characterAtIndex:i];if(c<'0'||c>'9'||cut>(UINT64_MAX-(uint64_t)(c-'0'))/10)return NO;
        cut=cut*10+(uint64_t)(c-'0');
    }
    NSMutableData *planDraw=[NSMutableData data],*planSlot=[NSMutableData data];
    NSMutableData *snapshots=[NSMutableData data],*draws=[NSMutableData data],*bindings=[NSMutableData data];
    NSMutableData *arguments=[NSMutableData data],*textures=[NSMutableData data],*planes=[NSMutableData data],*samplers=[NSMutableData data];
    NSMutableArray<NSArray *> *argPending=[NSMutableArray array];
    uint32_t bindingCount=0,argumentCount=0,slotCount=0;
    for(NSUInteger i=0;i<snapshotRows.count;i++){
        NSDictionary *row=snapshotRows[i];
        if(![row isKindOfClass:[NSDictionary class]])return NO;
        if(number(row[@"id"])!=i+1)return NO;
        BOOL incarnation=row[@"source_incarnation"]!=nil,generation=row[@"source_generation"]!=nil,
            offset=row[@"source_offset"]!=nil;
        if(incarnation!=generation||generation!=offset)return NO;
        BOOL provenance=incarnation;
        ffmd_graph_snapshot s={.generation=u32(row[@"generation"]),.has_provenance=provenance,
            .length=number(row[@"length"]),.source_incarnation=optional_number(row[@"source_incarnation"]),
            .source_generation=optional_number(row[@"source_generation"]),.source_offset=optional_number(row[@"source_offset"])};
        add(snapshots,&s,sizeof(s));
    }
    for(NSDictionary *row in drawRows){
        if(![row isKindOfClass:[NSDictionary class]])return NO;
        NSArray *tuple=row[@"draw"],*vertices=row[@"bindings"],*vc=row[@"vertex_constants"],*fc=row[@"fragment_constants"],*stages=row[@"arguments"];
        if(![tuple isKindOfClass:[NSArray class]]||tuple.count!=5||![vertices isKindOfClass:[NSArray class]]||
           ![vc isKindOfClass:[NSArray class]]||![fc isKindOfClass:[NSArray class]]||
           ![stages isKindOfClass:[NSArray class]]||stages.count!=2||
           vertices.count>32||vc.count>14||fc.count>14)return NO;
        NSArray *va=stages[0],*fa=stages[1];if(![va isKindOfClass:[NSArray class]]||![fa isKindOfClass:[NSArray class]]||va.count>128||fa.count>128)return NO;
        NSDictionary *indexed=row[@"indexed"];
        if(indexed&&![indexed isKindOfClass:[NSDictionary class]])return NO;
        ffmd_plan_draw p={.ia_slot_mask=u32(row[@"ia_slot_mask"]),.primitive=u32(tuple[0]),
            .vertex_count=(uint16_t)vertices.count,.constant_count={(uint16_t)vc.count,(uint16_t)fc.count},
            .argument_count={(uint16_t)va.count,(uint16_t)fa.count},.indexed=indexed?1:0,
            .index_type=indexed?u8(indexed[@"index_type"]):0,.argument_slot_first={slotCount,slotCount+(uint32_t)va.count}};
        add(planDraw,&p,sizeof(p));
        uint32_t firstBinding=bindingCount,firstArgument=argumentCount;
        for(NSArray *group in @[vertices,vc,fc])for(NSDictionary *ref in group){
            ffmd_graph_binding b=binding(ref);add(bindings,&b,sizeof(b));bindingCount++;
        }
        uint32_t index=FFMD_NO_BINDING;
        if(indexed){index=bindingCount;ffmd_graph_binding b=binding(row[@"index_binding"]);add(bindings,&b,sizeof(b));bindingCount++;}
        for(NSArray *stage in stages)for(NSDictionary *field in stage){
            if(![field isKindOfClass:[NSDictionary class]]||!field[@"offset"]||!field[@"kind"]||!field[@"value"])return NO;
            if((u32(field[@"kind"])==1)!=(field[@"buffer"]!=nil))return NO;
            ffmd_plan_argument_slot slot={.offset=u32(field[@"offset"]),.kind=u32(field[@"kind"])};
            add(planSlot,&slot,sizeof(slot));[argPending addObject:@[field[@"value"],field[@"buffer"]?:[NSNull null],field[@"kind"]]];
            argumentCount++;slotCount++;
        }
        ffmd_graph_draw d={.start=u32(tuple[1]),.count=u32(tuple[2]),.instances=u32(tuple[3]),.base_instance=u32(tuple[4]),
            .base_vertex=0,.binding_first=firstBinding,
            .argument_first=firstArgument,.index_binding=index,.index_count=optional_number(indexed[@"index_count"]),
            .index_offset=optional_number(indexed[@"index_offset"])};
        if(indexed&&!ffst_value_i32(indexed[@"base_vertex"],&d.base_vertex))return NO;
        add(draws,&d,sizeof(d));
    }
    for(NSArray *item in argPending){
        id ref=item[1];uint32_t index=FFMD_NO_BINDING;
        if(ref!=[NSNull null]){
            if(![ref isKindOfClass:[NSDictionary class]])return NO;
            index=bindingCount;ffmd_graph_binding b=binding(ref);add(bindings,&b,sizeof(b));bindingCount++;
        }
        ffmd_graph_argument_value a={.value=number(item[0]),.buffer_binding=index};add(arguments,&a,sizeof(a));
    }
    uint32_t planeCount=0;
    for(NSUInteger i=0;i<textureRows.count;i++){
        NSDictionary *row=textureRows[i];if(number(row[@"id"])!=i+1)return NO;
        NSArray *ps=row[@"planes"],*sw=row[@"swizzle"];
        if(![ps isKindOfClass:[NSArray class]]||ps.count>256||!(!sw||([sw isKindOfClass:[NSArray class]]&&sw.count==4)))return NO;
        ffmd_graph_texture t={.format=u32(row[@"format"]),.texture_type=u32(row[@"texture_type"]),
            .width=u32(row[@"width"]),.height=u32(row[@"height"]),.mip_count=u32(row[@"mip_count"]),
            .array_length=u32(row[@"array_length"]),.has_swizzle=sw?1:0,
            .plane_first=planeCount,.plane_count=(uint32_t)ps.count,.length=number(row[@"length"])};
        for(unsigned i=0;i<4;i++)t.swizzle[i]=sw?u32(sw[i]):0;
        add(textures,&t,sizeof(t));
        for(NSDictionary *rowPlane in ps){
            ffmd_graph_texture_plane p={.mip=u32(rowPlane[@"mip"]),.slice=u32(rowPlane[@"slice"]),
                .offset=number(rowPlane[@"offset"]),.row_bytes=number(rowPlane[@"row_bytes"]),.length=number(rowPlane[@"length"])};
            add(planes,&p,sizeof(p));planeCount++;
        }
    }
    for(NSUInteger i=0;i<samplerRows.count;i++){
        NSDictionary *row=samplerRows[i];if(number(row[@"id"])!=i+1)return NO;
        NSArray *address=row[@"address"];if(![address isKindOfClass:[NSArray class]]||address.count!=3)return NO;
        ffmd_graph_sampler s={.address={u32(address[0]),u32(address[1]),u32(address[2])},
            .min_filter=u32(row[@"min_filter"]),.mag_filter=u32(row[@"mag_filter"]),.mip_filter=u32(row[@"mip_filter"]),
            .compare=u32(row[@"compare"]),.border=u32(row[@"border"]),.max_anisotropy=u32(row[@"max_anisotropy"]),
            .normalized=u32(row[@"normalized"]),.lod_average=u32(row[@"lod_average"])};
        float lo=[row[@"lod_min"] floatValue],hi=[row[@"lod_max"] floatValue];
        if(!isfinite(lo)||!isfinite(hi))return NO;memcpy(&s.lod_min_bits,&lo,4);memcpy(&s.lod_max_bits,&hi,4);
        add(samplers,&s,sizeof(s));
    }
    uint16_t planTypes[]={FFMD_PLAN_DRAW,FFMD_PLAN_ARGUMENT_SLOT};
    uint32_t planStrides[]={sizeof(ffmd_plan_draw),sizeof(ffmd_plan_argument_slot)};
    NSData *p=emit(FFMD_PLAN,NULL,NULL,planTypes,planStrides,@[planDraw,planSlot]);if(!p)return NO;
    uint8_t digest[32];CC_SHA256(p.bytes,(CC_LONG)p.length,digest);
    uint64_t identity[]={number(sidecar[@"stream"]),number(sidecar[@"frame"]),number(sidecar[@"chunk"]),number(sidecar[@"payload_id"]),cut};
    uint16_t graphTypes[]={FFMD_GRAPH_SNAPSHOT,FFMD_GRAPH_DRAW,FFMD_GRAPH_BINDING,FFMD_GRAPH_ARGUMENT_VALUE,
        FFMD_GRAPH_TEXTURE,FFMD_GRAPH_TEXTURE_PLANE,FFMD_GRAPH_SAMPLER};
    uint32_t graphStrides[]={sizeof(ffmd_graph_snapshot),sizeof(ffmd_graph_draw),sizeof(ffmd_graph_binding),
        sizeof(ffmd_graph_argument_value),sizeof(ffmd_graph_texture),sizeof(ffmd_graph_texture_plane),sizeof(ffmd_graph_sampler)};
    NSData *g=emit(FFMD_GRAPH,identity,digest,graphTypes,graphStrides,
        @[snapshots,draws,bindings,arguments,textures,planes,samplers]);if(!g)return NO;
    if(plan)*plan=p;if(dynamic)*dynamic=g;return YES;
    }@catch(NSException *error){(void)error;return NO;}
}

BOOL ffmd_encode_sidecar(NSDictionary *sidecar,uint64_t cut_id,NSData *plan,NSData **encoded){
    if(encoded)*encoded=nil;
    @try {
    if(![sidecar isKindOfClass:[NSDictionary class]]||![sidecar[@"format"] isEqual:@"bedrock-native-frame-pass"]||
       ![sidecar[@"version"] isEqual:@1]||!plan.length)return NO;
    NSArray *rows=sidecar[@"resources"],*snapshotRefs=sidecar[@"snapshots"],*textureRefs=sidecar[@"textures"],
        *attachmentRefs=sidecar[@"attachments"],*commandTypes=sidecar[@"command_types"];
    if(![rows isKindOfClass:[NSArray class]]||rows.count>4096||![snapshotRefs isKindOfClass:[NSArray class]]||snapshotRefs.count>1024||
       ![textureRefs isKindOfClass:[NSArray class]]||textureRefs.count>128||
       ![attachmentRefs isKindOfClass:[NSArray class]]||attachmentRefs.count>4||
       ![commandTypes isKindOfClass:[NSArray class]]||commandTypes.count>65536)return NO;
    NSMutableData *resources=[NSMutableData data],*snapshots=[NSMutableData data],*textures=[NSMutableData data],
        *attachments=[NSMutableData data],*commands=[NSMutableData data];
    NSMutableDictionary<NSNumber *,NSMutableArray<NSNumber *> *> *byRoot=[NSMutableDictionary dictionary];
    for(NSUInteger i=0;i<rows.count;i++){
        NSDictionary *row=rows[i];if(![row isKindOfClass:[NSDictionary class]])return NO;
        NSNumber *root=row[@"root"];if(!root)return NO;
        NSMutableArray<NSNumber *> *bucket=byRoot[root];
        if(!bucket){bucket=[NSMutableArray array];byRoot[root]=bucket;}[bucket addObject:@(i)];
        ffmd_sidecar_resource r={.kind=number(row[@"kind"]),.root=number(row[@"root"]),.view=number(row[@"view"]),
            .allocation_generation=number(row[@"allocation_generation"]),.input_content_version=number(row[@"input_content_version"]),
            .output_content_version=number(row[@"output_content_version"]),.offset=number(row[@"offset"]),.length=number(row[@"length"]),
            .buffer_base_offset=optional_number(row[@"buffer_base_offset"]),.buffer_length=optional_number(row[@"buffer_length"]),
            .flags=u32(row[@"flags"]),.role=optional_u32(row[@"role"]),.base_mip=optional_u32(row[@"base_mip"]),.base_slice=optional_u32(row[@"base_slice"]),
            .mip_count=optional_u32(row[@"mip_count"]),.slice_count=optional_u32(row[@"slice_count"]),.format=optional_u32(row[@"format"]),
            .type=optional_u32(row[@"type"]),.width=optional_u32(row[@"width"]),.height=optional_u32(row[@"height"]),
            .array_length=optional_u32(row[@"array_length"]),.sample_count=optional_u32(row[@"sample_count"])};
        NSArray *sw=row[@"swizzle"];if(sw&&(![sw isKindOfClass:[NSArray class]]||sw.count!=4))return NO;
        for(unsigned j=0;j<4;j++)r.swizzle[j]=sw?u32(sw[j]):0;
        add(resources,&r,sizeof(r));
    }
    NSNumber *(^referenceIndex)(NSDictionary *)=^NSNumber *(NSDictionary *row){
        NSDictionary *canonical=canonical_reference(row);
        for(NSNumber *candidate in byRoot[row[@"root"]])
            if([rows[candidate.unsignedIntegerValue] isEqual:canonical])return candidate;
        return nil;
    };
    for(NSArray *list in @[snapshotRefs,textureRefs]){
        NSMutableData *target=list==snapshotRefs?snapshots:textures;
        for(NSDictionary *row in list){NSNumber *index=referenceIndex(row);if(!index)return NO;
            ffmd_sidecar_index ref={.resource_index=(uint16_t)index.unsignedIntValue};add(target,&ref,sizeof(ref));}
    }
    NSDictionary *roles=@{@"color":@(FFMD_ATTACHMENT_COLOR),@"color_resolve":@(FFMD_ATTACHMENT_COLOR_RESOLVE),
        @"depth":@(FFMD_ATTACHMENT_DEPTH),@"stencil":@(FFMD_ATTACHMENT_STENCIL)};
    for(NSDictionary *row in attachmentRefs){NSNumber *index=referenceIndex(row),*role=roles[row[@"role"]];
        if(!index||!role)return NO;
        ffmd_sidecar_attachment a={.resource_index=(uint16_t)index.unsignedIntValue,.role=u8(role),
            .index=u8(row[@"index"]),.level=u32(row[@"level"]),.slice=u32(row[@"slice"]),
            .depth_plane=u32(row[@"depth_plane"]),.shared_cut_id=optional_number(row[@"shared_cut_id"]),
            .shared_role=optional_u8(row[@"shared_role"]),.shared_index=optional_u8(row[@"shared_index"])};
        add(attachments,&a,sizeof(a));
    }
    for(NSNumber *kind in commandTypes){ffmd_sidecar_command c={.command_type=u32(kind)};add(commands,&c,sizeof(c));}
    uint8_t digest[32];CC_SHA256(plan.bytes,(CC_LONG)plan.length,digest);
    uint64_t identity[]={number(sidecar[@"stream"]),number(sidecar[@"frame"]),number(sidecar[@"chunk"]),number(sidecar[@"payload_id"]),cut_id};
    uint16_t types[]={FFMD_SIDECAR_RESOURCE,FFMD_SIDECAR_SNAPSHOT_INDEX,FFMD_SIDECAR_TEXTURE_INDEX,
        FFMD_SIDECAR_ATTACHMENT,FFMD_SIDECAR_COMMAND_TYPE};
    uint32_t strides[]={sizeof(ffmd_sidecar_resource),sizeof(ffmd_sidecar_index),sizeof(ffmd_sidecar_index),
        sizeof(ffmd_sidecar_attachment),sizeof(ffmd_sidecar_command)};
    NSData *wire=emit(FFMD_SIDECAR,identity,digest,types,strides,@[resources,snapshots,textures,attachments,commands]);
    if(!wire)return NO;if(encoded)*encoded=wire;return YES;
    }@catch(NSException *error){(void)error;return NO;}
}
