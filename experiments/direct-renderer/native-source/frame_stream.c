#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#include "frame_stream.h"
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

typedef struct {
  uint64_t kind, root, generation, version, pending;
  uint32_t next, prev;
} ffs_generation_slot;
_Static_assert(sizeof(ffs_generation_slot)==48, "generation slot accounting");
typedef struct {
  uint64_t kind, root, view, generation, offset, length;
} ffs_view_state;
typedef struct {
  uint64_t domain, id, value;
} ffs_dependency_state;
/* Zero index is null; actual slots are indexed from one. Slots marked free
 * have kind=0 and use next for the free list. */
typedef struct { ffs_view_state value; uint32_t next, prev, generation_next; } ffs_view_slot;
typedef struct {
  uint32_t free_head, next_unused, reserved[2];
  uint32_t buckets[FFS_MAX_VIEWS];
  uint32_t generation_heads[FFS_MAX_GENERATIONS];
  ffs_view_slot slots[FFS_MAX_VIEWS];
} ffs_view_table;
_Static_assert(sizeof(ffs_view_slot)==64, "account every view slot byte");
_Static_assert(FFS_MAX_VIEWS > 0 && FFS_MAX_VIEWS < UINT32_MAX, "view slot indices fit");

struct ffs_collector {
  ffs_summary s;
  ffs_record *records;
  size_t capacity;
  size_t stored_count;
  ffs_generation_slot generations[FFS_MAX_GENERATIONS];
  uint32_t generation_buckets[FFS_MAX_GENERATIONS],dirty[FFS_MAX_GENERATIONS];
  uint32_t generation_next,generation_free,dirty_count;
  ffs_view_table *views;
  size_t view_bytes;
  ffs_dependency_state dependencies[FFS_MAX_DEPENDENCIES];
  size_t resource_count, view_count, dependency_count;
  enum ffs_limit_cause limit;
  uint64_t chunk, chunk_encoders, chunk_commands, expected_encoders;
  uint64_t chunk_dependencies, initializer, completion;
  uint64_t expected_commands, expected_resources, expected_dependencies;
  uint64_t encoder_commands, encoder_resources, encoder_dependencies;
  uint64_t category;
  int begun, in_chunk, in_encoder, ended, unsupported, initializer_seen, completion_seen, encoder_signalled, discarded;
};

static int fail(ffs_collector *c, enum ffs_error e) {
  if (c && c->s.status != FFS_INVALID) { c->s.status = FFS_INVALID; c->s.error = e; }
  return 0;
}

static int fail_limit(ffs_collector *c, enum ffs_limit_cause cause) {
  if (c && c->s.status != FFS_INVALID) c->limit = cause;
  return fail(c, FFS_LIMIT);
}

static uint64_t view_hash(uint64_t kind,uint64_t root,uint64_t view,uint64_t generation) {
#ifdef FFS_TEST_FORCE_VIEW_COLLISIONS
  (void)kind;(void)root;(void)view;(void)generation;return 0;
#else
  uint64_t h=UINT64_C(14695981039346656037), data[]={kind,root,view,generation};
  for(size_t i=0;i<4;i++) { uint64_t x=data[i]; for(unsigned j=0;j<8;j++) {h^=(unsigned char)x;h*=UINT64_C(1099511628211);x>>=8;} }
  return h;
#endif
}
/* Fixed generation index: 48-byte slots, bucket heads and dirty indices are
 * bounded by 448 KiB plus collector controls. No live entry is evicted. */
_Static_assert((sizeof(ffs_generation_slot)+2*sizeof(uint32_t))*FFS_MAX_GENERATIONS <= 448u*1024u,
               "bounded generation index");
