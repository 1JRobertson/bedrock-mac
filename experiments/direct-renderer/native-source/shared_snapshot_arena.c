#include "shared_snapshot_arena.h"
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define FFSA_MAGIC UINT64_C(0x31414e4552415346) /* "FSARENA1" */
#define FFSA_VERSION 1u
enum { SLOT_FREE=0, SLOT_CLAIMED=1, SLOT_SEALED=2, SLOT_ACQUIRED=3 };

typedef struct {
    _Atomic uint32_t state;
    uint32_t reserved;
    _Atomic uint64_t generation;
    _Atomic uint64_t serial;
    _Atomic uint64_t used;
} ffsa_shared_slot;

typedef struct {
    uint64_t magic;
    uint32_t version,slot_count;
    uint64_t slot_bytes,total_bytes;
    _Atomic uint64_t source_pid,native_pid;
    _Atomic uint32_t stopped;
    uint32_t reserved;
    ffsa_shared_slot slots[FFSA_SLOT_COUNT];
} ffsa_control;

_Static_assert(sizeof(ffsa_control)<=FFSA_ALIGNMENT,"arena control fits one aligned page");
_Static_assert(_Alignof(ffsa_shared_slot)>=8,"shared slot atomics are aligned");

struct ffsa_endpoint {
    void *mapping;
    size_t mapping_bytes;
    ffsa_control *control;
    ffsa_role role;
    pid_t pid;
    pthread_mutex_t local_lock;
    uint64_t native_generation[FFSA_SLOT_COUNT];
    uint32_t native_pins[FFSA_SLOT_COUNT];
    uint8_t native_submitted[FFSA_SLOT_COUNT];
    uint8_t native_gpu_done[FFSA_SLOT_COUNT];
};

static int private_file(int fd,struct stat *state) {
    return fd>=0&&!fstat(fd,state)&&S_ISREG(state->st_mode)&&
        state->st_uid==getuid()&&state->st_nlink==1&&
        (state->st_mode&0777)==0600&&(fcntl(fd,F_GETFL)&O_ACCMODE)==O_RDWR;
}

static int valid_slot_bytes(uint64_t bytes) {
    return bytes>=FFSA_ALIGNMENT&&bytes<=FFSA_MAX_SLOT_BYTES&&
        bytes%FFSA_ALIGNMENT==0;
}

static int atomics_lock_free(ffsa_control *control) {
    return atomic_is_lock_free(&control->stopped)&&
        atomic_is_lock_free(&control->source_pid)&&
        atomic_is_lock_free(&control->native_pid)&&
        atomic_is_lock_free(&control->slots[0].state)&&
        atomic_is_lock_free(&control->slots[0].generation);
}

static uint8_t *slot_base(ffsa_endpoint *endpoint,uint32_t slot) {
    return (uint8_t *)endpoint->mapping+FFSA_ALIGNMENT+
        (size_t)slot*(size_t)endpoint->control->slot_bytes;
}

static ffsa_result health(ffsa_endpoint *endpoint) {
    if(!endpoint||endpoint->pid!=getpid())return FFSA_INVALID;
    ffsa_control *control=endpoint->control;
    if(atomic_load_explicit(&control->stopped,memory_order_acquire))return FFSA_STOPPED;
    _Atomic uint64_t *peer=endpoint->role==FFSA_SOURCE?&control->native_pid:&control->source_pid;
    uint64_t pid=atomic_load_explicit(peer,memory_order_acquire);
    if(pid&&kill((pid_t)pid,0)&&errno==ESRCH){
        atomic_store_explicit(&control->stopped,1,memory_order_release);
        return FFSA_PEER_DEAD;
    }
    return FFSA_OK;
}

/* Retiring an existing native lease must remain possible after terminal stop.
 * The stopped bit still prevents every new source claim or native acquire. */
static ffsa_result native_retirement_health(ffsa_endpoint *endpoint) {
    ffsa_result result=health(endpoint);
    return result==FFSA_STOPPED||result==FFSA_PEER_DEAD?FFSA_OK:result;
}

