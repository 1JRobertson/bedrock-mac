#ifndef BEDROCK_NATIVE_BOUNDARY_UPLOAD_H
#define BEDROCK_NATIVE_BOUNDARY_UPLOAD_H
#include <stddef.h>
#include <stdint.h>
/* Source-side immutable WRITE_DISCARD bytes. Exact allocation generations and
 * byte ranges only. Never a native GPU-write cache. A miss keeps the existing
 * ordered GPU acquisition path; a poisoned store rejects the entire capture. */
typedef struct ffbu_store ffbu_store;
ffbu_store *ffbu_create(size_t budget);
void ffbu_destroy(ffbu_store *);
int ffbu_write(ffbu_store *,uint64_t root,uint64_t generation,uint64_t offset,
    const void *bytes,size_t length);
/* 1 copied, 0 absent, -1 invalid/poisoned; copies while holding ownership lock. */
int ffbu_copy(ffbu_store *,uint64_t root,uint64_t generation,uint64_t offset,
    void *destination,size_t length);
void ffbu_retire(ffbu_store *,uint64_t root,uint64_t generation);
int ffbu_write_handle(ffbu_store *,uint64_t root,uint64_t generation,uint64_t offset,const void *bytes,size_t length,uint64_t handle);
void ffbu_retire_handle(ffbu_store *,uint64_t handle);
/* Until source authority is complete, the live bridge validates but does not
 * retain uploads, and its copy lookup always falls back to the GPU snapshot. */
uint32_t fullframe_boundary_upload(uint64_t root,uint64_t generation,uint64_t offset,
    const void *bytes,uint64_t length,uint64_t handle);
int fullframe_boundary_upload_copy(uint64_t root,uint64_t generation,uint64_t offset,
    void *destination,size_t length);
void fullframe_boundary_upload_retire(uint64_t root,uint64_t generation);
void fullframe_boundary_upload_invalidate(uint64_t handle);
void fullframe_boundary_upload_report(void);
#endif