static uint64_t generation_hash(uint64_t kind,uint64_t root,uint64_t generation){return view_hash(kind,root,0,generation);}
static uint32_t generation_find(const ffs_collector *c,uint64_t kind,uint64_t root,uint64_t generation){
  uint32_t i=c->generation_buckets[generation_hash(kind,root,generation)%FFS_MAX_GENERATIONS];
  while(i){const ffs_generation_slot *g=&c->generations[i-1];
    if(g->kind==kind&&g->root==root&&g->generation==generation)return i;i=g->next;}
  return 0;
}
static uint32_t generation_insert(ffs_collector *c,uint64_t kind,uint64_t root,uint64_t generation,uint64_t version){
  uint32_t i;if(c->generation_free){i=c->generation_free;c->generation_free=c->generations[i-1].next;}else i=c->generation_next++;
  uint32_t *head=&c->generation_buckets[generation_hash(kind,root,generation)%FFS_MAX_GENERATIONS];
  c->generations[i-1]=(ffs_generation_slot){.kind=kind,.root=root,.generation=generation,.version=version,.next=*head};
  if(*head)c->generations[*head-1].prev=i;*head=i;c->resource_count++;return i;
}
/* Hash chaining gives expected constant-time lookup at <=1 slot per bucket;
 * collisions are bounded by FFS_MAX_VIEWS and require exact key equality.
 * A generation chain retires only its own views, unlinking each in O(1). */
static uint32_t view_find(const ffs_collector *c,uint64_t kind,uint64_t root,uint64_t view,uint64_t generation,uint64_t hash) {
  uint32_t i=c->views->buckets[hash%FFS_MAX_VIEWS];
  while(i) {const ffs_view_slot *slot=&c->views->slots[i-1];const ffs_view_state *v=&slot->value;
    if(v->kind==kind&&v->root==root&&v->view==view&&v->generation==generation)return i;
    i=slot->next;
  }return 0;
}
static void view_insert(ffs_collector *c,ffs_view_state value,uint64_t hash,size_t generation_index) {
  ffs_view_table *t=c->views;uint32_t i;
  if(t->free_head){i=t->free_head;t->free_head=t->slots[i-1].next;}
  else i=t->next_unused++;
  ffs_view_slot *slot=&t->slots[i-1];uint32_t *head=&t->buckets[hash%FFS_MAX_VIEWS];
  *slot=(ffs_view_slot){.value=value,.next=*head,.generation_next=t->generation_heads[generation_index]};
  t->generation_heads[generation_index]=i;
  if(*head)t->slots[*head-1].prev=i;*head=i;c->view_count++;
}
static void view_remove(ffs_collector *c,uint32_t i) {
  ffs_view_table *t=c->views;ffs_view_slot *slot=&t->slots[i-1];
  if(slot->prev)t->slots[slot->prev-1].next=slot->next;
  else {ffs_view_state *v=&slot->value;uint64_t hash=view_hash(v->kind,v->root,v->view,v->generation);
    t->buckets[hash%FFS_MAX_VIEWS]=slot->next;}
  if(slot->next)t->slots[slot->next-1].prev=slot->prev;
  slot->value.kind=0;slot->prev=0;slot->next=t->free_head;t->free_head=i;c->view_count--;
}

ffs_collector *ffs_create(uint64_t stream, uint64_t sequence, size_t maximum) {
  if (!stream || !sequence || !maximum || maximum > FFS_MAX_RECORDS) return NULL;
  ffs_collector *c = calloc(1, sizeof(*c));
  if (!c) return NULL;
  long page = sysconf(_SC_PAGESIZE);
  if (page <= 0 || sizeof(ffs_view_table)>SIZE_MAX-((size_t)page-1)) { free(c);return NULL; }
  size_t size=sizeof(ffs_view_table), p=(size_t)page;
  size_t rounded=((size+p-1)/p)*p;
  /* Charge the mapping and its pointer, byte-count and occupancy fields in
   * the collector. Kernel VM bookkeeping and residency are OS-managed. */
  size_t control=sizeof(c->views)+sizeof(c->view_bytes)+sizeof(c->view_count);
  if (rounded<size || control>FFS_VIEW_BUDGET_BYTES || rounded>FFS_VIEW_BUDGET_BYTES-control) { free(c);return NULL; }
#ifdef FFS_TEST_FAIL_VIEW_MAP
  c->views=MAP_FAILED;
#else
  c->views=mmap(NULL,rounded,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANON,-1,0);
#endif
  if(c->views==MAP_FAILED){free(c);return NULL;}
  c->view_bytes=rounded;
  /* Anonymous mappings are zeroed. Do not dirty untouched slot pages. */
  c->views->next_unused=1;c->generation_next=1;
  c->records = calloc(maximum, sizeof(*c->records));
  if (!c->records) { munmap(c->views,c->view_bytes); free(c); return NULL; }
  c->capacity = maximum;
  c->s.stream = stream;
  c->s.first_sequence = c->s.next_sequence = sequence;
  c->s.digest = UINT64_C(14695981039346656037);
  return c;
}

