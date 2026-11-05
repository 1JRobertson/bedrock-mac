#include "chunk_stream.h"
#include <errno.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#define FFSC_MAPPING_MAGIC UINT64_C(0x4244434853483031)
#define CONTROL_BYTES 65536u
#define HISTORY FFSC_RECEIPT_CAPACITY
typedef struct { _Atomic uint64_t value; unsigned char pad[120]; } lane;
typedef struct {
    uint64_t magic;uint32_t version,bytes,slots,packet_bytes;
    uint64_t mapping_bytes;unsigned char reserved[96];
    lane producer_pid,native_pid,stopped,write,read,receipt_write,receipt_read,armed;
    uint64_t lengths[FFSC_MAX_SLOTS];
    ffsc_receipt receipts[FFSC_RECEIPT_CAPACITY];
} shared;
_Static_assert(sizeof(lane)==128&&sizeof(shared)<=CONTROL_BYTES,"shared chunk control bounds");
typedef struct { ffsc_packet_header header;unsigned gpu_seen; } publication;
struct ffsc_endpoint {
    shared *shared;size_t mapping_bytes;enum ffsc_role role;
    uint64_t cursor,receipt_cursor;int reserved,peeked,waiting_credit;
    ffsc_packet_header previous;publication history[HISTORY];
    publication presentations[FFSC_PRESENT_HISTORY];
};

static int span(uint64_t offset,uint64_t bytes,size_t total) {return offset<=total&&bytes<=total-offset;}
static int overlaps(uint64_t a,uint64_t n,uint64_t b,uint64_t m) {return n&&m&&a<b+m&&b<a+n;}
int ffsc_receiver_digest_name(const char *name) {
    if(!name)return 0;
    size_t length=strnlen(name,FFSC_BLOB_NAME_BYTES);
    if(!length||length>=FFSC_BLOB_NAME_BYTES)return 0;
    char leaf[FFSC_BLOB_NAME_BYTES];memcpy(leaf,name,length+1);
    char *base=leaf;
    if(!strncmp(base,"page-",5)){
        if(length<10||base[length-5]!='-')return 0;
        unsigned page=0;for(size_t i=length-4;i<length;i++){
            if(base[i]<'0'||base[i]>'9')return 0;page=page*10+(unsigned)(base[i]-'0');}
        if(page>=512)return 0;base[length-5]=0;base+=5;
    }
    const char *digits=!strncmp(base,"cut-buffer-",11)?base+11:
        !strncmp(base,"operation-buffer-",17)?base+17:NULL;
    if(!digits)return 0;
    unsigned index=0,count=0;const char *at=digits;
    while(*at>='0'&&*at<='9'){
        if(++count>4)return 0;index=index*10+(unsigned)(*at++-'0');}
    if(count<2||!index||index>FFS_MAX_RESOURCES||strcmp(at,".bin"))return 0;
    if((count>2&&digits[0]=='0')||(count==2&&index<10&&digits[0]!='0'))return 0;
    return 1;
}
static int basename_valid(const ffsc_blob_entry *b) {
    if(!b->name_bytes||b->name_bytes>=FFSC_BLOB_NAME_BYTES||b->name[b->name_bytes]||
       (b->name[0]=='.'&&(b->name_bytes==1||(b->name_bytes==2&&b->name[1]=='.'))))return 0;
    for(unsigned i=0;i<b->name_bytes;i++){
        unsigned char c=(unsigned char)b->name[i];if(!((c>='a'&&c<='z')||(c>='A'&&c<='Z')||
            (c>='0'&&c<='9')||c=='-'||c=='_'||c=='.'))return 0;
    }
    for(unsigned i=b->name_bytes+1;i<FFSC_BLOB_NAME_BYTES;i++)if(b->name[i])return 0;
    return b->payload_id||!strcmp(b->name,"chunk.json");
}
/* Own all directory fields before comparing them. Reuse one allocation for
 * blobs and retirements: at most640KiB with the existing4096-entry limits. */
_Static_assert(FFSC_MAX_BLOBS*sizeof(ffsc_blob_entry)<=640u*1024u&&
    FFSC_MAX_RETIREMENTS*sizeof(ffsc_retirement)<=640u*1024u&&
    sizeof(ffsc_retirement)<=sizeof(ffsc_blob_entry),"bounded validator scratch and swaps");
