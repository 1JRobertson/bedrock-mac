#pragma once
/* Bounded writer version history. No live key is evicted. The writer owns one
 * index and serializes its operations; handles survive unrelated insertions. */
#include <array>
#include <cstddef>
#include <cstdint>
#include <limits>

namespace dxmt {
class FrameStreamVersionIndex {
public:
  static constexpr uint32_t capacity=4096, bucket_count=8192;
  enum Result:uint32_t { Ok=0, EntryCapacity=1, Invalid=2 };
  struct Handle { uint32_t slot=0; uint64_t stamp=0; };
private:
  struct Entry {
    uint64_t kind=0,root=0,generation=0,version=0,stamp=0;
    uint32_t next_hash=0,next_root=0,root_id=0,next_free=0;
    uint32_t next_raw=0,prev_raw=0;
    bool marked=false;
  };
  struct Root { uint64_t kind=0,root=0;uint32_t head=0,next_hash=0,next_free=0; };
  static_assert((bucket_count&(bucket_count-1))==0,"power-of-two bucket count");
  std::array<Entry,capacity+1> entries_{};
  std::array<Root,capacity+1> roots_{};
  std::array<uint32_t,bucket_count> exact_{},physical_{};
  std::array<Handle,capacity> writes_{};
  uint32_t entry_high_=0,root_high_=0,free_entry_=0,free_root_=0,entry_count_=0,root_count_=0;
  uint32_t raw_head_=0,write_count_=0,last_exact_steps_=0,last_root_steps_=0,last_raw_steps_=0;
  uint64_t next_stamp_=0;
  static uint64_t mix(uint64_t x) {
    x+=UINT64_C(0x9e3779b97f4a7c15);x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);
    x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb);return x^(x>>31);
  }
  static uint64_t rotate(uint64_t x,unsigned n){return (x<<n)|(x>>(64-n));}
  static uint32_t rootBucket(uint64_t kind,uint64_t root){return uint32_t(mix(mix(kind)^rotate(mix(root),21)))&(bucket_count-1);}
  static uint32_t entryBucket(uint64_t kind,uint64_t root,uint64_t generation){
    return uint32_t(mix(mix(kind)^rotate(mix(root),21)^rotate(mix(generation),42)))&(bucket_count-1);
  }
  uint32_t findRoot(uint64_t kind,uint64_t root,uint32_t &steps)const {
    uint32_t id=physical_[rootBucket(kind,root)];steps=0;
    while(id){++steps;const Root &r=roots_[id];if(r.kind==kind&&r.root==root)return id;id=r.next_hash;}return 0;
  }
  uint32_t findEntry(uint64_t kind,uint64_t root,uint64_t generation,uint32_t &steps)const {
    uint32_t id=exact_[entryBucket(kind,root,generation)];steps=0;
    while(id){++steps;const Entry &e=entries_[id];
      if(e.kind==kind&&e.root==root&&e.generation==generation)return id;id=e.next_hash;}return 0;
  }
  uint32_t allocateEntry(){uint32_t id=free_entry_;if(id)free_entry_=entries_[id].next_free;else id=++entry_high_;return id;}
  uint32_t allocateRoot(){uint32_t id=free_root_;if(id)free_root_=roots_[id].next_free;else id=++root_high_;return id;}
  Entry *resolve(Handle h,uint64_t kind,uint64_t root,uint64_t generation){
    if(!h.slot||h.slot>entry_high_||!h.stamp)return nullptr;Entry &e=entries_[h.slot];
    return e.stamp==h.stamp&&e.kind==kind&&e.root==root&&e.generation==generation?&e:nullptr;
  }
  Entry *resolve(Handle h){
    if(!h.slot||h.slot>entry_high_||!h.stamp)return nullptr;Entry &e=entries_[h.slot];
    return e.stamp==h.stamp?&e:nullptr;
  }
  void dropRoot(uint32_t id){
    Root &r=roots_[id];uint32_t *link=&physical_[rootBucket(r.kind,r.root)];
    while(*link!=id)link=&roots_[*link].next_hash;
    *link=r.next_hash;r={};r.next_free=free_root_;free_root_=id;--root_count_;
  }
  void dropEntry(uint32_t id,bool drop_empty_root){
    Entry &e=entries_[id];uint32_t root_id=e.root_id;
    uint32_t *hash=&exact_[entryBucket(e.kind,e.root,e.generation)];
    while(*hash!=id)hash=&entries_[*hash].next_hash;*hash=e.next_hash;
    uint32_t *chain=&roots_[root_id].head;
    while(*chain!=id)chain=&entries_[*chain].next_root;*chain=e.next_root;
    if(e.root&UINT64_C(0x8000000000000000)){
      if(e.prev_raw)entries_[e.prev_raw].next_raw=e.next_raw;else raw_head_=e.next_raw;
      if(e.next_raw)entries_[e.next_raw].prev_raw=e.prev_raw;
    }
    e={};e.next_free=free_entry_;free_entry_=id;--entry_count_;
    if(drop_empty_root&&!roots_[root_id].head)dropRoot(root_id);
  }
