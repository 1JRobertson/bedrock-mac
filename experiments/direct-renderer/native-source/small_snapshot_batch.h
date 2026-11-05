/* One bounded, pointer-free batch of small immutable snapshots. */
#ifndef BEDROCK_SMALL_SNAPSHOT_BATCH_H
#define BEDROCK_SMALL_SNAPSHOT_BATCH_H
#include <stdint.h>
#include <stddef.h>
#include <string.h>
#define FFSB_MAGIC UINT64_C(0x3150414e53425046)
#define FFSB_MAX_BYTES (4u*1024u*1024u)
#define FFSB_MAX_ROWS 1024u
#define FFSB_NAME "cut-snapshot-batch.bin"
typedef struct {uint64_t magic;uint32_t version,count;uint64_t bytes,reserved;} ffsb_header;
typedef struct {uint64_t id,offset,length;} ffsb_entry;
_Static_assert(sizeof(ffsb_header)==32,"batch header ABI");
_Static_assert(sizeof(ffsb_entry)==24,"batch entry ABI");
static inline int ffsb_validate(const void *bytes,size_t length,ffsb_header *out){
 if(!bytes||length<sizeof(ffsb_header)||length>FFSB_MAX_BYTES)return 0;
 ffsb_header h;memcpy(&h,bytes,sizeof(h));
 if(h.magic!=FFSB_MAGIC||h.version!=1||!h.count||h.count>FFSB_MAX_ROWS||h.bytes!=length||h.reserved)return 0;
 uint64_t cursor=sizeof(h)+(uint64_t)h.count*sizeof(ffsb_entry),prior=0;if(cursor>length)return 0;
 for(uint32_t i=0;i<h.count;i++){
  ffsb_entry e;memcpy(&e,(const uint8_t*)bytes+sizeof(h)+i*sizeof(e),sizeof(e));
  if(e.id<=prior||e.id>FFSB_MAX_ROWS||e.offset!=cursor||!e.length||e.length>65536||e.length>length-cursor)return 0;
  prior=e.id;uint64_t end=cursor+e.length,rounded=(end+7)&~UINT64_C(7);if(rounded>length)return 0;
  for(uint64_t p=end;p<rounded;p++)if(((const uint8_t*)bytes)[p])return 0;cursor=rounded;
 }
 if(cursor!=length)return 0;if(out)*out=h;return 1;
}
#endif