#ifdef FFSC_TEST_VALIDATE_ALLOCATOR
extern void *ffsc_test_validate_alloc(size_t);
#define validator_alloc ffsc_test_validate_alloc
#else
#define validator_alloc malloc
#endif
static int compare_u64(uint64_t a,uint64_t b){return (a>b)-(a<b);}
static int blob_namespace_compare(const void *left,const void *right){
    const ffsc_blob_entry *a=left,*b=right;int order=compare_u64(a->payload_id,b->payload_id);
    return order?order:strcmp(a->name,b->name);
}
int ffsc_shared_snapshot_name(const char *name){
    return name&&(!strncmp(name,"cut-buffer-",11)||!strncmp(name,"operation-buffer-",17))&&
        ffsc_receiver_digest_name(name);
}
static int blob_extent_compare(const void *left,const void *right){
    const ffsc_blob_entry *a=left,*b=right;
    int realm=compare_u64(a->flags==FFSC_BLOB_SHARED_SNAPSHOT,b->flags==FFSC_BLOB_SHARED_SNAPSHOT);
    return realm?realm:compare_u64(a->offset,b->offset);
}
static int retirement_compare(const void *left,const void *right){
    const ffsc_retirement *a=left,*b=right;int order=compare_u64(a->kind,b->kind);
    if(!order)order=compare_u64(a->root,b->root);
    return order?order:compare_u64(a->generation,b->generation);
}
static void directory_swap(unsigned char *a,unsigned char *b,size_t width){
    unsigned char temporary[sizeof(ffsc_blob_entry)];memcpy(temporary,a,width);memcpy(a,b,width);memcpy(b,temporary,width);
}
static void directory_sift(unsigned char *base,size_t root,size_t count,size_t width,int (*compare)(const void *,const void *)){
    for(;;){size_t child=root*2+1;if(child>=count)return;
        if(child+1<count&&compare(base+child*width,base+(child+1)*width)<0)child++;
        if(compare(base+root*width,base+child*width)>=0)return;
        directory_swap(base+root*width,base+child*width,width);root=child;}
}
/* Heapsort gives a worst-case O(n log n) bound even for adversarial names and
 * offsets, without recursion or an additional allocation. */
