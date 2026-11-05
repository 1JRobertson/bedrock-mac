#ifndef LIVE_STARTUP_WIRE_H
#define LIVE_STARTUP_WIRE_H
#include <stdint.h>
#define FFLI_MAGIC UINT64_C(0x314a58544556494c)
typedef struct {uint64_t magic,length;uint32_t width,height,depth,slice,level,row,image,flags;} ffli_header;
#endif
