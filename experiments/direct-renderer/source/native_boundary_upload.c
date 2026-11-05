#include <stddef.h>
#include "live_startup_wire.h"
extern uint32_t fullframe_live_initial_write(uint64_t,uint64_t,uint64_t,const void*,uint64_t,uint64_t);
extern void fullframe_live_buffer_write(uint64_t,uint64_t,uint64_t,const void*,size_t);
#include "native_boundary_upload.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#define FFBU_ENTRIES 4096
typedef struct {uint64_t root,generation,offset,handle;size_t length;void *bytes;} entry;
struct ffbu_store {pthread_mutex_t lock;size_t budget,retained,count;int poisoned;uint64_t writes,hits,misses,copied;entry entries[FFBU_ENTRIES];};
ffbu_store *ffbu_create(size_t budget){
    if(!budget||budget>64u*1024u*1024u)return NULL;
    ffbu_store *s=calloc(1,sizeof(*s));if(!s)return NULL;
    if(pthread_mutex_init(&s->lock,NULL)){free(s);return NULL;}s->budget=budget;return s;
}
static size_t root_start(ffbu_store *s,uint64_t root){size_t lo=0,hi=s->count;while(lo<hi){size_t mid=lo+(hi-lo)/2;if(s->entries[mid].root<root)lo=mid+1;else hi=mid;}return lo;}
static void remove_index(ffbu_store *s,size_t i){s->retained-=s->entries[i].length;free(s->entries[i].bytes);--s->count;memmove(&s->entries[i],&s->entries[i+1],(s->count-i)*sizeof(entry));memset(&s->entries[s->count],0,sizeof(entry));}
void ffbu_destroy(ffbu_store *s){if(!s)return;for(size_t i=0;i<s->count;i++)free(s->entries[i].bytes);pthread_mutex_destroy(&s->lock);free(s);}
int ffbu_write_handle(ffbu_store *s,uint64_t root,uint64_t generation,uint64_t offset,const void *bytes,size_t length,uint64_t handle){
    if(!s)return 0;pthread_mutex_lock(&s->lock);int ok=0;size_t position=0;
    if(s->poisoned||!root||!generation||!bytes||!length||length>s->budget||offset>UINT64_MAX-length)goto fail;
    position=root_start(s,root);
    for(size_t i=position;i<s->count&&s->entries[i].root==root;){entry *e=&s->entries[i];
        if(e->generation<generation){remove_index(s,i);continue;}
        if(e->generation==generation&&offset<e->offset+e->length&&e->offset<offset+length)goto fail;
        ++i;
    }
    if(s->count==FFBU_ENTRIES||length>s->budget-s->retained)goto fail;
    void *copy=malloc(length);if(!copy)goto fail;memcpy(copy,bytes,length);
    memmove(&s->entries[position+1],&s->entries[position],(s->count-position)*sizeof(entry));
    s->entries[position]=(entry){root,generation,offset,handle,length,copy};++s->count;s->retained+=length;++s->writes;ok=1;goto done;
fail:s->poisoned=1;
done:pthread_mutex_unlock(&s->lock);return ok;
}
int ffbu_write(ffbu_store *s,uint64_t root,uint64_t generation,uint64_t offset,const void *bytes,size_t length){return ffbu_write_handle(s,root,generation,offset,bytes,length,0);}
void ffbu_retire_handle(ffbu_store *s,uint64_t handle){if(!s||!handle)return;pthread_mutex_lock(&s->lock);for(size_t i=0;i<s->count;)if(s->entries[i].handle==handle)remove_index(s,i);else ++i;pthread_mutex_unlock(&s->lock);}
int ffbu_copy(ffbu_store *s,uint64_t root,uint64_t generation,uint64_t offset,void *destination,size_t length){
    if(!s)return -1;pthread_mutex_lock(&s->lock);int result=0;
    if(s->poisoned||!root||!generation||!destination||!length||offset>UINT64_MAX-length){result=-1;goto done;}
    for(size_t i=root_start(s,root);i<s->count&&s->entries[i].root==root;i++){entry *e=&s->entries[i];
        if(e->generation==generation&&offset>=e->offset&&offset-e->offset<=e->length&&length<=e->length-(offset-e->offset)){
            memcpy(destination,(const char *)e->bytes+(offset-e->offset),length);result=1;break;}}
done:if(result>0){++s->hits;s->copied+=length;}else if(!result)++s->misses;pthread_mutex_unlock(&s->lock);return result;
}
void ffbu_retire(ffbu_store *s,uint64_t root,uint64_t generation){
    if(!s)return;pthread_mutex_lock(&s->lock);for(size_t i=root_start(s,root);i<s->count&&s->entries[i].root==root;)if(!generation||s->entries[i].generation==generation)remove_index(s,i);else ++i;pthread_mutex_unlock(&s->lock);
}
static pthread_once_t once=PTHREAD_ONCE_INIT;static ffbu_store *store;static int enabled;
static void initialize(void){const char *v=getenv("BEDROCK_BOUNDARY_UPLOADS");enabled=v&&!strcmp(v,"1");if(enabled)store=ffbu_create(64u*1024u*1024u);}
uint32_t fullframe_boundary_upload(uint64_t root,uint64_t generation,uint64_t offset,const void *bytes,uint64_t length,uint64_t handle){
    if(bytes&&length>=sizeof(ffli_header)){uint64_t magic;memcpy(&magic,bytes,8);if(magic==FFLI_MAGIC)return fullframe_live_initial_write(root,generation,offset,bytes,length,handle);}
    extern int fullframe_direct_upload_mode(void);
    extern uint32_t fullframe_direct_upload_seal(uint64_t,uint64_t,uint64_t,const void *,size_t,uint64_t,uint32_t);
    if(fullframe_direct_upload_mode()&&bytes&&length>=24&&length<=32u*1024u*1024u+24){
      uint64_t magic=0,n=0;uint32_t epoch=0,reserved=0;memcpy(&magic,bytes,8);memcpy(&epoch,(const char*)bytes+8,4);
      memcpy(&reserved,(const char*)bytes+12,4);memcpy(&n,(const char*)bytes+16,8);
      if(magic==UINT64_C(0x3155504355444646)&&!reserved&&n==length-24)
        {uint32_t ok=fullframe_direct_upload_seal(root,generation,offset,(const char*)bytes+24,(size_t)n,handle,epoch);if(ok)fullframe_live_buffer_write(root,generation,offset,(const char*)bytes+24,(size_t)n);return ok;}
    }
    pthread_once(&once,initialize);if(!enabled)return 0;
    if(!store)return 0;
    /* Lookups always fall back while authority is incomplete, so don't retain
     * another copy or reject a later overlap that will never be reused. */
    pthread_mutex_lock(&store->lock);
    int ok=!store->poisoned&&root&&generation&&bytes&&length&&length<=store->budget&&
        length<=SIZE_MAX&&offset<=UINT64_MAX-length&&handle;
    if(!ok)store->poisoned=1;pthread_mutex_unlock(&store->lock);
    if(!ok)fprintf(stderr,"[boundary-upload] immutable ownership rejected\n");return ok;
}
int fullframe_boundary_upload_copy(uint64_t root,uint64_t generation,uint64_t offset,void *destination,size_t length){
    pthread_once(&once,initialize);if(!enabled)return 0;
    if(!store||!root||!generation||!destination||!length||offset>UINT64_MAX-length)return -1;
    /* A handle can be written through untracked CPU and Metal aliases. Until
     * every writer is qualified, use the ordered GPU snapshot on every lookup. */
    pthread_mutex_lock(&store->lock);int poisoned=store->poisoned;
    if(!poisoned)++store->misses;pthread_mutex_unlock(&store->lock);
    return poisoned?-1:0;
}
void fullframe_boundary_upload_retire(uint64_t root,uint64_t generation){pthread_once(&once,initialize);if(enabled)ffbu_retire(store,root,generation);}

void fullframe_boundary_upload_invalidate(uint64_t handle){pthread_once(&once,initialize);if(enabled)ffbu_retire_handle(store,handle);}
void fullframe_boundary_upload_report(void){pthread_once(&once,initialize);if(!enabled||!store)return;
    pthread_mutex_lock(&store->lock);fprintf(stderr,"[boundary-upload-result] writes=%llu hits=%llu misses=%llu copied_bytes=%llu retained_bytes=%zu poisoned=%d\n",
        (unsigned long long)store->writes,(unsigned long long)store->hits,(unsigned long long)store->misses,
        (unsigned long long)store->copied,store->retained,store->poisoned);pthread_mutex_unlock(&store->lock);}
