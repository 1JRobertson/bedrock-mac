/* Allocation lifetime authority with optional coverage diagnostics. Native
 * references still require independent written-range/version evidence. */
#include "retained_observer.h"
#include "direct_pass_journal.h"
#include "frame_stream.h"
#include "frame_stream_private.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define RO_CAPACITY 65536u
enum { TAINT_POINTER=1,TAINT_UPDATE=2,TAINT_ALIAS=4,TAINT_GENERATION=8,TAINT_POLICY=16,TAINT_DEAD=32 };
typedef struct {uint64_t root,generation,handle,length;uint32_t taint,policy,candidate,direct,epoch,upload_epoch;uint64_t upload_generation,upload_offset,published_generation;uint32_t published_epoch,published_count,published_cursor;uint64_t published_ranges[8][2];size_t upload_length;void *upload;} ROEntry;
static ROEntry entries[RO_CAPACITY];static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_once_t once=PTHREAD_ONCE_INIT;static int enabled,diagnostics,live_commands;
static size_t direct_bytes;static uint64_t direct_seals,direct_hits,direct_misses,direct_copied,direct_births,direct_queries;static int direct_mode;
static uint64_t events,births,cpu,updates,aliases,generations,deaths,passes,ranges_seen,bytes,union_bytes;
static uint64_t clean_bytes,mapped_bytes,updated_bytes,alias_bytes,policy_bytes,unknown_bytes,overflow,invalid;
static uint64_t active,peak_active;
static uint64_t flag_only_bytes,placed_bytes,suballocated_bytes,generation_only_bytes;
static uint64_t stream_ranges,stream_bytes,stream_matched_bytes,stream_unexposed_bytes;
static void report_locked(void);
static void configure(void){const char *l=getenv("BEDROCK_LIVE_COMMANDS");live_commands=l&&!strcmp(l,"1");const char *v=getenv("BEDROCK_PRIVATE_RETAINED_OBSERVER"),*r=getenv("BEDROCK_NATIVE_RETAINED");diagnostics=v&&!strcmp(v,"1");enabled=diagnostics||(r&&!strcmp(r,"1"));const char *d=getenv("BEDROCK_DIRECT_UPLOAD");direct_mode=d&&!strcmp(d,"1")?1:d&&!strcmp(d,"2")?2:0;}
static ROEntry *lookup(uint64_t root,int create){
 size_t slot=(size_t)((root*UINT64_C(11400714819323198485))>>(64-16));
 for(size_t n=0;n<RO_CAPACITY;n++){ROEntry *e=&entries[(slot+n)&(RO_CAPACITY-1)];if(e->root==root)return e;if(!e->root)return create?e:NULL;}
 if(create)overflow++;return NULL;
}
/* Remove a retired lifetime with backward-shift deletion. Keeping the probe
 * chain intact avoids both stale matches and an ever-growing tombstone set.
 * Only concurrent live identities consume capacity. Source incarnation IDs
 * remain producer-issued; this observer does not grant authority. */
