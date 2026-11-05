#include "chunk_completion.h"
#include <stdlib.h>
#include <string.h>

typedef struct ffcc_slot {
    ffsc_packet_header packet;
    ffcc_query queries[FFCC_MAX_QUERIES];
    uint64_t values[FFCC_MAX_QUERIES];
    unsigned char seen[FFCC_MAX_QUERIES];
    size_t count, received;
    int used, gpu, complete;
} ffcc_slot;
struct ffcc_registry {
    ffcc_slot slots[FFCC_CAPACITY];
    ffsc_packet_header last;
    size_t count;
    int started, failed;
};

static enum ffcc_result reject(ffcc_registry *registry) {
    if (registry) registry->failed = 1;
    return FFCC_FAILED;
}
static int identity(const ffsc_packet_header *a, const ffsc_packet_header *b) {
    return a->serial == b->serial && a->stream == b->stream &&
        a->frame == b->frame && a->chunk == b->chunk &&
        a->record_digest == b->record_digest && a->queue_completion == b->queue_completion;
}
static ffcc_slot *by_serial(ffcc_registry *registry, uint64_t serial) {
    for (size_t i = 0; i < FFCC_CAPACITY; ++i)
        if (registry->slots[i].used && registry->slots[i].packet.serial == serial)
            return &registry->slots[i];
    return NULL;
}
static const ffcc_slot *by_queue(const ffcc_registry *registry,
                                uint64_t stream, uint64_t completion) {
    for (size_t i = 0; i < FFCC_CAPACITY; ++i)
        if (registry->slots[i].used && registry->slots[i].packet.stream == stream &&
            registry->slots[i].packet.queue_completion == completion)
            return &registry->slots[i];
    return NULL;
}
static int tables_valid(const ffsc_packet_header *h) {
    const uint64_t offsets[] = {0, h->records_offset, h->blobs_offset, h->retirements_offset};
    const uint64_t sizes[] = {sizeof(*h), (uint64_t)h->record_count * sizeof(ffs_record),
        (uint64_t)h->blob_count * sizeof(ffsc_blob_entry),
        (uint64_t)h->retirement_count * sizeof(ffsc_retirement)};
    for (size_t i = 0; i < 4; ++i) {
        if ((offsets[i] & 7) || offsets[i] > h->total_bytes || sizes[i] > h->total_bytes - offsets[i])
            return 0;
        for (size_t j = 0; j < i; ++j)
            if (sizes[i] && sizes[j] && offsets[i] < offsets[j] + sizes[j] &&
                offsets[j] < offsets[i] + sizes[i]) return 0;
    }
    return 1;
}
static int valid_header(const ffsc_packet_header *h) {
    return h->magic == FFSC_PACKET_MAGIC && h->version == FFSC_VERSION &&
        h->bytes == sizeof(*h) && h->total_bytes >= sizeof(*h) &&
        h->total_bytes <= FFSC_MAX_PACKET_BYTES && h->serial && h->stream &&
        h->frame && h->queue_completion && h->first_sequence &&
        h->next_sequence > h->first_sequence && h->record_count &&
        h->record_count <= FFS_MAX_RECORDS &&
        h->record_count == h->next_sequence - h->first_sequence &&
        (h->flags & FFSC_SOURCE_READY) &&
        !(h->flags & ~(FFSC_SOURCE_READY | FFSC_FRAME_BEGIN | FFSC_FRAME_END)) &&
        h->blob_count <= FFSC_MAX_BLOBS && h->retirement_count <= FFSC_MAX_RETIREMENTS &&
        tables_valid(h);
}
static int query_valid(ffcc_query q, const ffsc_packet_header *h) {
    if (q.reserved) return 0;
    if (q.kind == FFSC_TIMESTAMP)
        return q.id == h->chunk && q.index <= 1048576 && q.count &&
            q.count <= 1048576 && !q.value;
    return q.kind == FFSC_EVENT_QUERY && q.id && !q.index && q.count == 1 && q.value;
}
static int query_equal(ffcc_query a, ffcc_query b) {
    return a.kind == b.kind && a.reserved == b.reserved && a.id == b.id &&
        a.index == b.index && a.count == b.count && a.value == b.value;
}