static int lease_matches(ffsa_endpoint *endpoint,ffsa_lease lease,uint32_t state) {
    if(lease.slot>=FFSA_SLOT_COUNT||lease.reserved||!lease.generation||!lease.serial)return 0;
    ffsa_shared_slot *slot=&endpoint->control->slots[lease.slot];
    return atomic_load_explicit(&slot->state,memory_order_acquire)==state&&
        atomic_load_explicit(&slot->generation,memory_order_acquire)==lease.generation&&
        atomic_load_explicit(&slot->serial,memory_order_acquire)==lease.serial;
}

ffsa_result ffsa_create(int fd,uint64_t slot_bytes) {
    struct stat state;
    if(!private_file(fd,&state)||state.st_size!=0||!valid_slot_bytes(slot_bytes))return FFSA_INVALID;
    uint64_t total=FFSA_ALIGNMENT+FFSA_SLOT_COUNT*slot_bytes;
    if(ftruncate(fd,(off_t)total))return FFSA_INVALID;
    void *mapping=mmap(NULL,FFSA_ALIGNMENT,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(mapping==MAP_FAILED)return FFSA_INVALID;
    memset(mapping,0,FFSA_ALIGNMENT);
    ffsa_control *control=mapping;
    control->version=FFSA_VERSION;control->slot_count=FFSA_SLOT_COUNT;
    control->slot_bytes=slot_bytes;control->total_bytes=total;
    if(!atomics_lock_free(control)){munmap(mapping,FFSA_ALIGNMENT);return FFSA_INVALID;}
    control->magic=FFSA_MAGIC;
    int ok=!msync(mapping,FFSA_ALIGNMENT,MS_SYNC)&&!fsync(fd);
    munmap(mapping,FFSA_ALIGNMENT);
    return ok?FFSA_OK:FFSA_INVALID;
}

ffsa_result ffsa_attach(int fd,ffsa_role role,ffsa_endpoint **out) {
    if(out)*out=NULL;
    struct stat state;
    if(!out||(role!=FFSA_SOURCE&&role!=FFSA_NATIVE)||!private_file(fd,&state)||
       state.st_size<(off_t)(FFSA_ALIGNMENT+FFSA_SLOT_COUNT*FFSA_ALIGNMENT)||
       state.st_size>(off_t)(FFSA_ALIGNMENT+FFSA_SLOT_COUNT*FFSA_MAX_SLOT_BYTES))return FFSA_INVALID;
    void *mapping=mmap(NULL,(size_t)state.st_size,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);
    if(mapping==MAP_FAILED)return FFSA_INVALID;
    ffsa_control *control=mapping;
    if(control->magic!=FFSA_MAGIC||control->version!=FFSA_VERSION||
       control->slot_count!=FFSA_SLOT_COUNT||!valid_slot_bytes(control->slot_bytes)||
       control->total_bytes!=(uint64_t)state.st_size||
       control->total_bytes!=FFSA_ALIGNMENT+FFSA_SLOT_COUNT*control->slot_bytes||
       !atomics_lock_free(control)){
        munmap(mapping,(size_t)state.st_size);return FFSA_INVALID;
    }
    if(atomic_load_explicit(&control->stopped,memory_order_acquire)){
        munmap(mapping,(size_t)state.st_size);return FFSA_STOPPED;
    }
    _Atomic uint64_t *mine=role==FFSA_SOURCE?&control->source_pid:&control->native_pid;
    _Atomic uint64_t *peer=role==FFSA_SOURCE?&control->native_pid:&control->source_pid;
    uint64_t expected=0,pid=(uint64_t)getpid();
    if(atomic_load_explicit(peer,memory_order_acquire)==pid||
       !atomic_compare_exchange_strong_explicit(mine,&expected,pid,memory_order_acq_rel,memory_order_acquire)){
        munmap(mapping,(size_t)state.st_size);return FFSA_ORDER;
    }
    ffsa_endpoint *endpoint=calloc(1,sizeof(*endpoint));
    if(!endpoint||pthread_mutex_init(&endpoint->local_lock,NULL)){
        atomic_store_explicit(&control->stopped,1,memory_order_release);
        free(endpoint);munmap(mapping,(size_t)state.st_size);return FFSA_INVALID;
    }
    endpoint->mapping=mapping;endpoint->mapping_bytes=(size_t)state.st_size;
    endpoint->control=control;endpoint->role=role;endpoint->pid=getpid();
    *out=endpoint;return FFSA_OK;
}

ffsa_result ffsa_claim(ffsa_endpoint *source,uint64_t serial,ffsa_lease *out) {
    if(out)memset(out,0,sizeof(*out));
    if(!source||source->role!=FFSA_SOURCE||!serial||!out)return FFSA_INVALID;
    pthread_mutex_lock(&source->local_lock);
    ffsa_result check=health(source);
    if(check!=FFSA_OK){pthread_mutex_unlock(&source->local_lock);return check;}
    for(uint32_t i=0;i<FFSA_SLOT_COUNT;++i){
        ffsa_shared_slot *slot=&source->control->slots[i];
        if(atomic_load_explicit(&slot->state,memory_order_acquire)!=SLOT_FREE&&
           atomic_load_explicit(&slot->serial,memory_order_acquire)==serial){
            pthread_mutex_unlock(&source->local_lock);return FFSA_ORDER;
        }
    }
    for(uint32_t i=0;i<FFSA_SLOT_COUNT;++i){
        ffsa_shared_slot *slot=&source->control->slots[i];uint32_t expected=SLOT_FREE;
        if(!atomic_compare_exchange_strong_explicit(&slot->state,&expected,SLOT_CLAIMED,
            memory_order_acq_rel,memory_order_acquire))continue;
        uint64_t previous=atomic_load_explicit(&slot->generation,memory_order_acquire);
        if(previous==UINT64_MAX){ffsa_stop(source);pthread_mutex_unlock(&source->local_lock);return FFSA_STOPPED;}
        uint64_t generation=previous+1;
        atomic_store_explicit(&slot->serial,serial,memory_order_relaxed);
        atomic_store_explicit(&slot->used,0,memory_order_relaxed);
        atomic_store_explicit(&slot->generation,generation,memory_order_release);
        *out=(ffsa_lease){.slot=i,.generation=generation,.serial=serial};
        pthread_mutex_unlock(&source->local_lock);
        return FFSA_OK;
    }
    pthread_mutex_unlock(&source->local_lock);
    return FFSA_BACKPRESSURE;
}

ffsa_result ffsa_allocate(ffsa_endpoint *source,ffsa_lease lease,uint64_t length,
    ffsa_extent_desc *out,void **bytes) {
    if(out)memset(out,0,sizeof(*out));if(bytes)*bytes=NULL;
    if(!source||source->role!=FFSA_SOURCE||!out||!bytes||!length||
       length>source->control->slot_bytes)return FFSA_INVALID;
    pthread_mutex_lock(&source->local_lock);
    ffsa_result result=health(source);
    if(result==FFSA_OK&&!lease_matches(source,lease,SLOT_CLAIMED))result=FFSA_ORDER;
    uint64_t rounded=0,used=0;
    if(result==FFSA_OK){
        rounded=(length+FFSA_ALIGNMENT-1)&~((uint64_t)FFSA_ALIGNMENT-1);
        ffsa_shared_slot *slot=&source->control->slots[lease.slot];
        used=atomic_load_explicit(&slot->used,memory_order_relaxed);
        if(used>source->control->slot_bytes)result=FFSA_INVALID;
        else if(rounded>source->control->slot_bytes-used)result=FFSA_BACKPRESSURE;
        else{
            atomic_store_explicit(&slot->used,used+rounded,memory_order_relaxed);
            *out=(ffsa_extent_desc){.lease=lease,.offset=used,.length=length,
                .allocated_length=rounded};
            *bytes=slot_base(source,lease.slot)+(size_t)used;
            /* Metal wraps the rounded region; never expose stale padding from
             * an older generation beyond this snapshot's logical length. */
            memset((uint8_t *)*bytes+(size_t)length,0,(size_t)(rounded-length));
        }
    }
    pthread_mutex_unlock(&source->local_lock);return result;
}

ffsa_result ffsa_source_abandon(ffsa_endpoint *source,ffsa_lease lease) {
    if(!source||source->role!=FFSA_SOURCE)return FFSA_INVALID;
    pthread_mutex_lock(&source->local_lock);
    ffsa_result result=health(source);
    if(result==FFSA_OK&&!lease_matches(source,lease,SLOT_CLAIMED))result=FFSA_ORDER;
    if(result==FFSA_OK){
        ffsa_shared_slot *slot=&source->control->slots[lease.slot];
        uint64_t used=atomic_load_explicit(&slot->used,memory_order_relaxed);
        if(used>source->control->slot_bytes)result=FFSA_INVALID;
        else{
            memset(slot_base(source,lease.slot),0,(size_t)used);
            atomic_store_explicit(&slot->used,0,memory_order_relaxed);
            atomic_store_explicit(&slot->state,SLOT_FREE,memory_order_release);
        }
    }
    pthread_mutex_unlock(&source->local_lock);return result;
}

ffsa_result ffsa_seal(ffsa_endpoint *source,ffsa_lease lease) {
    if(!source||source->role!=FFSA_SOURCE)return FFSA_INVALID;
    pthread_mutex_lock(&source->local_lock);
    ffsa_result result=health(source);
    if(result==FFSA_OK&&!lease_matches(source,lease,SLOT_CLAIMED))result=FFSA_ORDER;
    if(result==FFSA_OK){ffsa_shared_slot *slot=&source->control->slots[lease.slot];
        if(!atomic_load_explicit(&slot->used,memory_order_relaxed))result=FFSA_ORDER;
        else atomic_store_explicit(&slot->state,SLOT_SEALED,memory_order_release);}
    pthread_mutex_unlock(&source->local_lock);return result;
}

ffsa_result ffsa_acquire(ffsa_endpoint *native,ffsa_lease lease,uint64_t *used) {
    if(used)*used=0;
    if(!native||native->role!=FFSA_NATIVE||!used)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=health(native);
    if(result==FFSA_OK&&!lease_matches(native,lease,SLOT_SEALED))result=FFSA_ORDER;
    if(result==FFSA_OK){ffsa_shared_slot *slot=&native->control->slots[lease.slot];
        uint32_t expected=SLOT_SEALED;
        if(native->native_generation[lease.slot]||
           !atomic_compare_exchange_strong_explicit(&slot->state,&expected,SLOT_ACQUIRED,
                memory_order_acq_rel,memory_order_acquire))result=FFSA_ORDER;
        else{native->native_generation[lease.slot]=lease.generation;
            native->native_submitted[lease.slot]=0;native->native_gpu_done[lease.slot]=0;
            native->native_pins[lease.slot]=0;
            *used=atomic_load_explicit(&slot->used,memory_order_acquire);}}
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_pin_extent(ffsa_endpoint *native,ffsa_extent_desc descriptor,void **bytes) {
    if(bytes)*bytes=NULL;
    if(!native||native->role!=FFSA_NATIVE||!bytes)return FFSA_INVALID;
    ffsa_lease lease=descriptor.lease;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=health(native);
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
        native->native_generation[lease.slot]!=lease.generation))result=FFSA_ORDER;
    if(result==FFSA_OK){
        uint64_t rounded=descriptor.length<=UINT64_MAX-FFSA_ALIGNMENT+1?
            (descriptor.length+FFSA_ALIGNMENT-1)&~((uint64_t)FFSA_ALIGNMENT-1):0;
        uint64_t used=atomic_load_explicit(&native->control->slots[lease.slot].used,memory_order_acquire);
        if(used>native->control->slot_bytes||!descriptor.length||!rounded||
           descriptor.allocated_length!=rounded||
           descriptor.offset%FFSA_ALIGNMENT||descriptor.offset>used||rounded>used-descriptor.offset||
           native->native_pins[lease.slot]==UINT32_MAX)result=FFSA_INVALID;
        else{native->native_pins[lease.slot]++;
            *bytes=slot_base(native,lease.slot)+(size_t)descriptor.offset;}}
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_unpin_extent(ffsa_endpoint *native,ffsa_lease lease) {
    if(!native||native->role!=FFSA_NATIVE)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    /* Deallocator callbacks must be able to drop pins after terminal stop.
     * They cannot make the shared slot reusable; only release can do that. */
    ffsa_result result=native->pid==getpid()?FFSA_OK:FFSA_INVALID;
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
       native->native_generation[lease.slot]!=lease.generation||!native->native_pins[lease.slot]))result=FFSA_ORDER;
    if(result==FFSA_OK)native->native_pins[lease.slot]--;
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_native_submitted(ffsa_endpoint *native,ffsa_lease lease) {
    if(!native||native->role!=FFSA_NATIVE)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=health(native);
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
       native->native_generation[lease.slot]!=lease.generation||native->native_submitted[lease.slot]))result=FFSA_ORDER;
    if(result==FFSA_OK)native->native_submitted[lease.slot]=1;
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_native_abandon(ffsa_endpoint *native,ffsa_lease lease) {
    if(!native||native->role!=FFSA_NATIVE)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=native_retirement_health(native);
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
       native->native_generation[lease.slot]!=lease.generation||native->native_submitted[lease.slot]))result=FFSA_ORDER;
    if(result==FFSA_OK&&native->native_pins[lease.slot])result=FFSA_BACKPRESSURE;
    if(result==FFSA_OK){
        native->native_generation[lease.slot]=0;
        atomic_store_explicit(&native->control->slots[lease.slot].state,SLOT_FREE,memory_order_release);
    }
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_native_gpu_complete(ffsa_endpoint *native,ffsa_lease lease) {
    if(!native||native->role!=FFSA_NATIVE)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=native_retirement_health(native);
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
       native->native_generation[lease.slot]!=lease.generation||!native->native_submitted[lease.slot]||
       native->native_gpu_done[lease.slot]))result=FFSA_ORDER;
    if(result==FFSA_OK)native->native_gpu_done[lease.slot]=1;
    pthread_mutex_unlock(&native->local_lock);return result;
}

