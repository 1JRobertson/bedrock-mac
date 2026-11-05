#define _POSIX_C_SOURCE 200809L
#include "readback_stream.h"
#include <errno.h>
#include <limits.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define FFRB_MAPPING_MAGIC UINT64_C(0x4244524253483031)
#define CONTROL_BYTES 4096u
#define MAX_SLOTS 2u
typedef struct { _Atomic uint64_t value; unsigned char pad[120]; } lane;
typedef struct {
    uint64_t magic;
    uint32_t version,bytes,slots,data_bytes;
    uint64_t stride,mapping_bytes;
    unsigned char reserved[88];
    lane native_pid,source_pid,stopped,write,read;
} shared;
_Static_assert(sizeof(lane)==128 && sizeof(shared)<=CONTROL_BYTES,"bounded readback control");
struct ffrb_endpoint {
    shared *shared;
    size_t mapping_bytes;
    enum ffrb_role role;
    pid_t owner;
    uint32_t slots,data_bytes;
    uint64_t stride;
    uint64_t cursor;
    int peeked;
};

uint64_t ffrb_digest(const void *bytes,size_t length) {
    if(!bytes&&length)return 0;
    uint64_t digest=UINT64_C(14695981039346656037);
    const unsigned char *p=bytes;
    for(size_t i=0;i<length;i++){digest^=p[i];digest*=UINT64_C(1099511628211);}
    return digest;
}
static uint64_t stride_for(uint32_t bytes) {
    return ((uint64_t)sizeof(ffrb_record)+bytes+127u)&~UINT64_C(127);
}
static int private_file(int fd,struct stat *s) {
    return !fstat(fd,s)&&S_ISREG(s->st_mode)&&s->st_uid==getuid()&&
        (s->st_mode&07777)==0600&&s->st_nlink==1;
}
static int zero(const unsigned char *bytes,size_t count) {
    for(size_t i=0;i<count;i++)if(bytes[i])return 0;
    return 1;
}
static int shape(const ffrb_record *r,uint64_t length) {
    if(!r->serial||!r->stream||!r->frame||!r->queue_completion||!r->root||
       !r->generation||!r->content_version||!r->row_length||!r->row_count||
       r->row_bytes<r->row_length||r->row_length>UINT64_MAX/r->row_count||
       r->row_length*r->row_count!=length)return 0;
    uint64_t last=r->row_count-1;
    if(last&&r->row_bytes>UINT64_MAX/last)return 0;
    uint64_t extent=last*r->row_bytes;
    if(extent>UINT64_MAX-r->row_length)return 0;
    extent+=r->row_length;
    return r->offset<=UINT64_MAX-extent;
}
enum ffrb_result ffrb_create(int fd,uint32_t slots,uint32_t dataBytes) {
    struct stat st;
    if(!private_file(fd,&st)||st.st_size||!slots||slots>MAX_SLOTS||
       dataBytes<4096||dataBytes>FFRB_MAX_BYTES)return FFRB_INVALID;
    uint64_t stride=stride_for(dataBytes);
    size_t bytes=CONTROL_BYTES+(size_t)slots*(size_t)stride;
    if(ftruncate(fd,(off_t)bytes))return FFRB_INVALID;
    shared *s=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(s==MAP_FAILED)return FFRB_INVALID;
    memset(s,0,CONTROL_BYTES);
    s->version=FFRB_VERSION;s->bytes=CONTROL_BYTES;s->slots=slots;s->data_bytes=dataBytes;
    s->stride=stride;s->mapping_bytes=bytes;
    atomic_init(&s->native_pid.value,0);atomic_init(&s->source_pid.value,0);
    atomic_init(&s->stopped.value,0);atomic_init(&s->write.value,0);atomic_init(&s->read.value,0);
    int ok=atomic_is_lock_free(&s->write.value);
    atomic_thread_fence(memory_order_release);s->magic=FFRB_MAPPING_MAGIC;
    if(msync(s,CONTROL_BYTES,MS_SYNC))ok=0;
    munmap(s,bytes);
    return ok?FFRB_OK:FFRB_INVALID;
}
enum ffrb_result ffrb_attach(int fd,enum ffrb_role role,ffrb_endpoint **out) {
    if(out)*out=NULL;
    struct stat st;
    if(!out||(role!=FFRB_NATIVE&&role!=FFRB_SOURCE)||!private_file(fd,&st)||
       st.st_size<CONTROL_BYTES||
       st.st_size>(off_t)(CONTROL_BYTES+MAX_SLOTS*stride_for(FFRB_MAX_BYTES)))return FFRB_INVALID;
    size_t bytes=(size_t)st.st_size;
    shared *s=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(s==MAP_FAILED)return FFRB_INVALID;
    if(s->magic!=FFRB_MAPPING_MAGIC||s->version!=FFRB_VERSION||s->bytes!=CONTROL_BYTES||
       !s->slots||s->slots>MAX_SLOTS||s->data_bytes<4096||s->data_bytes>FFRB_MAX_BYTES||
       s->stride!=stride_for(s->data_bytes)||s->mapping_bytes!=bytes||
       bytes!=CONTROL_BYTES+(uint64_t)s->slots*s->stride||
       !zero(s->reserved,sizeof(s->reserved))||!atomic_is_lock_free(&s->write.value)){
        munmap(s,bytes);return FFRB_INVALID;
    }
    ffrb_endpoint *e=calloc(1,sizeof(*e));
    if(!e){munmap(s,bytes);return FFRB_INVALID;}
    uint64_t expected=0;
    _Atomic uint64_t *pid=role==FFRB_NATIVE?&s->native_pid.value:&s->source_pid.value;
    if(!atomic_compare_exchange_strong_explicit(pid,&expected,(uint64_t)getpid(),memory_order_acq_rel,memory_order_acquire)){
        free(e);munmap(s,bytes);return FFRB_ORDER;
    }
    e->shared=s;e->mapping_bytes=bytes;e->role=role;e->owner=getpid();
    e->slots=s->slots;e->data_bytes=s->data_bytes;e->stride=s->stride;*out=e;
    return FFRB_OK;
}
static enum ffrb_result alive(ffrb_endpoint *e) {
    if(!e||e->owner!=getpid())return FFRB_INVALID;
    shared *s=e->shared;
    if(atomic_load_explicit(&s->stopped.value,memory_order_acquire))return FFRB_CLOSED;
    uint64_t pid=atomic_load_explicit(e->role==FFRB_NATIVE?&s->source_pid.value:&s->native_pid.value,memory_order_acquire);
    if(pid>INT_MAX)return FFRB_INVALID;
    if(pid&&kill((pid_t)pid,0)&&errno==ESRCH)return FFRB_PEER_DEAD;
    return FFRB_OK;
}
void ffrb_stop(ffrb_endpoint *e) {
    if(e&&e->owner==getpid())atomic_store_explicit(&e->shared->stopped.value,1,memory_order_release);
}
void ffrb_destroy(ffrb_endpoint *e) {
    if(e){ffrb_stop(e);munmap(e->shared,e->mapping_bytes);free(e);}
}
static unsigned char *slot(ffrb_endpoint *e,uint64_t cursor) {
    return (unsigned char *)e->shared+CONTROL_BYTES+(cursor%e->slots)*e->stride;
}
enum ffrb_result ffrb_publish(ffrb_endpoint *e,const ffrb_record *metadata,const void *data,size_t length) {
    enum ffrb_result result=alive(e);if(result!=FFRB_OK)return result;
    if(e->role!=FFRB_NATIVE||!metadata||!data||!length)return FFRB_INVALID;
    if(length>FFRB_MAX_BYTES||length>e->data_bytes)return FFRB_TOO_LARGE;
    ffrb_record r=*metadata;
    if(r.magic||r.version||r.bytes||r.reserved||r.sequence||r.length||r.data_digest||r.reserved64||
       !shape(&r,length))return FFRB_INVALID;
    if(e->cursor==UINT64_MAX)return FFRB_ORDER;
    uint64_t read=atomic_load_explicit(&e->shared->read.value,memory_order_acquire);
    if(read>e->cursor)return FFRB_INVALID;
    if(e->cursor-read>=e->slots)return FFRB_BACKPRESSURE;
    r.magic=FFRB_MAGIC;r.version=FFRB_VERSION;r.bytes=sizeof(r);r.sequence=e->cursor+1;r.length=length;
    r.data_digest=ffrb_digest(data,length);
    unsigned char *destination=slot(e,e->cursor);
    memcpy(destination+sizeof(r),data,length);memcpy(destination,&r,sizeof(r));
    e->cursor++;
    atomic_store_explicit(&e->shared->write.value,e->cursor,memory_order_release);
    return FFRB_OK;
}
enum ffrb_result ffrb_peek(ffrb_endpoint *e,ffrb_record *metadata,const void **data,size_t *length) {
    if(metadata)memset(metadata,0,sizeof(*metadata));
    if(data)*data=NULL;if(length)*length=0;
    enum ffrb_result result=alive(e);if(result!=FFRB_OK)return result;
    if(e->role!=FFRB_SOURCE||!metadata||!data||!length)return FFRB_INVALID;
    e->peeked=0;
    uint64_t write=atomic_load_explicit(&e->shared->write.value,memory_order_acquire);
    if(write==e->cursor)return FFRB_EMPTY;
    if(write<e->cursor||write-e->cursor>e->slots||e->cursor==UINT64_MAX)return FFRB_INVALID;
    const unsigned char *source=slot(e,e->cursor);
    ffrb_record r;memcpy(&r,source,sizeof(r));
    if(r.magic!=FFRB_MAGIC||r.version!=FFRB_VERSION||r.bytes!=sizeof(r)||r.reserved||r.reserved64||
       r.sequence!=e->cursor+1||!r.length||r.length>e->data_bytes||r.length>FFRB_MAX_BYTES||
       !shape(&r,r.length)||ffrb_digest(source+sizeof(r),(size_t)r.length)!=r.data_digest)return FFRB_INVALID;
    *metadata=r;*data=source+sizeof(r);*length=(size_t)r.length;e->peeked=1;
    return FFRB_OK;
}
enum ffrb_result ffrb_consume(ffrb_endpoint *e,uint64_t sequence) {
    enum ffrb_result result=alive(e);if(result!=FFRB_OK)return result;
    if(e->role!=FFRB_SOURCE)return FFRB_INVALID;
    if(!e->peeked||e->cursor==UINT64_MAX||sequence!=e->cursor+1)return FFRB_ORDER;
    e->cursor++;e->peeked=0;
    atomic_store_explicit(&e->shared->read.value,e->cursor,memory_order_release);
    return FFRB_OK;
}
enum ffrb_result ffrb_wait(ffrb_endpoint *e,uint32_t milliseconds) {
    if(!e||milliseconds>1000)return FFRB_INVALID;
    struct timespec start,now;if(clock_gettime(CLOCK_MONOTONIC,&start))return FFRB_INVALID;
    for(;;){
        enum ffrb_result result=alive(e);if(result!=FFRB_OK)return result;
        shared *s=e->shared;
        uint64_t peer=atomic_load_explicit(e->role==FFRB_NATIVE?&s->read.value:&s->write.value,memory_order_acquire);
        if(e->role==FFRB_NATIVE){
            if(peer>e->cursor)return FFRB_INVALID;
            if(e->cursor-peer<e->slots)return FFRB_OK;
        }else{
            if(peer<e->cursor||peer-e->cursor>e->slots)return FFRB_INVALID;
            if(peer>e->cursor)return FFRB_OK;
        }
        if(clock_gettime(CLOCK_MONOTONIC,&now))return FFRB_INVALID;
        int64_t elapsed=(int64_t)(now.tv_sec-start.tv_sec)*INT64_C(1000000000)+now.tv_nsec-start.tv_nsec;
        if(elapsed>=(int64_t)milliseconds*1000000)return FFRB_EMPTY;
        struct timespec delay={0,1000000};while(nanosleep(&delay,&delay)&&errno==EINTR){}
    }
}
