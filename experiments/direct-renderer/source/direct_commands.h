/* Ordered, bounded direct resource command stream. Little-endian x86_64/arm64.
 * No process pointers, diagnostic manifests or implicit GPU-completion claims. */
#ifndef BEDROCK_DIRECT_COMMANDS_H
#define BEDROCK_DIRECT_COMMANDS_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#include "persistent_resource_source.h"
#define FFDC_MAGIC UINT64_C(0x31444d4352444646)
#define FFDC_VERSION 1u
#define FFDC_MAX_BYTES (16u * 1024u * 1024u)
#define FFDC_MAX_COMMANDS 65536u

typedef struct {
    uint64_t magic, serial, stream, frame, chunk, completion;
    uint32_t version, bytes, count, reserved;
} FFDCHeader;
enum { FFDC_BEGIN_RENDER=5, FFDC_BIND_PIPELINE=6, FFDC_DRAW_TRIANGLES=7, FFDC_END_RENDER=8,
    FFDC_SET_VIEWPORT=9, FFDC_SET_SCISSOR=10, FFDC_SET_RASTER=11,
    FFDC_SET_BUFFER=12, FFDC_SET_BUFFER_OFFSET=13, FFDC_SET_FRAGMENT_BYTES=14,
    FFDC_SET_FRAGMENT_TEXTURE=15, FFDC_DRAW=16, FFDC_DRAW_INDEXED=17,
    FFDC_VERTEX_TABLE=18, FFDC_CONSTANT_TABLE=19, FFDC_ARGUMENT_TABLE=20 };
enum { FFDC_VERTEX=0, FFDC_FRAGMENT=1, FFDC_MAX_INLINE_BYTES=4096 };
/* Fixed-width little-endian payloads; reserved fields MUST be zero. Object IDs
 * and allocation generations are distinct; {0,0} means explicit unbind. */
typedef struct { double x,y,width,height,znear,zfar; } FFDCViewport;
typedef struct { uint64_t x,y,width,height; } FFDCScissor;
typedef struct { uint32_t fill,cull,depth_clip,winding; float depth_bias,slope_scale,depth_bias_clamp; uint32_t reserved; } FFDCRaster;
typedef struct { uint64_t object,generation,offset; uint32_t stage,index; } FFDCBufferBinding;
typedef struct { uint64_t offset; uint32_t stage,index; } FFDCBufferOffset;
typedef struct { uint64_t object,generation; uint32_t index,reserved; } FFDCTextureBinding;
typedef struct { uint64_t first,count; uint32_t primitive,instances,base_instance,reserved; } FFDCDraw;
typedef struct { uint64_t object,generation,offset,count; uint32_t primitive,index_type,instances; int32_t base_vertex; uint32_t base_instance,reserved; } FFDCIndexedDraw;
/* Logical DXMT table values, never source GPU addresses or Metal handles. */
enum { FFDC_FIELD_BUFFER=1, FFDC_FIELD_TEXTURE=2, FFDC_FIELD_SAMPLER=3, FFDC_FIELD_VALUE=4 };
typedef struct { uint64_t object,generation,offset; uint32_t stride,length; } FFDCLogicalBuffer;
typedef struct { uint32_t offset,kind; uint64_t value; FFDCLogicalBuffer buffer; uint64_t object,generation; } FFDCLogicalField;
#ifdef __cplusplus
#define FFDC_STATIC_ASSERT static_assert
#else
#define FFDC_STATIC_ASSERT _Static_assert
#endif
FFDC_STATIC_ASSERT(sizeof(FFDCViewport)==48 && sizeof(FFDCScissor)==32 && sizeof(FFDCRaster)==32 &&
    sizeof(FFDCBufferBinding)==32 && sizeof(FFDCBufferOffset)==16 && sizeof(FFDCTextureBinding)==24 &&
    sizeof(FFDCDraw)==32 && sizeof(FFDCIndexedDraw)==56 && sizeof(FFDCLogicalBuffer)==32 && sizeof(FFDCLogicalField)==64,"direct render wire ABI");
