#include "persistent_resource_source.h"
#include <stdlib.h>

typedef struct { uint64_t object,generation,length; int live; } record;
struct FFPSSource { FFPSEmit emit; void *context; record *records; size_t count,capacity; };
FFPSSource *ffps_create(FFPSEmit emit,void *context) {
    if (!emit) return NULL;
    FFPSSource *s=calloc(1,sizeof(*s)); if(s){s->emit=emit;s->context=context;} return s;
}
void ffps_free(FFPSSource *s){if(s){free(s->records);free(s);}}
static record *find(FFPSSource *s,uint64_t object) {
    if(!s || !object)return NULL;
    for(size_t i=0;i<s->count;i++)if(s->records[i].object==object)return &s->records[i];
    return NULL;
}
static record *live(FFPSSource *s,FFPSHandle h) {
    record *r=find(s,h.object); return r && r->live && h.generation && r->generation==h.generation?r:NULL;
}
static int bounds(record *r,uint64_t offset,uint64_t length){return r && length && offset<=r->length && length<=r->length-offset;}
int ffps_buffer_create(FFPSSource *s,FFPSHandle h,uint64_t length) {
    if(!s||!h.object||!h.generation||!length)return 0;
    record *r=find(s,h.object); if(r && (r->live || h.generation<=r->generation))return 0;
    if(!r && s->count==s->capacity){
        size_t capacity=s->capacity?s->capacity*2:64;
        if(capacity<s->capacity || capacity>SIZE_MAX/sizeof(record))return 0;
        record *p=realloc(s->records,capacity*sizeof(record));if(!p)return 0;s->records=p;s->capacity=capacity;
    }
    FFPSEvent event={.operation=FFPS_CREATE,.target=h,.length=length};
    if(s->emit(s->context,&event)!=1)return 0;
    if(!r)r=&s->records[s->count++];
    *r=(record){h.object,h.generation,length,1};return 1;
}
int ffps_buffer_write(FFPSSource *s,FFPSHandle h,uint64_t offset,const void *bytes,size_t length) {
    if(!bytes||!bounds(live(s,h),offset,length))return 0;
    /* The caller guarantees bytes remain stable until this synchronous sink returns. */
    FFPSEvent event={.operation=FFPS_WRITE,.target=h,.offset=offset,.length=length,.bytes=bytes};
    return s->emit(s->context,&event)==1;
}
int ffps_buffer_copy(FFPSSource *s,FFPSHandle from,uint64_t from_offset,FFPSHandle to,uint64_t to_offset,uint64_t length) {
    if(!bounds(live(s,from),from_offset,length)||!bounds(live(s,to),to_offset,length))return 0;
    if(from.object==to.object && from.generation==to.generation && from_offset<to_offset+length && to_offset<from_offset+length)return 0;
    FFPSEvent event={.operation=FFPS_COPY,.target=to,.source=from,.offset=to_offset,.source_offset=from_offset,.length=length};
    return s->emit(s->context,&event)==1;
}
int ffps_buffer_destroy(FFPSSource *s,FFPSHandle h) {
    record *r=live(s,h);if(!r)return 0;
    FFPSEvent event={.operation=FFPS_DESTROY,.target=h};
    if(s->emit(s->context,&event)!=1)return 0;r->live=0;return 1;
}
