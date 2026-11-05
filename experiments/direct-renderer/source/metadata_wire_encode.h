#ifndef FULLFRAME_METADATA_WIRE_ENCODE_H
#define FULLFRAME_METADATA_WIRE_ENCODE_H
#import <Foundation/Foundation.h>

/* Experimental v1 encoder; no live route until paired native decoder passes
 * retained-frame oracle tests. All output data is owned and immutable. */
#ifndef FFMD_ENCODER_API
#define FFMD_ENCODER_API
#endif
FFMD_ENCODER_API BOOL ffmd_encode_graph(NSDictionary *graph, NSDictionary *sidecar,
    NSData **plan, NSData **dynamic);
FFMD_ENCODER_API BOOL ffmd_encode_sidecar(NSDictionary *sidecar, uint64_t cut_id,
    NSData *plan, NSData **encoded);

#endif