ffsa_result ffsa_release(ffsa_endpoint *native,ffsa_lease lease) {
    if(!native||native->role!=FFSA_NATIVE)return FFSA_INVALID;
    pthread_mutex_lock(&native->local_lock);
    ffsa_result result=native_retirement_health(native);
    if(result==FFSA_OK&&(!lease_matches(native,lease,SLOT_ACQUIRED)||
       native->native_generation[lease.slot]!=lease.generation))result=FFSA_ORDER;
    if(result==FFSA_OK&&(!native->native_submitted[lease.slot]||
       !native->native_gpu_done[lease.slot]||native->native_pins[lease.slot]))
        result=FFSA_BACKPRESSURE;
    if(result==FFSA_OK){
        ffsa_shared_slot *slot=&native->control->slots[lease.slot];
        native->native_generation[lease.slot]=0;native->native_submitted[lease.slot]=0;
        native->native_gpu_done[lease.slot]=0;
        atomic_store_explicit(&slot->state,SLOT_FREE,memory_order_release);
    }
    pthread_mutex_unlock(&native->local_lock);return result;
}

void ffsa_stop(ffsa_endpoint *endpoint) {
    if(endpoint&&endpoint->pid==getpid())
        atomic_store_explicit(&endpoint->control->stopped,1,memory_order_release);
}