static void direct_drop(ROEntry *e){if(e->upload){direct_bytes-=e->upload_length;free(e->upload);}e->upload=NULL;e->upload_length=0;e->upload_epoch=0;}
static void erase(ROEntry *entry){
 direct_drop(entry);
 size_t hole=(size_t)(entry-entries),scan=(hole+1)&(RO_CAPACITY-1);
 for(size_t visited=0;visited<RO_CAPACITY-1&&entries[scan].root;visited++){
  size_t home=(size_t)((entries[scan].root*UINT64_C(11400714819323198485))>>(64-16));
  if(((scan-home)&(RO_CAPACITY-1))>=((scan-hole)&(RO_CAPACITY-1))){entries[hole]=entries[scan];hole=scan;}
  scan=(scan+1)&(RO_CAPACITY-1);
 }
 entries[hole]=(ROEntry){0};active--;
}
uint32_t retained_observer_event(const ROEvent *v){
 pthread_once(&once,configure);if(!enabled)return 0;
 if(v&&!diagnostics&&(v->operation==RO_STREAM_READ||v->operation==RO_REPORT))return 1;
 pthread_mutex_lock(&lock);events++;
 if(v&&v->operation==9){++direct_queries;ROEntry *e=v->root?lookup(v->root,0):NULL;
  uint32_t stamp=direct_mode&&e&&e->direct&&e->handle==v->handle&&!invalid&&!overflow&&
      !(e->taint&(TAINT_ALIAS|TAINT_DEAD))?e->epoch:0;
  pthread_mutex_unlock(&lock);return stamp;}

 if(v&&v->operation==8){report_locked();pthread_mutex_unlock(&lock);return 1;}
 if(v&&v->operation==7){
  stream_ranges++;stream_bytes+=v->length;ROEntry *e=v->root?lookup(v->root,0):NULL;
  if(e&&e->generation==v->generation&&e->handle==v->handle&&!(e->taint&TAINT_DEAD)&&v->auxiliary<=e->length&&v->length<=e->length-v->auxiliary){
   stream_matched_bytes+=v->length;if(!overflow&&!invalid&&!e->taint)stream_unexposed_bytes+=v->length;
  }
  if(stream_ranges<=8||!(stream_ranges%4096))report_locked();
  pthread_mutex_unlock(&lock);return 1;
 }
 if(!v||!v->root||!v->generation||!v->handle||v->operation<1||v->operation>6){invalid++;pthread_mutex_unlock(&lock);return 0;}
 ROEntry *e=lookup(v->root,v->operation==RO_BIRTH);
 if(v->operation==RO_BIRTH){
  births++;
  if(!e||e->root||!v->length){invalid++;pthread_mutex_unlock(&lock);return 0;}
  *e=(ROEntry){.root=v->root,.generation=v->generation,.handle=v->handle,.length=v->length,.candidate=(v->flags&(UINT64_C(1)<<7))!=0,.direct=direct_mode&&(v->flags&(UINT64_C(1)<<8))&&!(v->flags&((UINT64_C(1)<<1)|(UINT64_C(1)<<6)))&&v->auxiliary==1,.epoch=1};active++;if(active>peak_active)peak_active=active;
  /* Explicitly reject placed backing, suballocation and non-single allocation.
   * This is a prospective cohort label, not a claim of graphics authority. */
  e->policy=((v->flags&(UINT64_C(1)<<5))?1u:0u)|((v->flags&(UINT64_C(1)<<6))?2u:0u)|((v->auxiliary!=1)?4u:0u);
  if(e->policy)e->taint|=TAINT_POLICY;if(e->direct)++direct_births;
 }else if(!e||e->handle!=v->handle||(e->taint&TAINT_DEAD)){invalid++;}
 else {
  if(e->generation!=v->generation)e->taint|=TAINT_GENERATION;
  if(v->operation==RO_CPU_POINTER||v->operation==RO_UPDATE||v->operation==RO_ALIAS ){
    if(!live_commands||v->operation==RO_ALIAS)direct_drop(e);if(e->epoch<UINT32_MAX)++e->epoch;else e->direct=0;
  }
  switch(v->operation){
   case RO_CPU_POINTER:cpu++;e->taint|=TAINT_POINTER;break;
   case RO_UPDATE:updates++;e->taint|=TAINT_UPDATE;break;
   case RO_ALIAS:aliases++;e->taint|=TAINT_ALIAS;break;
   case RO_GENERATION:generations++;e->taint|=TAINT_GENERATION;e->generation=v->generation+1;break;
   case RO_DESTROY:deaths++;erase(e);break;
  }
 }
 if(events<=16||!(events%16384))report_locked();
 pthread_mutex_unlock(&lock);return 1;
}
static int compare(const void *a,const void *b){const RORange *x=a,*y=b;
 if(x->root!=y->root)return x->root<y->root?-1:1;if(x->generation!=y->generation)return x->generation<y->generation?-1:1;
 if(x->handle!=y->handle)return x->handle<y->handle?-1:1;return x->offset<y->offset?-1:x->offset!=y->offset;
}
static void classify(RORange r){
 union_bytes+=r.length;ROEntry *e=lookup(r.root,0);
 if(overflow||invalid||!e||e->generation!=r.generation||e->handle!=r.handle||(e->taint&TAINT_DEAD)||r.offset>e->length||r.length>e->length-r.offset){unknown_bytes+=r.length;return;}
 if(e->taint&TAINT_POINTER)mapped_bytes+=r.length;
 else if(e->taint&TAINT_UPDATE)updated_bytes+=r.length;
 else if(e->taint&TAINT_ALIAS)alias_bytes+=r.length;
 else if(e->taint&(TAINT_POLICY|TAINT_GENERATION)){
  policy_bytes+=r.length;
  if(e->policy&4)suballocated_bytes+=r.length;
  else if(e->policy&2)placed_bytes+=r.length;
  else if(e->policy&1)flag_only_bytes+=r.length;
  else generation_only_bytes+=r.length;
 }
 else clean_bytes+=r.length;
}
static void report_locked(void){
 if(!diagnostics)return;
 fprintf(stderr,"[retained-policy-observer] flag_only_bytes=%llu placed_bytes=%llu suballocated_bytes=%llu generation_only_bytes=%llu\n",(unsigned long long)flag_only_bytes,(unsigned long long)placed_bytes,(unsigned long long)suballocated_bytes,(unsigned long long)generation_only_bytes);
 fprintf(stderr,"[retained-observer] events=%llu births=%llu cpu=%llu updates=%llu aliases=%llu generations=%llu deaths=%llu active=%llu peak_active=%llu passes=%llu ranges=%llu bytes=%llu union_bytes=%llu unexposed_bytes=%llu mapped_bytes=%llu updated_bytes=%llu alias_bytes=%llu policy_bytes=%llu unknown_bytes=%llu overflow=%llu invalid=%llu\n",
  (unsigned long long)events,(unsigned long long)births,(unsigned long long)cpu,(unsigned long long)updates,(unsigned long long)aliases,(unsigned long long)generations,(unsigned long long)deaths,(unsigned long long)active,(unsigned long long)peak_active,(unsigned long long)passes,(unsigned long long)ranges_seen,(unsigned long long)bytes,(unsigned long long)union_bytes,(unsigned long long)clean_bytes,(unsigned long long)mapped_bytes,(unsigned long long)updated_bytes,(unsigned long long)alias_bytes,(unsigned long long)policy_bytes,(unsigned long long)unknown_bytes,(unsigned long long)overflow,(unsigned long long)invalid);
 fprintf(stderr,"[retained-stream-observer] ranges=%llu bytes=%llu matched_bytes=%llu unexposed_bytes=%llu\n",(unsigned long long)stream_ranges,(unsigned long long)stream_bytes,(unsigned long long)stream_matched_bytes,(unsigned long long)stream_unexposed_bytes);
}
void retained_observer_pass(const RORange *v,size_t count){
 pthread_once(&once,configure);if(!enabled)return;if(count>1024||(!v&&count)){pthread_mutex_lock(&lock);invalid++;pthread_mutex_unlock(&lock);return;}
 /* Preserve every malformed-range transition that can close reference
  * authority. Sorting, union classification and coverage totals are optional. */
 if(!diagnostics){
  uint64_t bad=0;for(size_t i=0;i<count;++i){RORange r=v[i];
   if(!r.root||!r.generation||!r.handle||!r.length||r.length>UINT64_MAX-r.offset)++bad;}
  if(bad){pthread_mutex_lock(&lock);invalid+=bad;pthread_mutex_unlock(&lock);}return;
 }
 RORange sorted[1024];if(count)memcpy(sorted,v,count*sizeof(*v));qsort(sorted,count,sizeof(*v),compare);
 pthread_mutex_lock(&lock);passes++;ranges_seen+=count;RORange current={0};
 for(size_t i=0;i<count;i++){RORange r=sorted[i];bytes+=r.length;
  if(!r.root||!r.generation||!r.handle||!r.length||r.length>UINT64_MAX-r.offset){invalid++;unknown_bytes+=r.length;union_bytes+=r.length;continue;}
  if(current.length&&current.root==r.root&&current.generation==r.generation&&current.handle==r.handle&&r.offset<=current.offset+current.length){uint64_t end=r.offset+r.length;if(end>current.offset+current.length)current.length=end-current.offset;}
  else {if(current.length)classify(current);current=r;}
 }
 if(current.length)classify(current);if(passes==1||!(passes%64))report_locked();pthread_mutex_unlock(&lock);
}
void retained_observer_report(void){pthread_once(&once,configure);if(!enabled)return;pthread_mutex_lock(&lock);report_locked();pthread_mutex_unlock(&lock);}