ffcc_registry *ffcc_create(void) { return calloc(1, sizeof(ffcc_registry)); }
void ffcc_destroy(ffcc_registry *registry) { free(registry); }
void ffcc_fail(ffcc_registry *registry) { (void)reject(registry); }

enum ffcc_result ffcc_track(ffcc_registry *registry, const ffsc_packet_header *packet,
                           const ffcc_query *queries, size_t count) {
    if (!registry || registry->failed) return FFCC_FAILED;
    if (!packet || (count && !queries) || count > FFCC_MAX_QUERIES || !valid_header(packet))
        return reject(registry);
    const ffsc_packet_header h = *packet;
    if (!registry->started) {
        if (h.serial != 1 || !(h.flags & FFSC_FRAME_BEGIN)) return reject(registry);
    } else {
        const ffsc_packet_header *last = &registry->last;
        if (last->serial == UINT64_MAX || h.serial != last->serial + 1 ||
            h.stream != last->stream || last->chunk == UINT64_MAX ||
            h.chunk != last->chunk + 1 || h.first_sequence != last->next_sequence ||
            h.queue_completion <= last->queue_completion)
            return reject(registry);
        if (last->flags & FFSC_FRAME_END) {
            if (!(h.flags & FFSC_FRAME_BEGIN) || h.frame <= last->frame) return reject(registry);
        } else if ((h.flags & FFSC_FRAME_BEGIN) || h.frame != last->frame) {
            return reject(registry);
        }
    }
    for (size_t i = 0; i < count; ++i) {
        if (!query_valid(queries[i], &h)) return reject(registry);
        for (size_t j = 0; j < i; ++j) {
            if (queries[i].kind != queries[j].kind || queries[i].id != queries[j].id) continue;
            /* One readback index denotes one coalesced timestamp group. Count
             * is a number of query objects, never an index range. */
            if (queries[i].kind == FFSC_TIMESTAMP && queries[i].index == queries[j].index)
                return reject(registry);
            if (queries[i].kind == FFSC_EVENT_QUERY && queries[i].value <= queries[j].value)
                return reject(registry);
        }
    }
    if (registry->count == FFCC_CAPACITY) return FFCC_BACKPRESSURE;
    ffcc_slot *slot = NULL;
    for (size_t i = 0; i < FFCC_CAPACITY; ++i)
        if (!registry->slots[i].used) { slot = &registry->slots[i]; break; }
    if (!slot) return reject(registry);
    slot->packet = h;
    if (count) memcpy(slot->queries, queries, count * sizeof(*queries));
    slot->count = count;
    slot->used = 1;
    registry->last = h;
    registry->started = 1;
    ++registry->count;
    return FFCC_OK;
}

enum ffcc_result ffcc_accept(ffcc_registry *registry, const ffsc_receipt *receipt) {
    if (!registry || registry->failed) return FFCC_FAILED;
    if (!receipt) return reject(registry);
    const ffsc_receipt r = *receipt;
    if (r.version != FFSC_VERSION || r.status != FFSC_COMPLETED ||
        (r.kind != FFSC_NATIVE_GPU_COMPLETED && r.kind != FFSC_QUERY_READY) ||
        r.root || r.generation || r.offset || r.length)
        return reject(registry);
    ffcc_slot *slot = by_serial(registry, r.serial);
    ffsc_packet_header h = {.serial=r.serial, .stream=r.stream, .frame=r.frame,
        .chunk=r.chunk, .record_digest=r.record_digest, .queue_completion=r.queue_completion};
    if (!slot || !identity(&slot->packet, &h) || slot->complete) return reject(registry);
    if (r.kind == FFSC_NATIVE_GPU_COMPLETED) {
        if (slot->gpu || r.query_kind || r.id || r.index || r.count || r.value)
            return reject(registry);
        slot->gpu = 1;
    } else {
        if (!r.value || (r.query_kind != FFSC_TIMESTAMP && r.query_kind != FFSC_EVENT_QUERY))
            return reject(registry);
        size_t match = slot->count;
        for (size_t i = 0; i < slot->count; ++i) {
            ffcc_query q = slot->queries[i];
            if (q.kind == r.query_kind && q.id == r.id && q.index == r.index && q.count == r.count &&
                (q.kind == FFSC_TIMESTAMP || q.value == r.value)) { match = i; break; }
        }
        if (match == slot->count || slot->seen[match]) return reject(registry);
        slot->seen[match] = 1;
        slot->values[match] = r.value;
        ++slot->received;
    }
    slot->complete = slot->gpu && slot->received == slot->count;
    return slot->complete ? FFCC_READY : FFCC_PENDING;
}