ffsa_result ffsa_detach(ffsa_endpoint *endpoint) {
    if(!endpoint||endpoint->pid!=getpid())return FFSA_INVALID;
    pthread_mutex_lock(&endpoint->local_lock);
    int terminal=atomic_load_explicit(&endpoint->control->stopped,memory_order_acquire);
    for(uint32_t i=0;i<FFSA_SLOT_COUNT;++i){
        if(endpoint->native_pins[i]||(!terminal&&endpoint->native_generation[i])||
           (!terminal&&endpoint->role==FFSA_SOURCE&&
            atomic_load_explicit(&endpoint->control->slots[i].state,memory_order_acquire)!=SLOT_FREE)){
            pthread_mutex_unlock(&endpoint->local_lock);return FFSA_BACKPRESSURE;
        }
    }
    ffsa_stop(endpoint);
    pthread_mutex_unlock(&endpoint->local_lock);
    pthread_mutex_destroy(&endpoint->local_lock);
    munmap(endpoint->mapping,endpoint->mapping_bytes);
    free(endpoint);return FFSA_OK;
}

const char *ffsa_result_name(ffsa_result result) {
    switch(result){
        case FFSA_OK:return "OK";
        case FFSA_BACKPRESSURE:return "BACKPRESSURE";
        case FFSA_STOPPED:return "STOPPED";
        case FFSA_PEER_DEAD:return "PEER_DEAD";
        case FFSA_INVALID:return "INVALID";
        case FFSA_ORDER:return "ORDER";
    }
    return "UNKNOWN";
}