public:
  FrameStreamVersionIndex()=default;
  FrameStreamVersionIndex(const FrameStreamVersionIndex &)=delete;
  FrameStreamVersionIndex &operator=(const FrameStreamVersionIndex &)=delete;
  uint32_t count()const{return entry_count_;}
  uint32_t rootCount()const{return root_count_;}
  uint32_t pendingWrites()const{return write_count_;}
  uint32_t lastExactSteps()const{return last_exact_steps_;}
  uint32_t lastRootSteps()const{return last_root_steps_;}
  uint32_t lastRawSteps()const{return last_raw_steps_;}
  static constexpr size_t budgetBytes(){return 1024u*1024u;}
  static uint32_t testExactBucket(uint64_t kind,uint64_t root,uint64_t generation){return entryBucket(kind,root,generation);}
  static uint32_t testRootBucket(uint64_t kind,uint64_t root){return rootBucket(kind,root);}
  Result getOrCreate(uint64_t kind,uint64_t root,uint64_t generation,uint64_t &version,Handle &handle){
    if(!root)return Invalid;
    uint32_t entry=findEntry(kind,root,generation,last_exact_steps_);
    if(entry){version=entries_[entry].version;handle={entry,entries_[entry].stamp};return Ok;}
    uint32_t root_id=findRoot(kind,root,last_root_steps_);
    if(entry_count_==capacity)return EntryCapacity;
    if(next_stamp_==std::numeric_limits<uint64_t>::max())return Invalid;
    if(!root_id){
      root_id=allocateRoot();Root &r=roots_[root_id];r={};r.kind=kind;r.root=root;
      uint32_t bucket=rootBucket(kind,root);r.next_hash=physical_[bucket];physical_[bucket]=root_id;++root_count_;
    }
    entry=allocateEntry();Entry &e=entries_[entry];e={};e.kind=kind;e.root=root;e.generation=generation;e.version=1;e.stamp=++next_stamp_;e.root_id=root_id;
    uint32_t bucket=entryBucket(kind,root,generation);e.next_hash=exact_[bucket];exact_[bucket]=entry;
    e.next_root=roots_[root_id].head;roots_[root_id].head=entry;
    if(root&UINT64_C(0x8000000000000000)){e.next_raw=raw_head_;if(raw_head_)entries_[raw_head_].prev_raw=entry;raw_head_=entry;}
    ++entry_count_;version=1;handle={entry,e.stamp};return Ok;
  }
  bool setVersion(Handle h,uint64_t kind,uint64_t root,uint64_t generation,uint64_t version){
    Entry *e=resolve(h,kind,root,generation);if(!e||!version)return false;e->version=version;return true;
  }
  bool markWrite(Handle h,uint64_t kind,uint64_t root,uint64_t generation){
    Entry *e=resolve(h,kind,root,generation);if(!e||e->version==UINT64_MAX)return false;
    if(!e->marked){if(write_count_==capacity)return false;e->marked=true;writes_[write_count_++]=h;}return true;
  }
  /* Validate all marks first, so failure cannot partly commit an encoder. */
  bool commitWrites(){
    for(uint32_t i=0;i<write_count_;++i){Entry *e=resolve(writes_[i]);if(!e||!e->marked||e->version==UINT64_MAX)return false;}
    for(uint32_t i=0;i<write_count_;++i){Entry *e=resolve(writes_[i]);++e->version;e->marked=false;}
    write_count_=0;return true;
  }
  void clearWrites(){
    for(uint32_t i=0;i<write_count_;++i){Entry *e=resolve(writes_[i]);if(e)e->marked=false;}write_count_=0;
  }
  void retire(uint64_t kind,uint64_t root,uint64_t generation){
    uint32_t steps=0;uint32_t root_id=findRoot(kind,root,steps);if(!root_id)return;
    if(generation){uint32_t id=findEntry(kind,root,generation,steps);if(id)dropEntry(id,true);return;}
    while(roots_[root_id].head)dropEntry(roots_[root_id].head,false);dropRoot(root_id);
  }
  void retireRawBuffers(uint64_t buffer_kind){
    last_raw_steps_=0;for(uint32_t id=raw_head_;id;){uint32_t next=entries_[id].next_raw;++last_raw_steps_;
      if(entries_[id].kind==buffer_kind)dropEntry(id,true);id=next;}
  }
};
static_assert(sizeof(FrameStreamVersionIndex)<=FrameStreamVersionIndex::budgetBytes(),"source version index budget");
}