static void directory_sort(void *array,size_t count,size_t width,int (*compare)(const void *,const void *)){
    unsigned char *base=array;
    /* Source packets already sort their namespaces; cached-only directories
     * and ordered retirement tuples need only one linear check. */
    size_t ordered=1;while(ordered<count&&compare(base+(ordered-1)*width,base+ordered*width)<=0)ordered++;
    if(ordered>=count)return;
    for(size_t start=count/2;start;start--)directory_sift(base,start-1,count,width,compare);
    for(size_t end=count;end>1;end--){directory_swap(base,base+(end-1)*width,width);directory_sift(base,0,end-1,width,compare);}
}
enum ffsc_result ffsc_validate_packet(const void *bytes,size_t length) {
    if(!bytes||length<sizeof(ffsc_packet_header)||length>FFSC_MAX_PACKET_BYTES)return FFSC_INVALID;
    ffsc_packet_header h;memcpy(&h,bytes,sizeof(h));
    if(h.magic!=FFSC_PACKET_MAGIC||h.version!=FFSC_VERSION||h.bytes!=sizeof(h)||h.total_bytes!=length||
       !h.serial||!h.stream||!h.frame||!h.first_sequence||h.next_sequence<=h.first_sequence||
       !h.queue_completion||!(h.flags&FFSC_SOURCE_READY)||(h.flags&~7u)||
       !h.record_count||h.record_count>FFS_MAX_RECORDS||h.blob_count>FFSC_MAX_BLOBS||h.retirement_count>FFSC_MAX_RETIREMENTS||
       h.next_sequence-h.first_sequence!=h.record_count)return FFSC_INVALID;
    uint64_t offsets[]={0,h.records_offset,h.blobs_offset,h.retirements_offset};
    uint64_t sizes[]={sizeof(h),(uint64_t)h.record_count*sizeof(ffs_record),(uint64_t)h.blob_count*sizeof(ffsc_blob_entry),
        (uint64_t)h.retirement_count*sizeof(ffsc_retirement)};
    for(unsigned i=0;i<4;i++){
        if((offsets[i]&7)||!span(offsets[i],sizes[i],length))return FFSC_INVALID;
        for(unsigned j=0;j<i;j++)if(overlaps(offsets[i],sizes[i],offsets[j],sizes[j]))return FFSC_INVALID;
    }
    const unsigned char *base=bytes;uint64_t digest=UINT64_C(14695981039346656037);unsigned begins=0,ends=0;
    for(uint32_t i=0;i<h.record_count;i++){
        ffs_record r;memcpy(&r,base+h.records_offset+(size_t)i*sizeof(r),sizeof(r));
        if(r.magic!=FFS_MAGIC||r.version!=FFS_VERSION||r.bytes!=sizeof(r)||r.stream!=h.stream||r.frame!=h.frame||
           r.chunk!=h.chunk||r.sequence!=h.first_sequence+i)return FFSC_INVALID;
        if(r.kind==FFS_FRAME_BEGIN){if(!(h.flags&FFSC_FRAME_BEGIN)||i)return FFSC_INVALID;}
        if(r.kind==FFS_FRAME_END){if(!(h.flags&FFSC_FRAME_END)||i+1!=h.record_count)return FFSC_INVALID;}
        if(r.kind==FFS_CHUNK_BEGIN){if(++begins!=1||i!=!!(h.flags&FFSC_FRAME_BEGIN)||r.data[3]!=h.queue_completion)return FFSC_INVALID;}
        if(r.kind==FFS_CHUNK_END){if(++ends!=1||i+1+!!(h.flags&FFSC_FRAME_END)!=h.record_count)return FFSC_INVALID;}
        digest=ffs_digest(digest,&r);
    }
    ffs_record first,last;memcpy(&first,base+h.records_offset,sizeof(first));
    memcpy(&last,base+h.records_offset+(h.record_count-1)*sizeof(last),sizeof(last));
    if(begins!=1||ends!=1||digest!=h.record_digest||
       !!(first.kind==FFS_FRAME_BEGIN)!=!!(h.flags&FFSC_FRAME_BEGIN)||
       !!(last.kind==FFS_FRAME_END)!=!!(h.flags&FFSC_FRAME_END))return FFSC_INVALID;
    size_t blob_bytes=(size_t)h.blob_count*sizeof(ffsc_blob_entry),retirement_bytes=(size_t)h.retirement_count*sizeof(ffsc_retirement);
    size_t scratch_bytes=blob_bytes>retirement_bytes?blob_bytes:retirement_bytes;
    if(!scratch_bytes)return FFSC_OK;
    void *scratch=validator_alloc(scratch_bytes);if(!scratch)return FFSC_INVALID;
    enum ffsc_result result=FFSC_INVALID;ffsc_blob_entry *blobs=scratch;
    memcpy(blobs,base+h.blobs_offset,blob_bytes);
    for(uint32_t i=0;i<h.blob_count;i++){
        const ffsc_blob_entry *b=&blobs[i];
        if(!basename_valid(b)||!b->length||b->length>FFSC_MAX_PACKET_BYTES||
           (b->flags!=FFSC_BLOB_INLINE&&b->flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_CACHE)&&b->flags!=FFSC_BLOB_CACHED&&
            b->flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_RECEIVER_DIGEST)&&b->flags!=FFSC_BLOB_SHARED_SNAPSHOT))goto done;
        if(b->flags&FFSC_BLOB_RECEIVER_DIGEST){
            if(!b->payload_id||!ffsc_receiver_digest_name(b->name))goto done;
            for(unsigned j=0;j<32;j++)if(b->sha256[j])goto done;
        }
        if(b->flags==FFSC_BLOB_SHARED_SNAPSHOT){
            if(!b->payload_id||!ffsc_shared_snapshot_name(b->name)||
               b->offset%FFSC_SHARED_SNAPSHOT_ALIGNMENT||!span(b->offset,b->length,FFSC_MAX_PACKET_BYTES))goto done;
            for(unsigned j=0;j<32;j++)if(b->sha256[j])goto done;
        }else if(b->flags&FFSC_BLOB_INLINE){
            if((b->offset&7)||!span(b->offset,b->length,length))goto done;
            for(unsigned j=0;j<4;j++)if(overlaps(b->offset,b->length,offsets[j],sizes[j]))goto done;
        }else if(b->offset)goto done;
    }
    directory_sort(blobs,h.blob_count,sizeof(*blobs),blob_namespace_compare);
    for(uint32_t i=1;i<h.blob_count;i++)if(!blob_namespace_compare(&blobs[i-1],&blobs[i]))goto done;
    uint32_t inline_count=0;
    for(uint32_t i=0;i<h.blob_count;i++)if(blobs[i].flags&(FFSC_BLOB_INLINE|FFSC_BLOB_SHARED_SNAPSHOT)){
        if(inline_count!=i)blobs[inline_count]=blobs[i];inline_count++;}
    directory_sort(blobs,inline_count,sizeof(*blobs),blob_extent_compare);
    const ffsc_blob_entry *previous=NULL;
    for(uint32_t i=0;i<inline_count;i++){
        const ffsc_blob_entry *b=&blobs[i];
        if(previous&&((previous->flags==FFSC_BLOB_SHARED_SNAPSHOT)!=(b->flags==FFSC_BLOB_SHARED_SNAPSHOT)))previous=NULL;
        if(previous&&b->offset<previous->offset+previous->length){
            if(b->offset!=previous->offset||b->length!=previous->length||memcmp(b->sha256,previous->sha256,32))goto done;
        }else previous=b;
    }
    ffsc_retirement *retirements=scratch;memcpy(retirements,base+h.retirements_offset,retirement_bytes);
    for(uint32_t i=0;i<h.retirement_count;i++){
        const ffsc_retirement *r=&retirements[i];
        if(!r->root||!r->generation||!r->last_use_serial||r->last_use_serial>h.serial||r->reserved||
           (r->kind!=FFS_BUFFER&&r->kind!=FFS_TEXTURE))goto done;
    }
    directory_sort(retirements,h.retirement_count,sizeof(*retirements),retirement_compare);
    for(uint32_t i=1;i<h.retirement_count;i++)if(!retirement_compare(&retirements[i-1],&retirements[i]))goto done;
    result=FFSC_OK;
done:free(scratch);return result;
}