typedef struct {
    uint32_t operation, bytes;
    uint64_t target, target_generation, source, source_generation;
    uint64_t offset, source_offset, length;
} FFDCRecord;
FFDC_STATIC_ASSERT(sizeof(FFDCHeader)==64 && sizeof(FFDCRecord)==64,"direct wire ABI");
typedef struct { unsigned char *data; size_t capacity, length; uint32_t count; int sealed; } FFDCWriter;
/* Writer owns no storage. Each successful emit copies the entire event before
 * returning; failure leaves the batch unchanged and can be retried in order. */
int ffdc_begin(FFDCWriter *,void *,size_t,uint64_t serial,uint64_t stream,uint64_t frame,uint64_t chunk,uint64_t completion);
int ffdc_emit(void *,const FFPSEvent *);
/* The experimental render subset is a clear/store pass with a non-indexed
 * triangle draw with first=0, count=3 and instances=1. Other pass/draw forms
 * are not represented and must reject. */
int ffdc_begin_render(FFDCWriter *,uint64_t object,uint64_t generation,const float clear[4]);
int ffdc_bind_pipeline(FFDCWriter *,uint64_t object,uint64_t generation);
int ffdc_draw_triangles(FFDCWriter *,uint32_t first,uint32_t count,uint32_t instances);
int ffdc_end_render(FFDCWriter *);
/* Append one of the new typed state/draw operations. For fragment bytes, index
 * is supplied separately and payload is copied synchronously, up to 4096 bytes.
 * The source and native executor must preserve command order; unsupported DXMT
 * operations, queries, waits and barriers cannot be silently dropped. Buffer
 * and inline-byte slots 16, 29 and 30 reject because DXMT tables there contain
 * source GPU addresses; send logical tables instead. */
int ffdc_render_command(FFDCWriter *,uint32_t operation,const void *payload,size_t bytes);
int ffdc_fragment_bytes(FFDCWriter *,uint32_t index,const void *bytes,size_t length);
/* Vertex count <=32, constant count <=14, argument count <=128. stage must be
 * FFDC_VERTEX for vertices and either stage for other tables. Arrays are copied
 * synchronously. An empty table resets the corresponding logical state. */
int ffdc_logical_table(FFDCWriter *,uint32_t operation,uint32_t stage,const void *entries,size_t count);
int ffdc_seal(FFDCWriter *);
/* Validate the complete envelope, typed payloads and pass order before calling
 * any visitor. Validity is not proof that resource generations/ranges exist. */
typedef int (*FFDCVisit)(void *,const FFDCRecord *,const void *payload);
int ffdc_validate(const void *,size_t);
/* Source adapter must call this before publishing its complete staged batch;
 * unlike legacy ffdc_validate, it also rejects an unterminated render pass. */
int ffdc_validate_complete(const void *,size_t);
int ffdc_visit(const void *,size_t,FFDCVisit,void *);
/* Connected SOCK_STREAM only; failure after a partial write is fatal to that
 * connection. EOF/failure is fatal, not a GPU receipt. The caller serializes
 * writers and keeps bytes immutable for the entire send/visit/submit call.
 * Only complete validated batches can be sent/received. Reader allocates *out,
 * caller frees; maximum frame is FFDC_MAX_BYTES. */
int ffdc_send(int fd,const void *,size_t);
int ffdc_receive(int fd,void **out,size_t *length);
/* These are GPU completion receipts, never transport consumption or a query
 * result. Sender must call only from the actual Metal completion path. Receive
 * matches exact expected identities; failure is terminal to the connection. */
enum { FFDC_GPU_COMPLETED=1, FFDC_GPU_FAILED=2 };
typedef struct { uint64_t magic,serial,completion; uint32_t status,reserved; } FFDCReceipt;
int ffdc_send_receipt(int fd,uint64_t serial,uint64_t completion,int gpu_completed);
int ffdc_receive_receipt(int fd,uint64_t serial,uint64_t completion,int *gpu_completed);
#undef FFDC_STATIC_ASSERT
#ifdef __cplusplus
}
#endif
#endif