/* Receiver independently requires the exact native version and fully defined
 * range. The producer supplies allocation/writer closure, not a guessed byte
 * witness. CPU-exposed allocations never become eligible again; Unmap publishes
 * a new ordered epoch so their ordinary snapshots can reseed native state. */
int fullframe_native_buffer_ref_authority(const ffs_producer_context *c,const ffs_producer_resource *r){
 pthread_once(&once,configure);if(!enabled||!c||!r||!c->stream||!c->frame||!c->chunk||r->kind!=FFS_BUFFER||!(r->flags&FFS_READ)||(r->flags&FFS_WRITE))return 0;
 pthread_mutex_lock(&lock);ROEntry *e=r->root?lookup(r->root,0):NULL;
 int yes=e&&!invalid&&!overflow&&e->candidate&&e->generation==r->allocation_generation&&e->handle==r->handle&&
   !(e->taint&(TAINT_POINTER|TAINT_UPDATE|TAINT_ALIAS|TAINT_DEAD))&&!(e->policy&6)&&r->offset<=e->length&&r->length&&r->length<=e->length-r->offset;
 pthread_mutex_unlock(&lock);return yes;
}

int retained_observer_diagnostics(void){pthread_once(&once,configure);return diagnostics;}

int fullframe_direct_upload_mode(void){pthread_once(&once,configure);return direct_mode;}
uint32_t fullframe_direct_upload_seal(uint64_t root,uint64_t generation,uint64_t offset,const void *bytes,size_t length,uint64_t handle,uint32_t epoch){
 pthread_once(&once,configure);if(!direct_mode)return 0;pthread_mutex_lock(&lock);ROEntry *e=lookup(root,0);int ok=0;
 if(e&&e->direct&&!invalid&&!overflow&&e->generation==generation&&e->handle==handle&&(live_commands?epoch<=e->epoch:e->epoch==epoch)&&epoch&&
    !(e->taint&(TAINT_ALIAS|TAINT_DEAD))&&bytes&&length&&length<=32u*1024u*1024u&&offset<=e->length&&length<=e->length-offset){
  direct_drop(e);if(length<=128u*1024u*1024u-direct_bytes){void *owned=malloc(length);if(owned){memcpy(owned,bytes,length);e->upload=owned;
    e->upload_length=length;e->upload_offset=offset;e->upload_generation=generation;e->upload_epoch=epoch;direct_bytes+=length;++direct_seals;ok=1;}}}
 pthread_mutex_unlock(&lock);return ok;
}
int fullframe_direct_upload_copy(uint64_t root,uint64_t generation,uint64_t offset,uint64_t handle,void *destination,size_t length){
 pthread_once(&once,configure);if(!direct_mode)return 0;pthread_mutex_lock(&lock);ROEntry *e=lookup(root,0);int ok=0;
 if(e&&e->direct&&!invalid&&!overflow&&e->generation==generation&&e->handle==handle&&e->upload&&e->upload_generation==generation&&
    e->epoch==e->upload_epoch&&!(e->taint&(TAINT_ALIAS|TAINT_DEAD))&&destination&&length&&
    offset>=e->upload_offset&&offset-e->upload_offset<=e->upload_length&&length<=e->upload_length-(offset-e->upload_offset)){
  memcpy(destination,(const char *)e->upload+(offset-e->upload_offset),length);++direct_hits;direct_copied+=length;ok=1;
 }else ++direct_misses;
 uint64_t calls=direct_hits+direct_misses;if(calls<=2||!(calls%4096)||(ok&&direct_hits<=2))fprintf(stderr,"[direct-upload] mode=%d seals=%llu hits=%llu misses=%llu copied_bytes=%llu retained_bytes=%zu births=%llu queries=%llu\n",direct_mode,(unsigned long long)direct_seals,(unsigned long long)direct_hits,(unsigned long long)direct_misses,(unsigned long long)direct_copied,direct_bytes,(unsigned long long)direct_births,(unsigned long long)direct_queries);
 pthread_mutex_unlock(&lock);return ok;
}

