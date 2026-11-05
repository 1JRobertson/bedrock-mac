#import "native_metadata_sidecar.h"
#include "frame_stream.h"
#include "vertex_resources.h"

#if !__has_feature(objc_arc)
#error native_metadata_sidecar.m requires ARC
#endif


#import <objc/runtime.h>
#include <dispatch/dispatch.h>
/* Typed transport has already bounded and copied these scalar rows. Keep them
 * immutable in their original representation instead of expanding every scalar
 * into dictionaries and repeatedly unboxing/type-checking them at each use.
 * JSON callers retain the full existing validator path. */
@interface FFMDNativeReference : NSDictionary {
@public
 ffmd_sidecar_resource raw;
 uint64_t payload,slot;
 BOOL valid;
 NSData *rootKey,*memberKey;
 NSArray *keys;
}
- (instancetype)initRow:(ffmd_sidecar_resource)row payload:(uint64_t)value slot:(uint64_t)sid;
@end
static NSArray *ffmd_common_keys(void){static NSArray *a;static dispatch_once_t o;dispatch_once(&o,^{a=@[@"kind",@"root",@"view",@"allocation_generation",@"input_content_version",@"output_content_version",@"offset",@"length",@"flags",@"payload_id"];});return a;}
static NSArray *ffmd_row_keys(BOOL texture){static NSArray *b,*t;static dispatch_once_t o;dispatch_once(&o,^{b=[ffmd_common_keys() arrayByAddingObjectsFromArray:@[@"buffer_base_offset",@"buffer_length"]];t=[ffmd_common_keys() arrayByAddingObjectsFromArray:@[@"base_mip",@"base_slice",@"mip_count",@"slice_count",@"format",@"type",@"width",@"height",@"array_length",@"sample_count",@"swizzle"]];});return texture?t:b;}
@implementation FFMDNativeReference
- (instancetype)initRow:(ffmd_sidecar_resource)r payload:(uint64_t)p slot:(uint64_t)s {
 self=[super init];if(!self)return nil;raw=r;payload=p;slot=s;
 valid=(r.kind==FFS_BUFFER||r.kind==FFS_TEXTURE)&&r.root&&r.view&&r.allocation_generation&&r.input_content_version&&r.input_content_version<UINT64_MAX&&
  (r.output_content_version==r.input_content_version||r.output_content_version==r.input_content_version+1)&&p&&r.length<=UINT64_MAX-r.offset&&(r.kind!=FFS_BUFFER||r.length);
 const uint64_t root[]={r.kind,r.root,r.allocation_generation};rootKey=[NSData dataWithBytes:root length:sizeof(root)];
 const uint64_t member[]={r.kind,r.root,r.view,r.allocation_generation,r.input_content_version,r.output_content_version,r.offset,r.length};memberKey=[NSData dataWithBytes:member length:sizeof(member)];
 keys=ffmd_row_keys(r.kind==FFS_TEXTURE);if(s)keys=[keys arrayByAddingObject:@"id"];return self;
}
- (NSUInteger)count{return keys.count;}
- (NSEnumerator *)keyEnumerator{return keys.objectEnumerator;}
- (id)copyWithZone:(NSZone *)zone{(void)zone;return self;}
- (id)mutableCopyWithZone:(NSZone *)zone{(void)zone;return [NSMutableDictionary dictionaryWithDictionary:self];}
- (id)objectForKey:(id)key {
 if([key isEqual:@"id"])return slot?@(slot):nil;
 NSUInteger i=NSNotFound;for(NSUInteger n=0;n<keys.count;n++)if(key==keys[n]){i=n;break;}
 if(i==NSNotFound)i=[keys indexOfObject:key];
 switch(i){case 0:return @(raw.kind);case 1:return @(raw.root);case 2:return @(raw.view);case 3:return @(raw.allocation_generation);
 case 4:return @(raw.input_content_version);case 5:return @(raw.output_content_version);case 6:return @(raw.offset);case 7:return @(raw.length);case 8:return @(raw.flags);case 9:return @(payload);default:break;}
 if(raw.kind==FFS_BUFFER){if(i==10)return @(raw.buffer_base_offset);if(i==11)return @(raw.buffer_length);return nil;}
 switch(i){case 10:return @(raw.base_mip);case 11:return @(raw.base_slice);case 12:return @(raw.mip_count);case 13:return @(raw.slice_count);
 case 14:return @(raw.format);case 15:return @(raw.type);case 16:return @(raw.width);case 17:return @(raw.height);case 18:return @(raw.array_length);case 19:return @(raw.sample_count);
 case 20:return @[@(raw.swizzle[0]),@(raw.swizzle[1]),@(raw.swizzle[2]),@(raw.swizzle[3])];default:return nil;}
}
@end
static FFMDNativeReference *ffmd_native_reference(NSDictionary *r){return object_getClass(r)==[FFMDNativeReference class]?(FFMDNativeReference *)r:nil;}
BOOL ffmd_resource_raw(NSDictionary *reference,ffmd_sidecar_resource *row,uint64_t *payload){FFMDNativeReference *r=ffmd_native_reference(reference);if(!r)return NO;if(row)*row=r->raw;if(payload)*payload=r->payload;return YES;}
BOOL ffmd_resource_valid(NSDictionary *reference){FFMDNativeReference *r=ffmd_native_reference(reference);return r&&r->valid;}
NSData *ffmd_resource_root_key(NSDictionary *reference){FFMDNativeReference *r=ffmd_native_reference(reference);return r?r->rootKey:nil;}
NSData *ffmd_resource_member_key(NSDictionary *reference){FFMDNativeReference *r=ffmd_native_reference(reference);return r?r->memberKey:nil;}
static BOOL ffmd_native_descriptors_enabled(void){static BOOL yes;static dispatch_once_t once;dispatch_once(&once,^{const char *p=getenv("BEDROCK_NATIVE_RESOURCE_DESCRIPTORS");yes=p&&!strcmp(p,"1");});return yes;}

static NSDictionary *resource_dictionary(ffmd_sidecar_resource r,uint64_t payload) {
    if((r.kind!=FFS_BUFFER&&r.kind!=FFS_TEXTURE)||!r.root||!r.view||!r.allocation_generation||
       !r.input_content_version||!r.output_content_version||r.role)return nil;
    if(ffmd_native_descriptors_enabled()){
        if(r.kind==FFS_BUFFER){if(r.base_mip||r.base_slice||r.mip_count||r.slice_count||r.format||r.type||r.width||r.height||r.array_length||r.sample_count||r.swizzle[0]||r.swizzle[1]||r.swizzle[2]||r.swizzle[3])return nil;}
        else if(r.buffer_base_offset||r.buffer_length)return nil;
        return [[FFMDNativeReference alloc] initRow:r payload:payload slot:0];
    }
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
            FFMDNativeReference *native=ffmd_native_reference(resource);
            if(native)[target addObject:[[FFMDNativeReference alloc] initRow:native->raw payload:native->payload slot:i+1]];
            else {NSMutableDictionary *reference=[resource mutableCopy];reference[@"id"]=@(i+1);[target addObject:[reference copy]];}}}
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