/* Private endpoint only: owned native request performs the delayed digest. */
static enum ffsc_result ffsc_validate_packet_deferred(const void *bytes,size_t length) {
    if(!bytes||length<sizeof(ffsc_packet_header)||length>FFSC_MAX_PACKET_BYTES)return FFSC_INVALID;
    ffsc_packet_header h;memcpy(&h,bytes,sizeof(h));
    if(h.magic!=FFSC_PACKET_MAGIC||h.version!=FFSC_VERSION||h.bytes!=sizeof(h)||h.total_bytes!=length||
       !h.serial||!h.stream||!h.frame||!h.first_sequence||h.next_sequence<=h.first_sequence||
       !h.queue_completion||!(h.flags&FFSC_SOURCE_READY)||(h.flags&~7u)||
       !h.record_count||h.record_count>FFS_MAX_RECORDS||h.blob_count>FFSC_MAX_BLOBS||h.retirement_count>FFSC_MAX_RETIREMENTS||
       h.next_sequence-h.first_sequence!=h.record_count)return FFSC_INVALID;
    uint64_t offsets[]={0,h.records_offset,h.blobs_offset,h.retirements_offset};
    uint64_t sizes[]={sizeof(h),(uint64_t)h.record_count*sizeof(ffs_record),(uint64_t)h.blob_count*sizeof(ffsc_blob_entry),
        (uint64_t)h.retirement_count*sizeof(ffsc_retirement)};
    for(unsigned i=0;i<4;i++){
        if((offsets[i]&7)||!span(offsets[i],sizes[i],length))return FFSC_INVALID;
        for(unsigned j=0;j<i;j++)if(overlaps(offsets[i],sizes[i],offsets[j],sizes[j]))return FFSC_INVALID;
    }
    const unsigned char *base=bytes;unsigned begins=0,ends=0;
    for(uint32_t i=0;i<h.record_count;i++){
        ffs_record r;memcpy(&r,base+h.records_offset+(size_t)i*sizeof(r),sizeof(r));
        if(r.magic!=FFS_MAGIC||r.version!=FFS_VERSION||r.bytes!=sizeof(r)||r.stream!=h.stream||r.frame!=h.frame||
           r.chunk!=h.chunk||r.sequence!=h.first_sequence+i)return FFSC_INVALID;
        if(r.kind==FFS_FRAME_BEGIN){if(!(h.flags&FFSC_FRAME_BEGIN)||i)return FFSC_INVALID;}
        if(r.kind==FFS_FRAME_END){if(!(h.flags&FFSC_FRAME_END)||i+1!=h.record_count)return FFSC_INVALID;}
        if(r.kind==FFS_CHUNK_BEGIN){if(++begins!=1||i!=!!(h.flags&FFSC_FRAME_BEGIN)||r.data[3]!=h.queue_completion)return FFSC_INVALID;}
        if(r.kind==FFS_CHUNK_END){if(++ends!=1||i+1+!!(h.flags&FFSC_FRAME_END)!=h.record_count)return FFSC_INVALID;}
    }
    ffs_record first,last;memcpy(&first,base+h.records_offset,sizeof(first));
    memcpy(&last,base+h.records_offset+(h.record_count-1)*sizeof(last),sizeof(last));
    if(begins!=1||ends!=1||
       !!(first.kind==FFS_FRAME_BEGIN)!=!!(h.flags&FFSC_FRAME_BEGIN)||
       !!(last.kind==FFS_FRAME_END)!=!!(h.flags&FFSC_FRAME_END))return FFSC_INVALID;
    size_t blob_bytes=(size_t)h.blob_count*sizeof(ffsc_blob_entry),retirement_bytes=(size_t)h.retirement_count*sizeof(ffsc_retirement);
    size_t scratch_bytes=blob_bytes>retirement_bytes?blob_bytes:retirement_bytes;
    if(!scratch_bytes)return FFSC_OK;
    void *scratch=validator_alloc(scratch_bytes);if(!scratch)return FFSC_INVALID;
    enum ffsc_result result=FFSC_INVALID;ffsc_blob_entry *blobs=scratch;
    memcpy(blobs,base+h.blobs_offset,blob_bytes);
    for(uint32_t i=0;i<h.blob_count;i++){
        const ffsc_blob_entry *b=&blobs[i];
        if(!basename_valid(b)||!b->length||b->length>FFSC_MAX_PACKET_BYTES||
           (b->flags!=FFSC_BLOB_INLINE&&b->flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_CACHE)&&b->flags!=FFSC_BLOB_CACHED&&
            b->flags!=(FFSC_BLOB_INLINE|FFSC_BLOB_RECEIVER_DIGEST)&&b->flags!=FFSC_BLOB_SHARED_SNAPSHOT))goto done;
        if(b->flags&FFSC_BLOB_RECEIVER_DIGEST){
            if(!b->payload_id||!ffsc_receiver_digest_name(b->name))goto done;
            for(unsigned j=0;j<32;j++)if(b->sha256[j])goto done;
        }
        if(b->flags==FFSC_BLOB_SHARED_SNAPSHOT){
            if(!b->payload_id||!ffsc_shared_snapshot_name(b->name)||
               b->offset%FFSC_SHARED_SNAPSHOT_ALIGNMENT||!span(b->offset,b->length,FFSC_MAX_PACKET_BYTES))goto done;
            for(unsigned j=0;j<32;j++)if(b->sha256[j])goto done;
        }else if(b->flags&FFSC_BLOB_INLINE){
            if((b->offset&7)||!span(b->offset,b->length,length))goto done;
            for(unsigned j=0;j<4;j++)if(overlaps(b->offset,b->length,offsets[j],sizes[j]))goto done;
        }else if(b->offset)goto done;
    }
    directory_sort(blobs,h.blob_count,sizeof(*blobs),blob_namespace_compare);
    for(uint32_t i=1;i<h.blob_count;i++)if(!blob_namespace_compare(&blobs[i-1],&blobs[i]))goto done;
    uint32_t inline_count=0;
    for(uint32_t i=0;i<h.blob_count;i++)if(blobs[i].flags&(FFSC_BLOB_INLINE|FFSC_BLOB_SHARED_SNAPSHOT)){
        if(inline_count!=i)blobs[inline_count]=blobs[i];inline_count++;}
    directory_sort(blobs,inline_count,sizeof(*blobs),blob_extent_compare);
    const ffsc_blob_entry *previous=NULL;
    for(uint32_t i=0;i<inline_count;i++){
        const ffsc_blob_entry *b=&blobs[i];
        if(previous&&((previous->flags==FFSC_BLOB_SHARED_SNAPSHOT)!=(b->flags==FFSC_BLOB_SHARED_SNAPSHOT)))previous=NULL;
        if(previous&&b->offset<previous->offset+previous->length){
            if(b->offset!=previous->offset||b->length!=previous->length||memcmp(b->sha256,previous->sha256,32))goto done;
        }else previous=b;
    }
    ffsc_retirement *retirements=scratch;memcpy(retirements,base+h.retirements_offset,retirement_bytes);
    for(uint32_t i=0;i<h.retirement_count;i++){
        const ffsc_retirement *r=&retirements[i];
        if(!r->root||!r->generation||!r->last_use_serial||r->last_use_serial>h.serial||r->reserved||
           (r->kind!=FFS_BUFFER&&r->kind!=FFS_TEXTURE))goto done;
    }
    directory_sort(retirements,h.retirement_count,sizeof(*retirements),retirement_compare);
    for(uint32_t i=1;i<h.retirement_count;i++)if(!retirement_compare(&retirements[i-1],&retirements[i]))goto done;
    result=FFSC_OK;