void ffs_destroy(ffs_collector *c) {
  if (c) { free(c->records); munmap(c->views,c->view_bytes); free(c); }
}

uint64_t ffs_digest(uint64_t prior, const ffs_record *r) {
  const unsigned char *p = (const unsigned char *)r;
  for (size_t i = 0; i < sizeof(*r); i++) { prior ^= p[i]; prior *= UINT64_C(1099511628211); }
  return prior;
}

static int resource(ffs_collector *c, const ffs_record *r) {
  const uint64_t *d = r->data;
  if (d[0] < FFS_BUFFER || d[0] > FFS_QUERY || !d[1] || !d[2] || !d[3] ||
      !d[4] || !(r->flags & (FFS_READ | FFS_WRITE)) || d[5] > UINT64_MAX - d[6] ||
      (d[0] == FFS_BUFFER && !d[6]))
    return fail(c, FFS_IDENTITY);
  uint64_t hash=view_hash(d[0],d[1],d[2],d[3]);
  uint32_t view=view_find(c,d[0],d[1],d[2],d[3],hash);
  if(view) {const ffs_view_state *v=&c->views->slots[view-1].value;
    if(v->offset!=d[5]||v->length!=d[6])return fail(c,FFS_IDENTITY);
  } else if(c->view_count==FFS_MAX_VIEWS) return fail_limit(c,FFS_LIMIT_VIEWS);
  uint32_t gi=generation_find(c,d[0],d[1],d[3]);
  ffs_generation_slot *g=gi?&c->generations[gi-1]:NULL;
  if(g&&g->version!=d[4])return fail(c,FFS_RESOURCE_VERSION);
  if(!g&&c->resource_count==FFS_MAX_GENERATIONS)return fail_limit(c,FFS_LIMIT_GENERATIONS);
  if(r->flags&FFS_WRITE){
    if(d[4]==UINT64_MAX||d[8]!=d[4]+1)return fail(c,FFS_RESOURCE_VERSION);
    if(g&&g->pending&&g->pending!=d[8])return fail(c,FFS_RESOURCE_VERSION);
    if((!g||!g->pending)&&c->dirty_count==FFS_MAX_GENERATIONS)return fail_limit(c,FFS_LIMIT_GENERATIONS);
  }else if(d[8]!=d[4])return fail(c,FFS_RESOURCE_VERSION);
  /* Commit only after all identity, capacity and version checks succeed. */
  if(!gi){gi=generation_insert(c,d[0],d[1],d[3],d[4]);g=&c->generations[gi-1];c->views->generation_heads[gi-1]=0;}
  if(!view)view_insert(c,(ffs_view_state){d[0],d[1],d[2],d[3],d[5],d[6]},hash,gi-1);
  if(r->flags&FFS_WRITE){if(!g->pending)c->dirty[c->dirty_count++]=gi;g->pending=d[8];}
  if (!(r->flags & FFS_PAYLOAD) || !d[7]) c->unsupported = 1;
  c->encoder_resources++;
  c->s.resources++;
  return 1;
}

