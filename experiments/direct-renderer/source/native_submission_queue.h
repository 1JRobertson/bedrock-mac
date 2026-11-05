/* Ordered GPU-submission ownership. Callbacks may complete on arbitrary threads.
 * The sole owner reserves and takes; completion callbacks only mark a ticket.
 * Neither a ticket nor its retained payload may be reused until take returns it. */
#ifndef BEDROCK_NATIVE_SUBMISSION_QUEUE_H
#define BEDROCK_NATIVE_SUBMISSION_QUEUE_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct ffns_queue ffns_queue;
typedef struct { uint64_t serial, bytes; void *payload; bool success; } ffns_retired;
/* Capacity and byte limit bound *all* reserved and completed-but-unretired work. */
ffns_queue *ffns_create(size_t capacity, uint64_t byte_limit);
/* Caller owns payload. A successful reservation transfers it to the queue until take.
 * Serials must be strictly consecutive starting at 1; failures do not consume one. */
bool ffns_reserve(ffns_queue *, uint64_t serial, uint64_t bytes, void *payload);
/* Called exactly once after GPU completion AND all dependent import retirements.
 * Returns false for unknown/already completed tickets, including stale callbacks. */
bool ffns_complete(ffns_queue *, uint64_t serial, bool success);
/* Returns only the next completed ticket in submission order. The caller now owns
 * payload and must publish results/release resources even if success is false. */
bool ffns_take(ffns_queue *, ffns_retired *);
/* Stops reservations; existing callbacks and takes remain valid. */
void ffns_close(ffns_queue *);
/* True only when no callback can legitimately still own a ticket. */
bool ffns_drained(ffns_queue *);
/* Caller must first close, drain, and join every callback that can access queue. */
void ffns_destroy(ffns_queue *);
#endif
