#ifndef BEDROCK_SOURCE_SCALAR_REFERENCE_H
#define BEDROCK_SOURCE_SCALAR_REFERENCE_H
/* Immutable producer-owned scalars. No borrowed pointers, handles, GPU objects,
 * native-write facts or cross-pass cache. Dictionary values remain available
 * for the unchanged legacy encoder and its ordinary validation. */
#include "metadata_wire_v1.h"
@interface FFSourceScalarReference : NSDictionary {
 @private uint64_t _values[13];BOOL _hasID;
}
+ (instancetype)reference:(const ffs_producer_resource *)r payload:(uint64_t)payload origin:(uint64_t)origin capacity:(uint64_t)capacity;
- (instancetype)withSnapshotID:(uint64_t)identity;
- (BOOL)checkedResource:(const ffs_producer_resource *)r payload:(uint64_t)payload output:(ffmd_sidecar_resource *)output;
- (BOOL)matchesSnapshot:(FFSourceScalarReference *)selected identity:(uint64_t)identity;
@end
static NSArray *ff_source_reference_keys(void){static NSArray *keys;static dispatch_once_t once;
 dispatch_once(&once,^{keys=[@[@"kind",@"root",@"view",@"allocation_generation",@"input_content_version",@"output_content_version",@"payload_id",@"flags",@"offset",@"length",@"buffer_length",@"buffer_base_offset",@"id"] retain];});return keys;}
@implementation FFSourceScalarReference
+ (instancetype)reference:(const ffs_producer_resource *)r payload:(uint64_t)payload origin:(uint64_t)origin capacity:(uint64_t)capacity {
 FFSourceScalarReference *v=[[self alloc]init];if(!v)return nil;
 const uint64_t values[12]={r->kind,r->root,r->view,r->allocation_generation,r->input_content_version,r->output_content_version,payload,r->flags,r->offset,r->length,capacity,origin};
 memcpy(v->_values,values,sizeof(values));return [v autorelease];
}
- (NSUInteger)count{return _hasID?13:12;}
- (id)objectForKey:(id)key {
 if(![key isKindOfClass:[NSString class]])return nil;NSArray *keys=ff_source_reference_keys();
 for(NSUInteger i=0;i<self.count;i++)if(key==keys[i]||[key isEqual:keys[i]])return i==7?@((uint32_t)_values[i]):@(_values[i]);
 return nil;
}
- (NSEnumerator *)keyEnumerator {
 NSArray *keys=ff_source_reference_keys();return [(_hasID?keys:[keys subarrayWithRange:NSMakeRange(0,12)]) objectEnumerator];
}
- (id)copyWithZone:(NSZone *)zone{(void)zone;return [self retain];}
- (id)mutableCopyWithZone:(NSZone *)zone {
 NSMutableDictionary *copy=[[NSMutableDictionary allocWithZone:zone]initWithCapacity:self.count];
 for(id key in self)copy[key]=self[key];return copy;
}
- (BOOL)isEqualToDictionary:(NSDictionary *)other {
 if([other isMemberOfClass:[FFSourceScalarReference class]]){FFSourceScalarReference *o=(id)other;
  return _hasID==o->_hasID&&!memcmp(_values,o->_values,self.count*sizeof(uint64_t));}
 return [super isEqualToDictionary:other];
}
- (BOOL)isEqual:(id)other{return [other isKindOfClass:[NSDictionary class]]&&[self isEqualToDictionary:other];}
- (instancetype)withSnapshotID:(uint64_t)identity {
 FFSourceScalarReference *v=[[[FFSourceScalarReference alloc]init]autorelease];if(!v)return nil;
 memcpy(v->_values,_values,12*sizeof(uint64_t));v->_values[12]=identity;v->_hasID=YES;return v;
}
- (BOOL)checkedResource:(const ffs_producer_resource *)r payload:(uint64_t)payload output:(ffmd_sidecar_resource *)out {
 if(!r||!out||_hasID||r->kind!=FFS_BUFFER||!r->root||!r->view||!r->allocation_generation||!r->input_content_version)return NO;
 const uint64_t expected[10]={r->kind,r->root,r->view,r->allocation_generation,r->input_content_version,r->output_content_version,payload,r->flags,r->offset,r->length};
 if(memcmp(_values,expected,sizeof(expected)))return NO;
 *out=(ffmd_sidecar_resource){.kind=r->kind,.root=r->root,.view=r->view,.allocation_generation=r->allocation_generation,
  .input_content_version=r->input_content_version,.output_content_version=r->output_content_version,.flags=r->flags,
  .offset=r->offset,.length=r->length,.buffer_length=_values[10],.buffer_base_offset=_values[11]};return YES;
}
- (BOOL)matchesSnapshot:(FFSourceScalarReference *)selected identity:(uint64_t)identity {
 return !_hasID&&selected->_hasID&&selected->_values[12]==identity&&!memcmp(_values,selected->_values,12*sizeof(uint64_t));
}
@end
#endif