enum ffcc_result ffcc_state(const ffcc_registry *registry, uint64_t stream,
                           uint64_t queue_completion) {
    if (!registry || registry->failed) return FFCC_FAILED;
    const ffcc_slot *slot = by_queue(registry, stream, queue_completion);
    if (!slot) return FFCC_NOT_FOUND;
    return slot->complete ? FFCC_READY : FFCC_PENDING;
}
enum ffcc_result ffcc_lookup(const ffcc_registry *registry, uint64_t stream,
                            uint64_t queue_completion, const ffcc_query *query, uint64_t *value) {
    if (value) *value = 0;
    if (!registry || registry->failed) return FFCC_FAILED;
    const ffcc_slot *slot = by_queue(registry, stream, queue_completion);
    if (!slot || !query) return FFCC_NOT_FOUND;
    for (size_t i = 0; i < slot->count; ++i) {
        if (!query_equal(slot->queries[i], *query)) continue;
        if (!slot->complete) return FFCC_PENDING;
        if (value) *value = slot->values[i];
        return FFCC_READY;
    }
    return FFCC_NOT_FOUND;
}
enum ffcc_result ffcc_copy(const ffcc_registry *registry, uint64_t stream,
                          uint64_t queue_completion, ffsc_receipt *receipts,
                          size_t capacity, size_t *count) {
    if (count) *count = 0;
    if (!registry || registry->failed) return FFCC_FAILED;
    const ffcc_slot *slot = by_queue(registry, stream, queue_completion);
    if (!slot) return FFCC_NOT_FOUND;
    if (!slot->complete) return FFCC_PENDING;
    if (count) *count = slot->count;
    if (capacity < slot->count || (slot->count && !receipts)) return FFCC_BACKPRESSURE;
    for (size_t i = 0; i < slot->count; ++i) {
        ffcc_query q = slot->queries[i];
        const ffsc_packet_header *h = &slot->packet;
        receipts[i] = (ffsc_receipt){.version=FFSC_VERSION,.kind=FFSC_QUERY_READY,.status=FFSC_COMPLETED,
            .query_kind=q.kind,.serial=h->serial,.stream=h->stream,.frame=h->frame,.chunk=h->chunk,
            .record_digest=h->record_digest,.queue_completion=h->queue_completion,
            .id=q.id,.index=q.index,.count=q.count,.value=slot->values[i]};
    }
    return FFCC_READY;
}
enum ffcc_result ffcc_verify(ffcc_registry *registry, const ffsc_packet_header *packet) {
    if (!registry || registry->failed) return FFCC_FAILED;
    if (!packet) return reject(registry);
    ffcc_slot *slot = by_serial(registry, packet->serial);
    if (!slot || !identity(&slot->packet, packet) || !slot->complete) return reject(registry);
    return FFCC_READY;
}
enum ffcc_result ffcc_release(ffcc_registry *registry, const ffsc_packet_header *packet) {
    if (ffcc_verify(registry, packet) != FFCC_READY) return FFCC_FAILED;
    ffcc_slot *slot = by_serial(registry, packet->serial);
    memset(slot, 0, sizeof(*slot));
    --registry->count;
    return FFCC_OK;
}