/* Called on the serial encoding owner, before pass publication. The first
 * reference to an epoch carries its owned update; later references carry only
 * its identity. Any failed packet aborts the stream, so publication never rolls
 * forward across a dropped update. Allocation destroy removes this state. */
void *fullframe_direct_journal_copy(uint64_t root,uint64_t generation,uint64_t offset,uint64_t handle,size_t length,size_t *total){
 if(total)*total=0;if(!ffjp_enabled()||!total)return NULL;pthread_once(&once,configure);pthread_mutex_lock(&lock);
 ROEntry *e=lookup(root,0);void *out=NULL;
 if(e&&e->direct&&!invalid&&!overflow&&e->generation==generation&&e->handle==handle&&e->upload&&
    e->upload_generation==generation&&(live_commands||e->epoch==e->upload_epoch)&&!(e->taint&(TAINT_ALIAS|TAINT_DEAD))&&
    offset>=e->upload_offset&&offset-e->upload_offset<=e->upload_length&&length&&length<=e->upload_length-(offset-e->upload_offset)){
   if(e->published_generation!=generation||e->published_epoch!=e->upload_epoch){e->published_count=0;e->published_cursor=0;e->published_generation=generation;e->published_epoch=e->upload_epoch;}
   int fresh=1;for(uint32_t i=0;i<e->published_count;i++)if(e->published_ranges[i][0]==offset&&e->published_ranges[i][1]==length){fresh=0;break;}
   ffjp_record r={.magic=FFJP_MAGIC,.root=root,.generation=generation,.epoch=e->upload_epoch,.offset=offset,
      .length=length,.bytes=fresh?length:0,.flags=fresh?FFJP_UPDATE:0};
   *total=sizeof(r)+r.bytes;out=malloc(*total);if(out){memcpy(out,&r,sizeof(r));if(r.bytes)memcpy((char*)out+sizeof(r),(const char*)e->upload+(offset-e->upload_offset),r.bytes);
     if(fresh){uint32_t slot=e->published_cursor++%8;e->published_ranges[slot][0]=offset;e->published_ranges[slot][1]=length;if(e->published_count<8)e->published_count++;}}
   else *total=0;
 }
 if(!out&&live_commands)fprintf(stderr,"[live-command-writer] found=%d direct=%u taint=%u policy=%u epoch=%u sealed_epoch=%u generation=%llu sealed_generation=%llu requested_generation=%llu sealed_length=%zu invalid=%llu overflow=%llu\n",e!=NULL,e?e->direct:0,e?e->taint:0,e?e->policy:0,e?e->epoch:0,e?e->upload_epoch:0,(unsigned long long)(e?e->generation:0),(unsigned long long)(e?e->upload_generation:0),(unsigned long long)generation,e?e->upload_length:0,(unsigned long long)invalid,(unsigned long long)overflow);
 pthread_mutex_unlock(&lock);return out;
}
