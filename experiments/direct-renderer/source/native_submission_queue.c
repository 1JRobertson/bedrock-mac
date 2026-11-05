#include "native_submission_queue.h"
#include <pthread.h>
#include <stdlib.h>
#include <stdint.h>

typedef struct { uint64_t serial, bytes; void *payload; bool complete, success; } slot;
struct ffns_queue { pthread_mutex_t lock; slot *slots; size_t capacity, head, count;
    uint64_t limit, bytes, next; bool closed; };
ffns_queue *ffns_create(size_t capacity, uint64_t limit) {
    if (!capacity || !limit || capacity > SIZE_MAX / sizeof(slot)) return NULL;
    ffns_queue *q=calloc(1,sizeof(*q)); if (!q) return NULL;
    q->slots=calloc(capacity,sizeof(slot));
    if (!q->slots) { free(q); return NULL; }
    if (pthread_mutex_init(&q->lock,NULL)) { free(q->slots); free(q); return NULL; }
    q->capacity=capacity; q->limit=limit; q->next=1; return q;
}
bool ffns_reserve(ffns_queue *q, uint64_t serial, uint64_t bytes, void *payload) {
    if (!q || !payload) return false;
    pthread_mutex_lock(&q->lock);
    bool ok=!q->closed && q->next && serial==q->next && q->count<q->capacity && bytes<=q->limit-q->bytes;
    if (ok) { size_t i=(q->head+q->count)%q->capacity;
        q->slots[i]=(slot){.serial=serial,.bytes=bytes,.payload=payload};
        ++q->count; q->bytes+=bytes; ++q->next; }
    pthread_mutex_unlock(&q->lock); return ok;
}
bool ffns_complete(ffns_queue *q, uint64_t serial, bool success) {
    if (!q || !serial) return false;
    pthread_mutex_lock(&q->lock); bool ok=false;
    for (size_t n=0;n<q->count;++n) { slot *s=&q->slots[(q->head+n)%q->capacity];
        if (s->serial==serial) { if (!s->complete) { s->success=success; s->complete=true; ok=true; } break; } }
    pthread_mutex_unlock(&q->lock); return ok;
}
bool ffns_take(ffns_queue *q, ffns_retired *out) {
    if (!q || !out) return false;
    pthread_mutex_lock(&q->lock); bool ok=q->count && q->slots[q->head].complete;
    if (ok) { slot *s=&q->slots[q->head]; *out=(ffns_retired){s->serial,s->bytes,s->payload,s->success};
        q->bytes-=s->bytes; *s=(slot){0}; q->head=(q->head+1)%q->capacity; --q->count; }
    pthread_mutex_unlock(&q->lock); return ok;
}
void ffns_close(ffns_queue *q) { if (!q) return; pthread_mutex_lock(&q->lock); q->closed=true; pthread_mutex_unlock(&q->lock); }
bool ffns_drained(ffns_queue *q) { if (!q) return false; pthread_mutex_lock(&q->lock); bool result=q->closed && !q->count; pthread_mutex_unlock(&q->lock); return result; }
void ffns_destroy(ffns_queue *q) { if (!q) return; pthread_mutex_destroy(&q->lock); free(q->slots); free(q); }
