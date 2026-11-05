/* Direct render resource journal, private little-endian ABI. No pointers. */
#ifndef FF_DIRECT_PASS_JOURNAL_H
#define FF_DIRECT_PASS_JOURNAL_H
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#define FFJP_MAGIC UINT64_C(0x31304c4e524a5044)
#define FFJP_BATCH_MAGIC UINT64_C(0x3130424e524a5044)
typedef struct {uint64_t magic;uint32_t version,count;uint64_t bytes,reserved;} ffjp_batch;
typedef struct {uint32_t offset,bytes;} ffjp_entry;
#define FFJP_UPDATE 1u
#define FFJP_NATIVE 2u
#define FFJP_LIMIT (32u*1024u*1024u)
typedef struct {uint64_t magic,root,generation,epoch,offset,length,bytes;uint32_t flags,reserved;} ffjp_record;
_Static_assert(sizeof(ffjp_record)==64,"direct journal ABI");
static inline int ffjp_enabled(void){const char *v=getenv("BEDROCK_DIRECT_PASS");return v&&!strcmp(v,"1");}
static inline int ffjp_valid(const ffjp_record *r,size_t bytes){return r&&r->magic==FFJP_MAGIC&&r->root&&r->generation&&r->epoch&&!r->reserved&&r->length&&r->length<=FFJP_LIMIT&&r->offset<=UINT64_MAX-r->length&&r->bytes==bytes-sizeof(*r)&&bytes>=sizeof(*r)&&((r->flags==0&&!r->bytes)||(r->flags==FFJP_NATIVE&&!r->bytes)||(r->flags==FFJP_UPDATE&&r->bytes==r->length));}
#endif
