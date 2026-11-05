/* Bounded native -> original-source row bytes. Independent of forward credit. */
#ifndef BEDROCK_READBACK_STREAM_H
#define BEDROCK_READBACK_STREAM_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
#define FFRB_ENDPOINT_ENV "BEDROCK_FULLFRAME_READBACK_STREAM"
#define FFRB_MAGIC UINT32_C(0x42524646)
#define FFRB_VERSION 1u
#define FFRB_MAX_BYTES (32u * 1024u * 1024u)
enum ffrb_role { FFRB_NATIVE=1,FFRB_SOURCE=2 };
enum ffrb_result { FFRB_OK,FFRB_EMPTY,FFRB_BACKPRESSURE,FFRB_CLOSED,FFRB_PEER_DEAD,FFRB_INVALID,FFRB_ORDER,FFRB_TOO_LARGE };
typedef struct ffrb_record {
    uint32_t magic,version,bytes,reserved;
    uint64_t sequence;
    uint64_t serial,stream,frame,chunk,record_digest,queue_completion;
    uint32_t encoder,command;
    uint64_t root,generation,content_version,offset;
    uint64_t row_bytes,row_length,row_count,length;
    uint64_t data_digest,reserved64;
} ffrb_record;
typedef struct ffrb_endpoint ffrb_endpoint;
/* Creation requires an empty, owned regular0600/nlink1 file. slots1..2 and
 * dataBytes4096..32MiB are hard limits; fixed control area, no resizing. */
enum ffrb_result ffrb_create(int fd,uint32_t slots,uint32_t dataBytes);
enum ffrb_result ffrb_attach(int fd,enum ffrb_role role,ffrb_endpoint **out);
void ffrb_destroy(ffrb_endpoint *endpoint);
/* Publish accepts metadata with transport fields magic/version/bytes/sequence/
 * length/digest and all reserved fields zero. It supplies those fields, copies
 * the complete packed bytes, then atomically exposes one message. Metadata
 * binds six exact forward-packet fields plus operation, root and final content
 * version. Packed length must equal row_length*row_count; row_bytes is original
 * destination pitch, not packed stride. No padding bytes are returned. */
enum ffrb_result ffrb_publish(ffrb_endpoint *,const ffrb_record *,const void *,size_t);
/* Peek copies validated metadata and lends immutable bytes until consume.
 * Sequence, bounds, overflow, reserved fields and full-byte digest are checked.
 * Source must additionally match its ORIGINAL expected target before scatter. */
enum ffrb_result ffrb_peek(ffrb_endpoint *,ffrb_record *,const void **,size_t *);
enum ffrb_result ffrb_consume(ffrb_endpoint *,uint64_t sequence);
enum ffrb_result ffrb_wait(ffrb_endpoint *,uint32_t milliseconds);
void ffrb_stop(ffrb_endpoint *);
uint64_t ffrb_digest(const void *,size_t);
#ifdef __cplusplus
}
static_assert(sizeof(ffrb_record)==160,"readback stream metadata ABI");
#else
_Static_assert(sizeof(ffrb_record)==160,"readback stream metadata ABI");
#endif
#endif