static int dependency(ffs_collector *c, const ffs_record *r) {
  const uint64_t *d = r->data;
  if (d[0] < FFS_FENCE || d[0] > FFS_EVENT || !d[1] || !d[2] ||
      (d[4] != FFS_WAIT && d[4] != FFS_SIGNAL)) return fail(c, FFS_IDENTITY);
  size_t i;
  for (i = 0; i < c->dependency_count; i++)
    if (c->dependencies[i].domain == d[0] && c->dependencies[i].id == d[1]) break;
  if (d[4] == FFS_WAIT) {
    if (c->in_encoder && (c->encoder_signalled || c->encoder_commands || c->encoder_resources))
      return fail(c, FFS_DEPENDENCY_ERROR);
    if (r->flags & FFS_EXTERNAL) {
      if (!(r->flags & FFS_PAYLOAD) || !d[5]) c->unsupported = 1;
    } else if (i == c->dependency_count || c->dependencies[i].value < d[2])
      return fail(c, FFS_DEPENDENCY_ERROR);
  } else {
    if (c->in_encoder && (c->encoder_commands != c->expected_commands || c->encoder_resources != c->expected_resources))
      return fail(c, FFS_DEPENDENCY_ERROR);
    if (r->flags & FFS_EXTERNAL) return fail(c, FFS_DEPENDENCY_ERROR);
    if (i == c->dependency_count) {
      if (i == FFS_MAX_DEPENDENCIES) return fail_limit(c, FFS_LIMIT_DEPENDENCIES);
      c->dependencies[c->dependency_count++] = (ffs_dependency_state){d[0],d[1],0};
    }
    if (d[2] <= c->dependencies[i].value) return fail(c, FFS_DEPENDENCY_ERROR);
    c->dependencies[i].value = d[2];
    if (c->in_encoder) c->encoder_signalled = 1;
  }
  if (c->in_encoder) c->encoder_dependencies++;
  c->s.dependencies++;
  return 1;
}

