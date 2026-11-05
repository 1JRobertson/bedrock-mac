/* Decode FFMD1 resource sidecar rows for existing frame validators. */
#ifndef BEDROCK_NATIVE_METADATA_SIDECAR_H
#define BEDROCK_NATIVE_METADATA_SIDECAR_H
#import <Foundation/Foundation.h>
#include "native_metadata_wire.h"

BOOL ffmd_resource_raw(NSDictionary *reference,ffmd_sidecar_resource *row,uint64_t *payload);
BOOL ffmd_resource_valid(NSDictionary *reference);
NSData *ffmd_resource_root_key(NSDictionary *reference);
NSData *ffmd_resource_member_key(NSDictionary *reference);
NSDictionary *ffmd_sidecar_dictionary(const ffmd_view *view);
#endif
