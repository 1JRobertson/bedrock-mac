/* Decode FFMD1 resource sidecar rows for existing frame validators. */
#ifndef BEDROCK_NATIVE_METADATA_SIDECAR_H
#define BEDROCK_NATIVE_METADATA_SIDECAR_H
#import <Foundation/Foundation.h>
#include "native_metadata_wire.h"

NSDictionary *ffmd_sidecar_dictionary(const ffmd_view *view);
#endif