int ffs_consume(ffs_collector *c, const ffs_record *r) {
  if (!c || !r) return 0;
  if (c->s.status == FFS_INVALID) return 0;
  if (c->ended) return fail(c, FFS_ORDER);
  if (r->magic != FFS_MAGIC || r->version != FFS_VERSION || r->bytes != sizeof(*r) ||
      r->stream != c->s.stream || r->sequence != c->s.next_sequence ||
      r->flags & ~(FFS_UNSUPPORTED | FFS_EXTERNAL | FFS_READ | FFS_WRITE | FFS_ATTACHMENT | FFS_PAYLOAD))
    return fail(c, FFS_BAD_PACKET);
  if (c->stored_count == c->capacity) return fail_limit(c, FFS_LIMIT_RECORDS);
  if (r->sequence == UINT64_MAX) return fail_limit(c, FFS_LIMIT_SEQUENCE);
  if (c->begun && r->frame != c->s.frame) return fail(c, FFS_ORDER);
  if (c->in_chunk && r->chunk != c->chunk) return fail(c, FFS_ORDER);
  if (c->in_encoder && r->encoder != c->chunk_encoders) return fail(c, FFS_ORDER);
  if (r->flags & FFS_UNSUPPORTED) c->unsupported = 1;
  const uint64_t *d = r->data;
  switch (r->kind) {
  case FFS_FRAME_BEGIN:
    if (c->begun || r->encoder || r->item || r->chunk != d[0]) return fail(c, FFS_ORDER);
    c->begun = 1; c->s.frame = r->frame; c->chunk = r->chunk;
    break;
  case FFS_CHUNK_BEGIN:
    if (!c->begun || c->in_chunk || d[0] != c->s.chunks || d[1] > FFS_MAX_COMMANDS ||
        (c->s.chunks ? r->chunk != c->chunk + 1 : r->chunk != c->chunk)) return fail(c, FFS_ORDER);
    c->chunk = r->chunk; c->in_chunk = 1; c->chunk_encoders = c->chunk_commands = 0;
    c->expected_encoders = d[1];
    c->chunk_dependencies = 0; c->initializer = d[2]; c->completion = d[3];
    c->initializer_seen = !d[2]; c->completion_seen = 0;
    if (!c->completion) return fail(c, FFS_IDENTITY);
    break;
  case FFS_ENCODER_BEGIN:
    if (!c->in_chunk || c->in_encoder || r->encoder != c->chunk_encoders ||
        c->chunk_encoders >= c->expected_encoders || d[0] >= FFS_CATEGORY_COUNT ||
        d[1] > FFS_MAX_COMMANDS || d[2] > FFS_MAX_RESOURCES || d[3] > FFS_MAX_DEPENDENCIES)
      return fail(c, FFS_ORDER);
    if (d[0] == FFS_NULL && (d[1] || d[2] || d[3])) return fail(c, FFS_COUNT);
    c->in_encoder = 1; c->category = d[0]; c->s.category_count[d[0]]++;
    c->expected_commands = d[1]; c->expected_resources = d[2]; c->expected_dependencies = d[3];
    c->encoder_commands = c->encoder_resources = c->encoder_dependencies = 0;
    c->encoder_signalled = 0;
    c->dirty_count=0;
    if (d[0] != FFS_NULL && (!(r->flags & FFS_PAYLOAD) || !d[4])) c->unsupported = 1;
    break;
  case FFS_COMMAND:
    if (!c->in_encoder || c->encoder_signalled || r->item != c->encoder_commands || c->encoder_commands >= c->expected_commands)
      return fail(c, FFS_ORDER);
    if (!(r->flags & FFS_PAYLOAD) || !d[1]) c->unsupported = 1;
    c->encoder_commands++; c->chunk_commands++; c->s.commands++;
    break;
  case FFS_RESOURCE:
    if (!c->in_encoder || c->encoder_signalled || c->encoder_resources >= c->expected_resources) return fail(c, FFS_ORDER);
    if (!resource(c, r)) return 0;
    break;
  case FFS_RESOURCE_UNRESOLVED:
    if (!c->in_encoder || c->encoder_signalled || c->encoder_resources >= c->expected_resources)
      return fail(c, FFS_ORDER);
    c->encoder_resources++; c->s.resources++; c->unsupported = 1;
    break;
  case FFS_DEPENDENCY:
    if (!c->in_chunk || (c->in_encoder && c->encoder_dependencies >= c->expected_dependencies))
      return fail(c, FFS_ORDER);
    if (!c->in_encoder) {
      if (d[0] == FFS_INITIALIZER && d[1] == 1 && d[2] == c->initializer &&
          d[4] == FFS_WAIT && (r->flags & FFS_EXTERNAL) && !c->initializer_seen && !c->chunk_encoders)
        c->initializer_seen = 1;
      else if (d[0] == FFS_QUEUE && d[1] == 1 && d[2] == c->completion &&
          d[4] == FFS_SIGNAL && !c->completion_seen && c->chunk_encoders == c->expected_encoders)
        c->completion_seen = 1;
      else return fail(c, FFS_DEPENDENCY_ERROR);
    }
    if (!dependency(c, r)) return 0;
    c->chunk_dependencies++;
    break;
  case FFS_PRESENT:
    if (!c->in_encoder || c->category != FFS_PRESENT_ENCODER || ++c->s.presents != 1 ||
        !d[0] || !d[1] || !d[2] || !d[3]) return fail(c, FFS_MISSING_PRESENT);
    {
      uint32_t gi=generation_find(c,FFS_TEXTURE,d[0],d[2]);
      if(!gi||c->generations[gi-1].version!=d[3])return fail(c,FFS_RESOURCE_VERSION);
      uint64_t hash=view_hash(FFS_TEXTURE,d[0],d[1],d[2]);
      if (!view_find(c,FFS_TEXTURE,d[0],d[1],d[2],hash)) return fail(c, FFS_IDENTITY);
    }
    break;
  case FFS_ENCODER_END:
    if (!c->in_encoder || d[0] != c->encoder_commands || d[1] != c->encoder_resources ||
        d[2] != c->encoder_dependencies || d[0] != c->expected_commands ||
        d[1] != c->expected_resources || d[2] != c->expected_dependencies) return fail(c, FFS_COUNT);
    for(uint32_t i=0;i<c->dirty_count;i++){ffs_generation_slot *g=&c->generations[c->dirty[i]-1];g->version=g->pending;g->pending=0;}
    c->dirty_count=0;
    c->in_encoder = 0; c->chunk_encoders++; c->s.encoders++;
    break;
  case FFS_CHUNK_END:
    if (!c->in_chunk || c->in_encoder || d[0] != c->chunk_encoders || d[1] != c->chunk_commands ||
        d[0] != c->expected_encoders || d[2] != c->chunk_dependencies || !c->initializer_seen || !c->completion_seen)
      return fail(c, FFS_COUNT);
    c->in_chunk = 0; c->s.chunks++;
    break;
  case FFS_FRAME_END:
    if (!c->begun || c->in_chunk || c->in_encoder || !c->s.chunks || c->s.presents != 1)
      return fail(c, FFS_MISSING_PRESENT);
    if (d[0] != c->s.chunks || d[1] != c->s.encoders || d[2] != c->s.commands ||
        d[3] != c->s.records || d[4] != c->s.digest) return fail(c, FFS_COUNT);
    c->ended = 1; c->s.status = c->unsupported ? FFS_UNSUPPORTED_FRAME : FFS_COMPLETE;
    break;
  case FFS_REJECT: return fail(c, FFS_PRODUCER_REJECT);
  default: return fail(c, FFS_BAD_PACKET);
  }
  c->records[c->stored_count++] = *r;c->s.records++;
  c->s.next_sequence++;
  if (r->kind != FFS_FRAME_END) c->s.digest = ffs_digest(c->s.digest, r);
  return 1;
}

