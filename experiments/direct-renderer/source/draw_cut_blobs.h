/* Synchronous serialization of an already completed immutable draw resource cut. */
#ifndef FULLFRAME_DRAW_CUT_BLOBS_H
#define FULLFRAME_DRAW_CUT_BLOBS_H
#include <stddef.h>
#include "shared_snapshot_arena.h"

@class FFSTPassRecord, NSDictionary, NSData;
@protocol MTLBuffer;
struct ff_draw_cut;
#ifdef __cplusplus
extern "C" {
#endif
/* Return exactly 1 after consuming/copying the borrowed bytes; any other result
 * stops emission and returns 0. Names use the existing capture-file basenames.
 * A failed sink owns discarding its partial output. No callback occurs unless
 * gpu_completed is true; this flag must come from source GPU completion, not
 * from sink acceptance. This routine performs no GPU work or temporary-file IO.
 * The cut/pass and every byte pointer remain borrowed for this call only. */
int fullframe_write_resource_cut_to_sink(struct ff_draw_cut *cut, FFSTPassRecord *pass,
    int gpu_completed, int (*sink)(void *context, const char *name, const void *bytes, size_t length),
    void *context);
/* Opt-in paired typed metadata path. plan_data is set only if all graph blobs
 * were emitted as FFMD1; nil means the ordinary v2 JSON fallback was used. */
#ifndef FF_DRAW_TYPED_API
#define FF_DRAW_TYPED_API
#endif
FF_DRAW_TYPED_API int fullframe_write_resource_cut_typed_to_sink(struct ff_draw_cut *cut, FFSTPassRecord *pass,
    NSDictionary *sidecar, NSData **plan_data, int gpu_completed,
    int (*sink)(void *context, const char *name, const void *bytes, size_t length),void *context);
/* Completed cut-buffer snapshots may pass their dedicated immutable Metal owner
 * to a sink that retains it. All other blobs keep the ordinary borrowed sink. */
FF_DRAW_TYPED_API int fullframe_write_resource_cut_to_owned_sink(struct ff_draw_cut *cut, FFSTPassRecord *pass,
    NSDictionary *sidecar, NSData **plan_data, int gpu_completed,
    int (*sink)(void *context, const char *name, const void *bytes, size_t length),
    int (*snapshot_sink)(void *context, const char *name, id<MTLBuffer> snapshot, size_t length,
        const ffsa_extent_desc *shared_extent),void *context);
/* Existing private, atomic directory writer and partial-resource rollback. */
int fullframe_write_resource_cut(int directory, struct ff_draw_cut *cut,
    FFSTPassRecord *pass, int gpu_completed);
#ifdef __cplusplus
}
#endif
#endif