done:free(scratch);return result;
}

static int private_file(int fd,struct stat *s) {return !fstat(fd,s)&&S_ISREG(s->st_mode)&&s->st_uid==getuid()&&
    (s->st_mode&0777)==0600&&s->st_nlink==1;}
enum ffsc_result ffsc_create(int fd,uint32_t slots,uint32_t packetBytes) {
    struct stat st;size_t page=(size_t)sysconf(_SC_PAGESIZE);
    if(!private_file(fd,&st)||st.st_size||!slots||slots>FFSC_MAX_SLOTS||packetBytes<4096||
       packetBytes>FFSC_MAX_PACKET_BYTES||!page||packetBytes%page)return FFSC_INVALID;
    size_t bytes=CONTROL_BYTES+(size_t)slots*packetBytes;if(ftruncate(fd,(off_t)bytes))return FFSC_INVALID;
    shared *s=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(s==MAP_FAILED)return FFSC_INVALID;
    memset(s,0,CONTROL_BYTES);s->version=FFSC_VERSION;s->bytes=CONTROL_BYTES;s->slots=slots;s->packet_bytes=packetBytes;s->mapping_bytes=bytes;
    atomic_init(&s->producer_pid.value,0);atomic_init(&s->native_pid.value,0);atomic_init(&s->stopped.value,0);
    atomic_init(&s->write.value,0);atomic_init(&s->read.value,0);atomic_init(&s->receipt_write.value,0);atomic_init(&s->receipt_read.value,0);
    atomic_init(&s->armed.value,0);
    int ok=atomic_is_lock_free(&s->write.value);atomic_thread_fence(memory_order_release);s->magic=FFSC_MAPPING_MAGIC;
    if(msync(s,CONTROL_BYTES,MS_SYNC))ok=0;munmap(s,bytes);return ok?FFSC_OK:FFSC_INVALID;
}
enum ffsc_result ffsc_attach(int fd,enum ffsc_role role,ffsc_endpoint **out) {
    if(out)*out=NULL;struct stat st;
    if(!out||(role!=FFSC_PRODUCER&&role!=FFSC_NATIVE)||!private_file(fd,&st)||st.st_size<CONTROL_BYTES||
       st.st_size>(off_t)(CONTROL_BYTES+(uint64_t)FFSC_MAX_SLOTS*FFSC_MAX_PACKET_BYTES))return FFSC_INVALID;
    size_t bytes=(size_t)st.st_size;shared *s=mmap(NULL,bytes,PROT_READ|PROT_WRITE,MAP_SHARED,fd,0);if(s==MAP_FAILED)return FFSC_INVALID;
    if(s->magic!=FFSC_MAPPING_MAGIC||s->version!=FFSC_VERSION||s->bytes!=CONTROL_BYTES||
       !s->slots||s->slots>FFSC_MAX_SLOTS||s->packet_bytes<4096||s->packet_bytes>FFSC_MAX_PACKET_BYTES||
       s->mapping_bytes!=bytes||bytes!=CONTROL_BYTES+(size_t)s->slots*s->packet_bytes||!atomic_is_lock_free(&s->write.value)){
        munmap(s,bytes);return FFSC_INVALID;
    }
    ffsc_endpoint *e=calloc(1,sizeof(*e));if(!e){munmap(s,bytes);return FFSC_INVALID;}
    uint64_t expected=0;_Atomic uint64_t *pid=role==FFSC_PRODUCER?&s->producer_pid.value:&s->native_pid.value;
    if(!atomic_compare_exchange_strong_explicit(pid,&expected,(uint64_t)getpid(),memory_order_acq_rel,memory_order_acquire)){
        free(e);munmap(s,bytes);return FFSC_ORDER;
    }
    e->shared=s;e->mapping_bytes=bytes;e->role=role;*out=e;return FFSC_OK;
}
static enum ffsc_result alive(ffsc_endpoint *e) {
    if(!e)return FFSC_INVALID;shared *s=e->shared;
    uint64_t stopped=atomic_load_explicit(&s->stopped.value,memory_order_acquire);
    if(stopped)return stopped==2?FFSC_SOURCE_CLOSED:FFSC_CLOSED;
    uint64_t pid=atomic_load_explicit(e->role==FFSC_PRODUCER?&s->native_pid.value:&s->producer_pid.value,memory_order_acquire);
    if(pid&&kill((pid_t)pid,0)&&errno==ESRCH)return FFSC_PEER_DEAD;return FFSC_OK;
}
void ffsc_stop(ffsc_endpoint *e){if(e)atomic_store_explicit(&e->shared->stopped.value,1,memory_order_release);}
void ffsc_source_close(ffsc_endpoint *e){
    if(!e||e->role!=FFSC_PRODUCER)return;
    uint64_t expected=0;
    atomic_compare_exchange_strong_explicit(&e->shared->stopped.value,&expected,2,memory_order_acq_rel,memory_order_acquire);
}
void ffsc_destroy(ffsc_endpoint *e){if(e){ffsc_stop(e);munmap(e->shared,e->mapping_bytes);free(e);}}
enum ffsc_result ffsc_arm(ffsc_endpoint *e){enum ffsc_result r=alive(e);if(r!=FFSC_OK)return r;
    if(e->role!=FFSC_NATIVE)return FFSC_INVALID;atomic_store_explicit(&e->shared->armed.value,1,memory_order_release);return FFSC_OK;}