ffs_summary ffs_inspect(const ffs_collector *c) {
  if (c) return c->s;
  ffs_summary s = {0}; s.status = FFS_INVALID; s.error = FFS_BAD_PACKET; return s;
}

ffs_occupancy ffs_inspect_occupancy(const ffs_collector *c) {
  return c ? (ffs_occupancy){c->resource_count,c->view_count,c->dependency_count,
      c->stored_count,c->capacity,c->limit} : (ffs_occupancy){0};
}
size_t ffs_view_storage_bytes(const ffs_collector *c) { return c?c->view_bytes:0; }
const char *ffs_limit_name(enum ffs_limit_cause cause) {
  switch(cause) {
    case FFS_LIMIT_NONE: return "none"; case FFS_LIMIT_RECORDS: return "records";
    case FFS_LIMIT_SEQUENCE: return "sequence"; case FFS_LIMIT_GENERATIONS: return "generations";
    case FFS_LIMIT_VIEWS: return "views"; case FFS_LIMIT_DEPENDENCIES: return "dependencies";
  }
  return "unknown";
}

const ffs_record *ffs_records(const ffs_collector *c, size_t *count) {
  if (count) *count = c ? c->stored_count : 0;
  return c ? c->records : NULL;
}

int ffs_can_replay(const ffs_collector *c, ffs_native_evidence evidence, void *context) {
  if (!c || c->discarded || c->s.status != FFS_COMPLETE || !evidence) return 0;
  for (size_t i = 0; i < c->stored_count; i++) {
    const ffs_record *r = &c->records[i];
    int needs = (r->kind == FFS_ENCODER_BEGIN && r->data[0] != FFS_NULL) ||
        r->kind == FFS_COMMAND || r->kind == FFS_RESOURCE ||
        (r->kind == FFS_DEPENDENCY && (r->flags & FFS_EXTERNAL)) || r->kind == FFS_PRESENT;
    if (needs && !evidence(r, context)) return 0;
  }
  return 1;
}

