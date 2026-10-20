/* SPDX-License-Identifier: GPL-3.0-or-later */
#include <assert.h>
#include <stdio.h>
#include "binding_core.h"
static struct bbr_history h;
static unsigned char a[BBR_RECORD_BYTES],b[BBR_RECORD_BYTES];
static uint64_t total(unsigned member){uint64_t sum=0;for(unsigned s=0;s<BBR_SITES;s++)sum+=((uint64_t *)&h.sites[s])[member];return sum;}
static void observe(unsigned site,uint64_t source,const void *p){assert(bbr_observe(&h,site,source,p,p,BBR_RECORD_BYTES));}
int main(void)
{
    uint32_t hash=0x12345678;memcpy(a+BBR_HASH_OFFSET,&hash,4);memcpy(b,a,sizeof(a));b[9]=1;
    observe(0,100,a);observe(1,200,b);observe(2,100,a);observe(0,100,a);
    assert(h.calls==4&&h.sites[2].history_exact==1&&h.sites[0].consecutive_exact==1);
    assert(h.sites[0].consecutive_same_source==1&&h.sites[0].run_max==2);
    assert(h.sites[1].hash_collisions==1&&h.sites[2].hash_collisions>=1);
    // Same opaque address does not imply same content, lifetime or resource.
    observe(1,100,b);assert(h.sites[1].consecutive_source_equal==1&&h.sites[1].consecutive_exact==0);
    // Historical payloads are owned copies and survive mutation of the input.
    a[17]=7;observe(2,100,a);a[17]=0;observe(0,100,a);assert(h.sites[0].history_exact==2);
    memset(&h,0,sizeof(h));observe(0,100,a);observe(1,200,a);
    assert(h.sites[1].consecutive_exact==1&&h.sites[1].consecutive_source_equal==0&&h.sites[1].history_same_source==0);
    observe(2,200,a);assert(h.sites[2].consecutive_same_source==1&&h.sites[2].history_same_source==1);
    memset(&h,0,sizeof(h));observe(0,100,a);
    // Differential mutation: changing ANY of the1044bytes must fail equality,
    // including forced same-hash collisions and the hash field itself.
    for(unsigned j=0;j<BBR_RECORD_BYTES;j++){
        uint64_t hits=total(5);memcpy(b,a,sizeof(b));b[j]^=1;
        observe(j%3,100,b);assert(total(5)==hits);
        observe((j+1)%3,100,a);assert(total(5)==hits+1);
    }
    assert(total(12)>0); // bounded LRU saturation does not invent recurrence
    bbr_break_sequence(&h);observe(0,100,a);assert(h.run==1);
    uint64_t calls=h.calls;
    assert(!bbr_observe(&h,3,0,NULL,NULL,BBR_RECORD_BYTES)&&h.calls==calls);
    assert(bbr_observe(&h,0,0,NULL,NULL,1)&&h.sites[0].unexpected_size==1&&!h.last_valid);
    assert(bbr_observe(&h,1,0,a,b,BBR_RECORD_BYTES)&&h.sites[1].abi_mismatch==1&&!h.last_valid);
    while(h.calls<BBR_CALL_LIMIT)observe(0,100,a);
    assert(total(0)==h.calls);calls=h.calls;assert(!bbr_observe(&h,0,0,(void *)1,(void *)1,BBR_RECORD_BYTES)&&h.calls==calls);
    puts("PASS all-site shared history, exact consecutive/source counters,1044single-byte mutations, forced collisions, owned snapshots, LRU, bounds and16384cap");
}
