#ifndef FULLFRAME_SHADER_PAIR_H
#define FULLFRAME_SHADER_PAIR_H
#include <stddef.h>
/* One explicitly armed, private original/native result pair. */
int ff_shader_pair_claim(void);
void ff_shader_pair_abandon(void);
void ff_shader_pair_publish(const void *original,size_t original_size,const void *native,size_t native_size);
#endif
