// SPDX-License-Identifier: GPL-3.0-or-later
// Executes only three exact, read-only-extracted allocator functions against fake
// objects. Native x64 test (Rosetta on Apple Silicon); no Wine/game launched.
#include <algorithm>
#include <array>
#include <atomic>
#include <cassert>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <thread>
#include <vector>
#include <sys/mman.h>
#include <unistd.h>
#include <csetjmp>
#include "current_reserve.h"
struct alignas(16) Arena { std::array<unsigned char,0xb0> b{}; };
struct alignas(16) Parent { std::array<unsigned char,0xa0> b{}; };
struct alignas(16) Owner { uint64_t vtable=0; uint32_t strong=1,weak=1; };
struct alignas(16) Desc { uint64_t backing,owner,offset,size,padding,generation; unsigned char tail[16]; };
static_assert(offsetof(Desc,tail)==0x30);
using Fn=Desc *(__attribute__((ms_abi)) *)(void *,Desc *,uint64_t,uint64_t);
static void put(void *p,size_t o,uint64_t v){std::memcpy((char*)p+o,&v,8);}
static uint64_t get(const void*p,size_t o){uint64_t v;std::memcpy(&v,(char*)p+o,8);return v;}
struct Fixture {
 Arena a; Parent p; Owner owner; uint64_t backing=0xdeadbeef;
 Fixture(uint64_t start1,uint64_t len1,uint64_t cur1,uint64_t start2,uint64_t len2,uint64_t cur2){
  put(&a,0,(uintptr_t)&backing);put(&a,8,(uintptr_t)&owner);put(&a,0x10,1<<24);
  put(&a,0x48,start1);put(&a,0x50,len1);put(&a,0x58,cur1);
  put(&a,0x60,start2);put(&a,0x68,len2);put(&a,0x70,cur2);put(&a,0x88,31);
  put(&p,0,(uintptr_t)&a);
 }
};
static void tail(const Desc&d){for(auto c:d.tail)assert(c==0xa5);}
static Fn original_wrapper;
static std::jmp_buf slow_return;
static void *slow_expected_lock;
__attribute__((noinline,ms_abi)) static void slow_boundary(void *lock){assert(lock==slow_expected_lock);std::longjmp(slow_return,1);}
static void install_relay(unsigned char*image,unsigned site,unsigned relay_offset,void *target){
 auto relay=image+relay_offset;relay[0]=0xff;relay[1]=0x25;memset(relay+2,0,4);uint64_t destination=(uintptr_t)target;memcpy(relay+6,&destination,8);
 assert(image[site]==0xe8);int32_t delta=relay_offset-(site+5);memcpy(image+site+1,&delta,4);
}
__attribute__((noinline,ms_abi)) static Desc *current_entry(void*a,Desc*d,uint64_t n,uint64_t align){if(bad_try_current(a,d,n,align))return d;return original_wrapper(a,d,n,align);}
static void desc(const Desc&d,const Fixture&f,uint64_t n){
 assert(d.backing==(uintptr_t)&f.backing&&d.owner==(uintptr_t)&f.owner);
 assert(d.size==n&&d.padding==0&&d.generation==31);tail(d);
}
static void same(const Fixture&a,const Fixture&b){
 for(size_t o:{0x40,0x48,0x50,0x58,0x60,0x68,0x70,0x78,0x88,0x90})assert(get(&a.a,o)==get(&b.a,o));
 assert(!memcmp(&a.a.b[0x80],&b.a.b[0x80],2));assert(a.a.b[0x98]==b.a.b[0x98]);
 assert(get(&a.p,8)==get(&b.p,8)&&get(&a.p,0x18)==get(&b.p,0x18));
 assert(a.owner.strong==b.owner.strong&&a.owner.weak==b.owner.weak);
}
static uint64_t rng(uint64_t &s){s^=s<<13;s^=s>>7;s^=s<<17;return s;}
static unsigned long differential(Fn general,Fn wrapper,Fn candidate_general){
 uint64_t seed=0x879923a;unsigned long calls=0;
 for(unsigned j=0;j<16000;j++){
  uint64_t s1=rng(seed)%4096,l1=rng(seed)%4096,c1=s1+rng(seed)%(l1+1);
  uint64_t s2=8192+rng(seed)%4096,l2=rng(seed)%4096,c2=s2+rng(seed)%(l2+1),n=1+rng(seed)%1024;
  Fixture reference(s1,l1,c1,s2,l2,c2),candidate(s1,l1,c1,s2,l2,c2);
  Desc d1,d2;memset(&d1,0xa5,sizeof(d1));memset(&d2,0xa5,sizeof(d2));
  bool expected=n<=s1+l1-c1||n<=s2+l2-c2;
  if(expected){assert(general(&reference.p,&d1,n,1)==&d1);assert(candidate_general(&candidate.p,&d2,n,1)==&d2);
   desc(d1,reference,n);desc(d2,candidate,n);assert(d1.offset==d2.offset);}
  else {assert(wrapper(&reference.p,&d1,n,1)==&d1);assert(d1.tail[0]==0);assert(current_entry(&candidate.p,&d2,n,1)==&d2);assert(d2.tail[0]==0);
   for(size_t byte=0;byte<sizeof(Desc);byte++)assert(((unsigned char*)&d2)[byte]==(byte==0x30?0:0xa5));}
  same(reference,candidate);calls++;
 }
 // Wrapped second interval, counter wrap, no-owner case and fallback gates.
 for(unsigned mode=0;mode<4;mode++)for(unsigned n:{0u,1u,528u,1024u,1025u})for(unsigned alignment:{1u,2u,16u}){
  Fixture f(0,8192,0,8192,0,8192);put(&f.p,0x90,mode);Desc d;memset(&d,0xa5,sizeof(d));
  auto before=f;const bool eligible=mode==0&&n>0&&n<=1024&&alignment==1;
  assert(bool(bad_try_current(&f.p,&d,n,alignment))==eligible);
  if(!eligible){assert(!memcmp(&f,&before,sizeof(f)));for(auto c:reinterpret_cast<const std::array<unsigned char,sizeof(Desc)>&>(d))assert(c==0xa5);}
 }
 for(bool null_owner:{false,true}){
  Fixture f(64,256,320,0,64,0); if(null_owner)put(&f.a,8,0);f.a.b[0x80]=0xfe;f.a.b[0x81]=0xff;
  for(unsigned i=0;i<2;i++){Desc d;memset(&d,0xa5,sizeof(d));assert(bad_try_current(&f.p,&d,32,1));assert(d.offset==i*32);assert(d.owner==(null_owner?0:(uintptr_t)&f.owner));assert(d.tail[0]==1);d.tail[0]=0xa5;tail(d);}
  assert(!f.a.b[0x80]&&!f.a.b[0x81]);assert(f.owner.strong==(null_owner?1u:3u));
 }
 return calls;
}
static unsigned long concurrent(Fn general){
 constexpr unsigned threads=7,iterations=4096;Fixture f(0,1<<24,0,1<<24,0,1<<24);
 std::vector<Desc> results(threads*iterations);std::atomic<unsigned> ready{0};std::atomic<bool> go{false};std::vector<std::thread> pool;
 for(unsigned t=0;t<threads;t++)pool.emplace_back([&,t]{uint64_t seed=t+12345;ready++;while(!go.load())std::this_thread::yield();
  for(unsigned i=0;i<iterations;i++){auto&d=results[t*iterations+i];memset(&d,0xa5,sizeof(d));auto n=1+rng(seed)%1024;
   assert(general(&f.p,&d,n,1)==&d);desc(d,f,n);
   __atomic_fetch_sub(&f.owner.strong,1,__ATOMIC_SEQ_CST);
  }});
 while(ready.load()!=threads)std::this_thread::yield();go=true;for(auto&t:pool)t.join();
 std::sort(results.begin(),results.end(),[](auto&a,auto&b){return a.offset<b.offset;});uint64_t cursor=0;
 for(auto&d:results){assert(d.offset==cursor);cursor+=d.size;}
 assert(get(&f.a,0x58)==cursor&&get(&f.a,0x40)==cursor&&get(&f.a,0x78)==cursor&&get(&f.p,0x18)==cursor);
 assert(get(&f.p,8)==0&&f.owner.strong==1);uint16_t attempts;memcpy(&attempts,&f.a.b[0x80],2);assert(attempts==uint16_t(results.size()));
 return results.size();
}
static unsigned fallback_boundaries(Fn original,Fn candidate){
 unsigned cases=0;
 for(unsigned n=11;n<=20;n++)for(bool null_arena:{false,true}){
  Fixture a(0,10,0,20,10,20),b(0,10,0,20,10,20);if(null_arena){put(&a.p,0,0);put(&b.p,0,0);}
  Desc da,db;memset(&da,0xa5,sizeof(da));memset(&db,0xa5,sizeof(db));
  slow_expected_lock=(char*)&a.p+0x88;
  if(!setjmp(slow_return)){original(&a.p,&da,n,1);assert(!"general unexpectedly returned before slow boundary");}
  slow_expected_lock=(char*)&b.p+0x88;
  if(!setjmp(slow_return)){candidate(&b.p,&db,n,1);assert(!"candidate unexpectedly returned before slow boundary");}
  same(a,b);assert(!memcmp(&da,&db,sizeof(da)));assert(get(&a.p,8)==0&&get(&a.p,0x18)==0);
  uint16_t attempts;memcpy(&attempts,&a.a.b[0x80],2);assert(attempts==(null_arena?0:1));cases++;
 }
 return cases;
}
int main(int argc,char**argv){
 assert(argc==2);std::ifstream file(argv[1],std::ios::binary);std::vector<char> code((std::istreambuf_iterator<char>(file)),{});assert(code.size()==8192);
 void*memory=mmap(nullptr,code.size(),PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(memory!=MAP_FAILED);memcpy(memory,code.data(),code.size());install_relay((unsigned char*)memory,0xd6b,0x1f20,(void*)slow_boundary);assert(!mprotect(memory,code.size(),PROT_READ|PROT_EXEC));
 Fn general=(Fn)((char*)memory+0xc70),wrapper=(Fn)((char*)memory+0x1320);
 original_wrapper=wrapper;
 void*patched=mmap(nullptr,code.size(),PROT_READ|PROT_WRITE,MAP_ANON|MAP_PRIVATE,-1,0);assert(patched!=MAP_FAILED);memcpy(patched,code.data(),code.size());
 auto relay=(unsigned char*)patched+0x1f00;relay[0]=0xff;relay[1]=0x25;memset(relay+2,0,4);uint64_t destination=(uintptr_t)current_entry;memcpy(relay+6,&destination,8);
 install_relay((unsigned char*)patched,0xd6b,0x1f20,(void*)slow_boundary);
 auto site=(unsigned char*)patched+0xcc2;assert(site[0]==0xe8);int32_t delta=0x1f00-(0xcc2+5);memcpy(site+1,&delta,4);assert(!mprotect(patched,code.size(),PROT_READ|PROT_EXEC));
 Fn candidate_general=(Fn)((char*)patched+0xc70);
 auto cases=differential(general,wrapper,candidate_general);auto fallback_cases=fallback_boundaries(general,candidate_general);assert(fallback_cases==20);auto original=concurrent(general),candidate=concurrent(candidate_general);munmap(memory,code.size());munmap(patched,code.size());
 printf("{\"passed\":true,\"differential_cases\":%lu,\"concurrent_calls_each\":%lu,\"threads\":7,\"copied_original_x64_instructions\":true,\"candidate_actual_header\":true,\"current_wrapper_call_substituted_in_copied_general\":true,\"general_slow_path_executed\":false,\"general_slow_boundary_intercepted_cases\":20,\"game_entrypoint_executed\":false,\"performance_claim\":false}\n",cases,original);assert(original==candidate);return 0;
}
