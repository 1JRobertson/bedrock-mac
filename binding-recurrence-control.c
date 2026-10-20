/* SPDX-License-Identifier: GPL-3.0-or-later */
/* Native arm64 control/snapshot utility. No game-memory access or launch. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "binding_control.h"
static const char *names[]={"calls","bytes","valid","unexpected_size","abi_mismatch","history_exact","history_same_source","consecutive_exact","consecutive_same_source","consecutive_source_equal","hash_collisions","history_misses","evictions","run_max","comparison_bytes","reserved"};
static int snapshot(const struct bbr_row *from,struct bbr_row *to)
{
    unsigned attempt,j;uint64_t first,last;uint64_t *out=(uint64_t *)to;
    const uint64_t *in=(const uint64_t *)from;
    for(attempt=0;attempt<10000;attempt++){
        first=__atomic_load_n(&from->sequence,__ATOMIC_ACQUIRE);if(first&1)continue;
        for(j=0;j<sizeof(*to)/8;j++)out[j]=__atomic_load_n(&in[j],__ATOMIC_RELAXED);
        __atomic_thread_fence(__ATOMIC_ACQUIRE);
        last=__atomic_load_n(&from->sequence,__ATOMIC_ACQUIRE);
        if(first==last&&!(last&1))return 1;
    }
    return 0;
}
int main(int argc,char **argv)
{
    int fd,write;struct stat st;struct bbr_control *c;unsigned i,s,j,printed=0;
    if(argc!=3|| (strcmp(argv[2],"status")&&strcmp(argv[2],"arm")&&strcmp(argv[2],"stop"))){
        fprintf(stderr,"usage: %s FRESH_OBSERVER_CONTROL status|arm|stop\n",argv[0]);return 2;
    }
    write=strcmp(argv[2],"status")!=0;
    fd=open(argv[1],write?O_RDWR:O_RDONLY);
    if(fd<0||fstat(fd,&st)||st.st_size!=sizeof(*c)){fprintf(stderr,"invalid control file\n");return 3;}
    c=mmap(NULL,sizeof(*c),PROT_READ|(write?PROT_WRITE:0),MAP_SHARED,fd,0);
    if(c==MAP_FAILED){perror("mmap");return 3;}
    if(c->magic!=BBR_MAGIC||c->version!=1||c->size!=sizeof(*c)||c->threads_count!=BBR_THREADS||
       c->row_size!=sizeof(struct bbr_row)||c->call_limit!=BBR_CALL_LIMIT||c->record_bytes!=BBR_RECORD_BYTES||
       c->cache_slots!=BBR_SLOTS||c->site_count!=BBR_SITES){fprintf(stderr,"control ABI mismatch\n");return 4;}
    if(write)__atomic_store_n(&c->armed,!strcmp(argv[2],"arm"),__ATOMIC_RELEASE);
    printf("{\"armed\":%llu,\"per_thread_call_limit\":%llu,\"record_bytes\":%llu,\"cache_slots\":%llu,\"threads\":[",
        (unsigned long long)__atomic_load_n(&c->armed,__ATOMIC_ACQUIRE),(unsigned long long)c->call_limit,
        (unsigned long long)c->record_bytes,(unsigned long long)c->cache_slots);
    for(i=0;i<BBR_THREADS;i++){
        struct bbr_row row;
        if(!snapshot(&c->threads[i],&row)){fprintf(stderr,"busy snapshot for thread%u\n",i);return 5;}
        if(!row.sequence)continue;
        printf("%s{\"slot\":%u,\"calls\":%llu,\"inside_worker\":%llu,\"outside_worker\":%llu,\"completed_workers\":%llu,\"exceptions\":%llu,\"sites\":[",printed++?",":"",i,
            (unsigned long long)row.calls,(unsigned long long)row.inside_worker,(unsigned long long)row.outside_worker,
            (unsigned long long)row.completed_workers,(unsigned long long)row.exceptions);
        for(s=0;s<BBR_SITES;s++){
            uint64_t *values=(uint64_t *)&row.sites[s];
            printf("%s{\"site\":%u",s?",":"",s);
            for(j=0;j<sizeof(names)/sizeof(names[0]);j++)printf(",\"%s\":%llu",names[j],(unsigned long long)values[j]);
            printf("}");
        }
        printf("]}");
    }
    printf("]}\n");munmap(c,sizeof(*c));close(fd);return 0;
}
