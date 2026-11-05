#ifndef BEDROCK_NATIVE_BUFFER_REF_EXPERIMENT_H
#define BEDROCK_NATIVE_BUFFER_REF_EXPERIMENT_H
#include <stdint.h>
/* Private experiment only: a graph row can refer to an already-defined native
 * buffer instead of carrying a source snapshot. The receiver independently
 * verifies all identity, authority and defined-range requirements. */
#define FF_NATIVE_BUFFER_REF_MAGIC UINT64_C(0x3152464252464646)
#define FF_NATIVE_BUFFER_REF_VERSION UINT64_C(1)
typedef struct {
    uint64_t magic,version;
    uint64_t stream,frame,chunk,payload,snapshot_id;
    uint64_t root,generation,input_version,offset,length;
} ff_native_buffer_ref;
_Static_assert(sizeof(ff_native_buffer_ref)==12*sizeof(uint64_t),"reference layout");
#endif