int ffsc_is_armed(ffsc_endpoint *e){return e&&alive(e)==FFSC_OK&&atomic_load_explicit(&e->shared->armed.value,memory_order_acquire);}
static unsigned char *slot(ffsc_endpoint *e,uint64_t cursor){return (unsigned char *)e->shared+CONTROL_BYTES+(cursor%e->shared->slots)*e->shared->packet_bytes;}
enum ffsc_result ffsc_reserve(ffsc_endpoint *e,void **bytes,size_t *capacity) {
    if(bytes)*bytes=NULL;if(capacity)*capacity=0;
    enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_PRODUCER||!bytes||!capacity||e->reserved)return FFSC_INVALID;
    uint64_t read=atomic_load_explicit(&e->shared->read.value,memory_order_acquire);
    if(e->cursor<read||e->cursor-read>=e->shared->slots){e->waiting_credit=1;return FFSC_BACKPRESSURE;}
    publication *old=&e->history[(e->cursor+1)%HISTORY];
    if(old->header.serial&&!old->gpu_seen){e->waiting_credit=1;return FFSC_BACKPRESSURE;}
    unsigned available=0;for(unsigned i=0;i<FFSC_PRESENT_HISTORY;i++)if(!e->presentations[i].header.serial)available++;
    if(!available){e->waiting_credit=1;return FFSC_BACKPRESSURE;}
    e->reserved=1;e->waiting_credit=0;*bytes=slot(e,e->cursor);*capacity=e->shared->packet_bytes;return FFSC_OK;
}
static int follows(ffsc_endpoint *e,const ffsc_packet_header *h) {
    const ffsc_packet_header *p=&e->previous;
    if(h->serial!=e->cursor+1)return 0;
    if(!e->cursor)return h->flags&FFSC_FRAME_BEGIN;
    if(h->stream!=p->stream||h->first_sequence!=p->next_sequence||h->chunk!=p->chunk+1||h->queue_completion<=p->queue_completion)return 0;
    if(p->flags&FFSC_FRAME_END)return (h->flags&FFSC_FRAME_BEGIN)&&h->frame>p->frame;
    return !(h->flags&FFSC_FRAME_BEGIN)&&h->frame==p->frame;
}
enum ffsc_result ffsc_publish(ffsc_endpoint *e,size_t bytes) {
    enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_PRODUCER||!e->reserved)return FFSC_INVALID;
    if(bytes>e->shared->packet_bytes)return FFSC_TOO_LARGE;
    void *data=slot(e,e->cursor);result=ffsc_validate_packet(data,bytes);if(result!=FFSC_OK)return result;
    ffsc_packet_header h;memcpy(&h,data,sizeof(h));if(!follows(e,&h))return FFSC_ORDER;
    e->history[h.serial%HISTORY]=(publication){.header=h};e->previous=h;
    if(h.flags&FFSC_FRAME_END)for(unsigned i=0;i<FFSC_PRESENT_HISTORY;i++)if(!e->presentations[i].header.serial){
        e->presentations[i]=(publication){.header=h};break;}
    e->shared->lengths[e->cursor%e->shared->slots]=bytes;e->cursor++;e->reserved=0;
    atomic_store_explicit(&e->shared->write.value,e->cursor,memory_order_release);return FFSC_OK;
}
void ffsc_abort(ffsc_endpoint *e){if(e&&e->role==FFSC_PRODUCER)e->reserved=0;}
static uint64_t ffsc_private_now_ns(void) {
    struct timespec t;if(clock_gettime(CLOCK_MONOTONIC,&t))return 0;
    return (uint64_t)t.tv_sec*UINT64_C(1000000000)+(uint64_t)t.tv_nsec;
}
static enum ffsc_result ffsc_peek_impl(ffsc_endpoint *e,const void **bytes,size_t *length,
                                      unsigned mode,ffsc_private_peek_stats *stats) {
    if(stats)memset(stats,0,sizeof(*stats));if(mode>2)return FFSC_INVALID;
    if(bytes)*bytes=NULL;if(length)*length=0;enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_NATIVE||!bytes||!length)return FFSC_INVALID;
    uint64_t write=atomic_load_explicit(&e->shared->write.value,memory_order_acquire);
    if(write==e->cursor)return FFSC_EMPTY;if(write<e->cursor||write-e->cursor>e->shared->slots)return FFSC_INVALID;
    size_t size=e->shared->lengths[e->cursor%e->shared->slots];if(size>e->shared->packet_bytes)return FFSC_INVALID;
    const void *data=slot(e,e->cursor);uint64_t start=stats?ffsc_private_now_ns():0,finish=0;
    enum ffsc_result shadow=FFSC_INVALID;
    if(mode!=2){result=ffsc_validate_packet(data,size);if(stats){finish=ffsc_private_now_ns();stats->original_ns=finish-start;}}
    if(mode){start=stats?ffsc_private_now_ns():0;shadow=ffsc_validate_packet_deferred(data,size);
        if(stats){finish=ffsc_private_now_ns();stats->deferred_ns=finish-start;}}
    if(mode==2)result=shadow;
    else if(mode==1&&stats)stats->shadow_mismatch=(result!=shadow);
    if(result!=FFSC_OK)return result;
    ffsc_packet_header h;memcpy(&h,data,sizeof(h));if(!follows(e,&h))return FFSC_ORDER;
    e->history[h.serial%HISTORY]=(publication){.header=h};
    if(!e->peeked&&(h.flags&FFSC_FRAME_END)){
        unsigned i=0;for(;i<FFSC_PRESENT_HISTORY;i++)if(!e->presentations[i].header.serial){e->presentations[i]=(publication){.header=h};break;}
        if(i==FFSC_PRESENT_HISTORY)return FFSC_BACKPRESSURE;
    }
    e->peeked=1;*bytes=data;*length=size;if(stats)stats->records=h.record_count;return FFSC_OK;
}
enum ffsc_result ffsc_peek(ffsc_endpoint *e,const void **bytes,size_t *length) {
    return ffsc_peek_impl(e,bytes,length,0,NULL);
}
enum ffsc_result ffsc_peek_private(ffsc_endpoint *e,const void **bytes,size_t *length,
                                   unsigned mode,ffsc_private_peek_stats *stats) {
    return ffsc_peek_impl(e,bytes,length,mode,stats);
}
enum ffsc_result ffsc_consume(ffsc_endpoint *e,uint64_t serial) {
    enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_NATIVE||!e->peeked||serial!=e->cursor+1)return FFSC_ORDER;
    e->previous=e->history[serial%HISTORY].header;e->cursor++;e->peeked=0;
    atomic_store_explicit(&e->shared->read.value,e->cursor,memory_order_release);return FFSC_OK;
}
uint64_t ffsc_transport_consumed(ffsc_endpoint *e){return e?atomic_load_explicit(&e->shared->read.value,memory_order_acquire):0;}
static int receipt_matches(ffsc_endpoint *e,const ffsc_receipt *r) {
    if(!r||r->version!=FFSC_VERSION||r->kind<FFSC_NATIVE_GPU_COMPLETED||r->kind>FFSC_OFFSCREEN_COMPLETED||
       r->status>FFSC_SUPERSEDED||!r->serial)return 0;
    publication *p=&e->history[r->serial%HISTORY];
    if(r->kind==FFSC_PRESENTED||r->kind==FFSC_OFFSCREEN_COMPLETED){p=NULL;for(unsigned i=0;i<FFSC_PRESENT_HISTORY;i++)if(e->presentations[i].header.serial==r->serial){p=&e->presentations[i];break;}if(!p)return 0;}
    const ffsc_packet_header *h=&p->header;
    if(h->serial!=r->serial||r->stream!=h->stream||r->frame!=h->frame||r->chunk!=h->chunk||
       r->record_digest!=h->record_digest||r->queue_completion!=h->queue_completion)return 0;
    if(r->kind==FFSC_NATIVE_GPU_COMPLETED&&p->gpu_seen)return 0;
    if(r->kind==FFSC_QUERY_READY&&(r->query_kind<FFSC_TIMESTAMP||r->query_kind>FFSC_MAP_READBACK||!r->count))return 0;
    if((r->kind==FFSC_PRESENTED||r->kind==FFSC_OFFSCREEN_COMPLETED)&&!(h->flags&FFSC_FRAME_END))return 0;
    return 1;
}
static void retire_presentation(ffsc_endpoint *e,uint64_t serial){
    for(unsigned i=0;i<FFSC_PRESENT_HISTORY;i++)if(e->presentations[i].header.serial==serial){memset(&e->presentations[i],0,sizeof(publication));break;}
}
enum ffsc_result ffsc_send_receipt(ffsc_endpoint *e,const ffsc_receipt *r) {
    enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_NATIVE||!receipt_matches(e,r)||r->serial>e->cursor)return FFSC_INVALID;
    uint64_t read=atomic_load_explicit(&e->shared->receipt_read.value,memory_order_acquire);
    if(e->receipt_cursor<read||e->receipt_cursor-read>=FFSC_RECEIPT_CAPACITY){e->waiting_credit=1;return FFSC_BACKPRESSURE;}
    e->shared->receipts[e->receipt_cursor%FFSC_RECEIPT_CAPACITY]=*r;e->receipt_cursor++;
    if(r->kind==FFSC_NATIVE_GPU_COMPLETED)e->history[r->serial%HISTORY].gpu_seen=1;
    if(r->kind==FFSC_PRESENTED||r->kind==FFSC_OFFSCREEN_COMPLETED)retire_presentation(e,r->serial);
    e->waiting_credit=0;atomic_store_explicit(&e->shared->receipt_write.value,e->receipt_cursor,memory_order_release);return FFSC_OK;
}
enum ffsc_result ffsc_receive_receipt(ffsc_endpoint *e,ffsc_receipt *r) {
    enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;
    if(e->role!=FFSC_PRODUCER||!r)return FFSC_INVALID;
    uint64_t write=atomic_load_explicit(&e->shared->receipt_write.value,memory_order_acquire);
    if(write==e->receipt_cursor)return FFSC_EMPTY;
    if(write<e->receipt_cursor||write-e->receipt_cursor>FFSC_RECEIPT_CAPACITY)return FFSC_INVALID;
    ffsc_receipt copy=e->shared->receipts[e->receipt_cursor%FFSC_RECEIPT_CAPACITY];
    if(!receipt_matches(e,&copy))return FFSC_INVALID;
    if(copy.kind==FFSC_NATIVE_GPU_COMPLETED)e->history[copy.serial%HISTORY].gpu_seen=1;
    if(copy.kind==FFSC_PRESENTED||copy.kind==FFSC_OFFSCREEN_COMPLETED)retire_presentation(e,copy.serial);
    e->receipt_cursor++;atomic_store_explicit(&e->shared->receipt_read.value,e->receipt_cursor,memory_order_release);*r=copy;return FFSC_OK;
}
enum ffsc_result ffsc_wait(ffsc_endpoint *e,uint32_t ms) {
    if(!e||ms>1000)return FFSC_INVALID;uint32_t waited=0;
    do {
        enum ffsc_result result=alive(e);if(result!=FFSC_OK)return result;shared *s=e->shared;
        if(e->role==FFSC_PRODUCER){
            if(atomic_load_explicit(&s->receipt_write.value,memory_order_acquire)!=e->receipt_cursor)return FFSC_OK;
            unsigned available=0;for(unsigned i=0;i<FFSC_PRESENT_HISTORY;i++)if(!e->presentations[i].header.serial)available++;
            if(e->waiting_credit&&available&&e->cursor-atomic_load_explicit(&s->read.value,memory_order_acquire)<s->slots&&
               (!e->history[(e->cursor+1)%HISTORY].header.serial||e->history[(e->cursor+1)%HISTORY].gpu_seen))return FFSC_OK;
        }else{
            if(atomic_load_explicit(&s->write.value,memory_order_acquire)!=e->cursor)return FFSC_OK;
            if(e->waiting_credit&&e->receipt_cursor-atomic_load_explicit(&s->receipt_read.value,memory_order_acquire)<FFSC_RECEIPT_CAPACITY)return FFSC_OK;
        }
        if(waited==ms)break;struct timespec delay={0,1000000};while(nanosleep(&delay,&delay)&&errno==EINTR){}waited++;
    }while(1);return FFSC_EMPTY;
}
