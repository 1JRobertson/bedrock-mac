#import "native_metadata_sidecar.h"
#include "frame_stream.h"
#include "vertex_resources.h"

#if !__has_feature(objc_arc)
#error native_metadata_sidecar.m requires ARC
#endif

static NSDictionary *resource_dictionary(ffmd_sidecar_resource r,uint64_t payload) {
    if((r.kind!=FFS_BUFFER&&r.kind!=FFS_TEXTURE)||!r.root||!r.view||!r.allocation_generation||
       !r.input_content_version||!r.output_content_version||r.role)return nil;
    NSMutableDictionary *d=[@{@"kind":@(r.kind),@"root":@(r.root),@"view":@(r.view),
        @"allocation_generation":@(r.allocation_generation),@"input_content_version":@(r.input_content_version),
        @"output_content_version":@(r.output_content_version),@"offset":@(r.offset),@"length":@(r.length),
        @"flags":@(r.flags),@"payload_id":@(payload)} mutableCopy];
    if(r.kind==FFS_BUFFER){
        if(r.base_mip||r.base_slice||r.mip_count||r.slice_count||r.format||r.type||r.width||r.height||
           r.array_length||r.sample_count||r.swizzle[0]||r.swizzle[1]||r.swizzle[2]||r.swizzle[3])return nil;
        d[@"buffer_base_offset"]=@(r.buffer_base_offset);d[@"buffer_length"]=@(r.buffer_length);
    }else{
        if(r.buffer_base_offset||r.buffer_length)return nil;
        d[@"base_mip"]=@(r.base_mip);d[@"base_slice"]=@(r.base_slice);
        d[@"mip_count"]=@(r.mip_count);d[@"slice_count"]=@(r.slice_count);
        d[@"format"]=@(r.format);d[@"type"]=@(r.type);d[@"width"]=@(r.width);
        d[@"height"]=@(r.height);d[@"array_length"]=@(r.array_length);
        d[@"sample_count"]=@(r.sample_count);
        d[@"swizzle"]=@[@(r.swizzle[0]),@(r.swizzle[1]),@(r.swizzle[2]),@(r.swizzle[3])];
    }
    return [d copy];
}

NSDictionary *ffmd_sidecar_dictionary(const ffmd_view *view) {
    if(!view||view->header.kind!=FFMD_SIDECAR||
       view->sections[0].count>FFS_MAX_RESOURCES||
       view->sections[1].count>FF_DRAW_RESOURCE_LIMIT||
       view->sections[2].count>FF_TEXTURE_RESOURCE_LIMIT||
       view->sections[3].count>4||view->sections[4].count>FFS_MAX_RECORDS)return nil;
    NSMutableArray *resources=[NSMutableArray arrayWithCapacity:view->sections[0].count];
    for(size_t i=0;i<view->sections[0].count;++i){ffmd_sidecar_resource row;
        if(!ffmd_view_row(view,0,i,&row,sizeof(row)))return nil;
        NSDictionary *d=resource_dictionary(row,view->header.payload_id);if(!d)return nil;
        [resources addObject:d];}
    NSMutableArray *snapshots=[NSMutableArray arrayWithCapacity:view->sections[1].count];
    NSMutableArray *textures=[NSMutableArray arrayWithCapacity:view->sections[2].count];
    for(unsigned section=1;section<=2;++section){NSMutableArray *target=section==1?snapshots:textures;
        for(size_t i=0;i<view->sections[section].count;++i){ffmd_sidecar_index row;
            if(!ffmd_view_row(view,section,i,&row,sizeof(row))||row.reserved||
               row.resource_index>=resources.count)return nil;
            NSDictionary *resource=resources[row.resource_index];
            if([resource[@"kind"] unsignedIntValue]!=(section==1?FFS_BUFFER:FFS_TEXTURE))return nil;
            NSMutableDictionary *reference=[resource mutableCopy];reference[@"id"]=@(i+1);
            [target addObject:[reference copy]];}}
    NSMutableArray *attachments=[NSMutableArray arrayWithCapacity:view->sections[3].count];
    NSArray *roles=@[@"",@"color",@"color_resolve",@"depth",@"stencil"];
    for(size_t i=0;i<view->sections[3].count;++i){ffmd_sidecar_attachment row;
        if(!ffmd_view_row(view,3,i,&row,sizeof(row))||row.reserved||row.resource_index>=resources.count||
           row.role<FFMD_ATTACHMENT_COLOR||row.role>FFMD_ATTACHMENT_STENCIL||
           row.shared_role>FFMD_SHARED_STENCIL||
           (row.shared_role==FFMD_SHARED_ABSENT&&(row.shared_cut_id||row.shared_index))||
           (row.shared_role!=FFMD_SHARED_ABSENT&&!row.shared_cut_id))return nil;
        NSDictionary *resource=resources[row.resource_index];if([resource[@"kind"] unsignedIntValue]!=FFS_TEXTURE)return nil;
        NSMutableDictionary *attachment=[resource mutableCopy];
        attachment[@"role"]=roles[row.role];attachment[@"index"]=@(row.index);
        attachment[@"level"]=@(row.level);attachment[@"slice"]=@(row.slice);
        attachment[@"depth_plane"]=@(row.depth_plane);
        if(row.shared_role){attachment[@"shared_cut_id"]=@(row.shared_cut_id);
            attachment[@"shared_role"]=@(row.shared_role);attachment[@"shared_index"]=@(row.shared_index);}
        [attachments addObject:[attachment copy]];}
    NSMutableArray *commands=[NSMutableArray arrayWithCapacity:view->sections[4].count];
    for(size_t i=0;i<view->sections[4].count;++i){ffmd_sidecar_command row;
        if(!ffmd_view_row(view,4,i,&row,sizeof(row)))return nil;[commands addObject:@(row.command_type)];}
    return @{@"resources":[resources copy],@"snapshots":[snapshots copy],
        @"textures":[textures copy],@"attachments":[attachments copy],@"command_types":[commands copy]};
}
