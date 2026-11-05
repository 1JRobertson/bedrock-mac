/* Experimental 64-bit bitcode handle routing; slots are never reused. */
#ifndef FULLFRAME_SHADER_HANDLES_H
#define FULLFRAME_SHADER_HANDLES_H
#include <stddef.h>
void *ff_shader_handle_create(void *original,const void *native,size_t native_size);
int ff_shader_handle_get(void *handle,const void **bytes,size_t *size);
/* Return recognized even for tombstones. Original, if returned, belongs to the
 * caller and must be destroyed through DXMT; NULL means already handled or pinned. */
int ff_shader_handle_release(void *handle,void **original);
void ff_shader_handle_bind(const void *bytes,size_t size,void *dispatch_data);
void ff_shader_data_retain(void *dispatch_data);
void *ff_shader_data_release(void *dispatch_data);
void *ff_shader_library_begin(void *dispatch_data);
void *ff_shader_handle_original(void *handle);
void *ff_shader_library_end(void *handle);
#endif
