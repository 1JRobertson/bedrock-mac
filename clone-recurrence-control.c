/* Native arm64 control/snapshot utility. No game-memory access or launch. */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>
#include "observer_control.h"
static const char *names[]={"calls","bytes","zero","oversized","invalid","sampled","comparisons","exact_payload","exact_metadata","same_observed_token","different_known_frames","different_known_scopes","exact_repeated_bytes","replacements","comparison_misses","clock_unknown"};
static int snapshot(const struct bcr_row *from,struct bcr_row *to)
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
    int fd,write;struct stat st;struct bcr_control *c;unsigned i,s,j,printed=0;
    if(argc!=3|| (strcmp(argv[2],"status")&&strcmp(argv[2],"arm")&&strcmp(argv[2],"stop"))){
        fprintf(stderr,"usage: %s FRESH_OBSERVER_CONTROL status|arm|stop\n",argv[0]);return 2;
    }
    write=strcmp(argv[2],"status")!=0;
    fd=open(argv[1],write?O_RDWR:O_RDONLY);
    if(fd<0||fstat(fd,&st)||st.st_size!=sizeof(*c)){fprintf(stderr,"invalid control file\n");return 3;}
    c=mmap(NULL,sizeof(*c),PROT_READ|(write?PROT_WRITE:0),MAP_SHARED,fd,0);
    if(c==MAP_FAILED){perror("mmap");return 3;}
    if(c->magic!=BCR_MAGIC||c->version!=1||c->size!=sizeof(*c)||c->threads_count!=BCR_THREADS||
       c->row_size!=sizeof(struct bcr_row)||c->call_limit!=BCR_CALL_LIMIT||c->sample_mask!=CR_SAMPLE_MASK||
       c->payload_limit!=CR_MAX_PAYLOAD||c->cache_slots!=CR_SLOTS){fprintf(stderr,"control ABI mismatch\n");return 4;}
    if(write)__atomic_store_n(&c->armed,!strcmp(argv[2],"arm"),__ATOMIC_RELEASE);
    printf("{\"armed\":%llu,\"per_thread_call_limit\":%llu,\"sample_mask\":%llu,\"cache_slots\":%llu,\"threads\":[",
        (unsigned long long)__atomic_load_n(&c->armed,__ATOMIC_ACQUIRE),(unsigned long long)c->call_limit,
        (unsigned long long)c->sample_mask,(unsigned long long)c->cache_slots);
    for(i=0;i<BCR_THREADS;i++){
        struct bcr_row row;
        if(!snapshot(&c->threads[i],&row)){fprintf(stderr,"busy snapshot for thread%u\n",i);return 5;}
        if(!row.sequence)continue;
        printf("%s{\"slot\":%u,\"calls\":%llu,\"inside_worker\":%llu,\"outside_worker\":%llu,\"abi_mismatch\":%llu,\"completed_workers\":%llu,\"exceptions\":%llu,\"sites\":[",printed++?",":"",i,
            (unsigned long long)row.calls,(unsigned long long)row.inside_worker,(unsigned long long)row.outside_worker,
            (unsigned long long)row.abi_mismatch,(unsigned long long)row.completed_workers,(unsigned long long)row.exceptions);
        for(s=0;s<BCR_SITES;s++){
            uint64_t *values=(uint64_t *)&row.sites[s];
            printf("%s{\"site\":%u",s?",":"",s);
            for(j=0;j<sizeof(names)/sizeof(names[0]);j++)printf(",\"%s\":%llu",names[j],(unsigned long long)values[j]);
            printf("}");
        }
        printf("]}");
    }
    printf("]}\n");munmap(c,sizeof(*c));close(fd);return 0;
}
