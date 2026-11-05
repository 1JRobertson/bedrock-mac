/* Source-side ordered mutation emitter; no Minecraft or Metal pointers on wire. */
#ifndef BEDROCK_PERSISTENT_RESOURCE_SOURCE_H
#define BEDROCK_PERSISTENT_RESOURCE_SOURCE_H
#include <stddef.h>
#include <stdint.h>
typedef struct { uint64_t object, generation; } FFPSHandle;
typedef enum { FFPS_CREATE=1, FFPS_WRITE=2, FFPS_COPY=3, FFPS_DESTROY=4 } FFPSOperation;
typedef struct {
    FFPSOperation operation;
    FFPSHandle target, source;
    uint64_t offset, source_offset, length;
    /* Borrowed only during emit; sink MUST copy independently before return. */
    const void *bytes;
} FFPSEvent;
typedef int (*FFPSEmit)(void *context,const FFPSEvent *event);
typedef struct FFPSSource FFPSSource;
/* All calls are serialized by the caller with the same ordered command stream.
 * emit returns 1 only after accepting the complete event in stream order; on
 * failure the source state is unchanged and caller must stop or retry in order. */
FFPSSource *ffps_create(FFPSEmit emit,void *context);
void ffps_free(FFPSSource *source);
int ffps_buffer_create(FFPSSource *,FFPSHandle,uint64_t length);
int ffps_buffer_write(FFPSSource *,FFPSHandle,uint64_t offset,const void *bytes,size_t length);
int ffps_buffer_copy(FFPSSource *,FFPSHandle source,uint64_t source_offset,FFPSHandle target,uint64_t target_offset,uint64_t length);
int ffps_buffer_destroy(FFPSSource *,FFPSHandle);
#endif