int ffs_can_replay_chunk(const ffs_collector *c,uint64_t first,ffs_native_evidence evidence,void *context) {
  if(!c||!evidence||c->s.status==FFS_INVALID||c->unsupported||c->in_chunk||c->in_encoder||!c->stored_count)return 0;
  size_t start=0;while(start<c->stored_count&&c->records[start].sequence!=first)start++;
  if(start==c->stored_count)return 0;
  if(start&&c->records[start-1].kind==FFS_FRAME_BEGIN)return 0;
  size_t begin=start;if(c->records[begin].kind==FFS_FRAME_BEGIN)begin++;
  if(begin==c->stored_count||c->records[begin].kind!=FFS_CHUNK_BEGIN)return 0;
  size_t end=c->stored_count-1;if(c->records[end].kind==FFS_FRAME_END){if(!end)return 0;end--;}
  if(end<begin||c->records[end].kind!=FFS_CHUNK_END)return 0;
  for(size_t i=begin+1;i<end;i++)if(c->records[i].kind==FFS_CHUNK_BEGIN||c->records[i].kind==FFS_CHUNK_END||
      c->records[i].kind==FFS_FRAME_BEGIN||c->records[i].kind==FFS_FRAME_END)return 0;
  for(size_t i=start;i<c->stored_count;i++){
    const ffs_record *r=&c->records[i];int needs=(r->kind==FFS_ENCODER_BEGIN&&r->data[0]!=FFS_NULL)||
      r->kind==FFS_COMMAND||r->kind==FFS_RESOURCE||(r->kind==FFS_DEPENDENCY&&(r->flags&FFS_EXTERNAL))||r->kind==FFS_PRESENT;
    if(needs&&!evidence(r,context))return 0;
  }
  return 1;
}
int ffs_discard_consumed_chunks(ffs_collector *c) {
  if(!c||c->s.status==FFS_INVALID||c->in_chunk||c->in_encoder||!c->stored_count)return 0;
  uint32_t last=c->records[c->stored_count-1].kind;if(last!=FFS_CHUNK_END&&last!=FFS_FRAME_END)return 0;
  c->stored_count=0;c->discarded=1;return 1;
}
int ffs_begin_next_frame(ffs_collector *c,uint64_t first) {
  if(!c||!c->ended||c->s.status!=FFS_COMPLETE||c->unsupported||first!=c->s.next_sequence)return 0;
  uint64_t stream=c->s.stream;c->s=(ffs_summary){.stream=stream,.first_sequence=first,.next_sequence=first,
      .digest=UINT64_C(14695981039346656037)};
  c->begun=c->ended=c->in_chunk=c->in_encoder=c->discarded=0;c->stored_count=0;return 1;
}
int ffs_retire_generation(ffs_collector *c,uint64_t kind,uint64_t root,uint64_t generation) {
  if(!c||c->s.status==FFS_INVALID||c->in_chunk||c->in_encoder||!root||!generation||
     (kind!=FFS_BUFFER&&kind!=FFS_TEXTURE))return 0;
  uint32_t i=generation_find(c,kind,root,generation);if(!i)return 1;
  ffs_generation_slot *g=&c->generations[i-1];uint32_t view=c->views->generation_heads[i-1];
  while(view){uint32_t next=c->views->slots[view-1].generation_next;view_remove(c,view);view=next;}
  c->views->generation_heads[i-1]=0;
  if(g->prev)c->generations[g->prev-1].next=g->next;
  else c->generation_buckets[generation_hash(kind,root,generation)%FFS_MAX_GENERATIONS]=g->next;
  if(g->next)c->generations[g->next-1].prev=g->prev;
  *g=(ffs_generation_slot){.next=c->generation_free};c->generation_free=i;c->resource_count--;return 1;
}

const char *ffs_status_name(enum ffs_status s) {
  switch (s) {
  case FFS_INCOMPLETE: return "incomplete";
  case FFS_UNSUPPORTED_FRAME: return "unsupported";
  case FFS_COMPLETE: return "complete";
  case FFS_INVALID: return "invalid";
  }
  return "invalid";
}
