#include "shader_pair.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define MAX_METALLIB (16u*1024u*1024u)
static int dir=-1;
static _Atomic int claimed;
__attribute__((constructor)) static void setup(void) {
    const char *path=getenv("BEDROCK_FULLFRAME_SHADER_PAIR_DIR"); struct stat s;
    if(!path||path[0]!='/')return;
    int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return;
    if(fstat(fd,&s)||!S_ISDIR(s.st_mode)||s.st_uid!=getuid()||(s.st_mode&077)) { close(fd); return; }
    dir=fd;
}
int ff_shader_pair_claim(void) {
    if(dir<0)return 0;
    struct stat s; char token[4]; int fd=openat(dir,"shader-pair.arm",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return 0;
    int valid=!fstat(fd,&s)&&S_ISREG(s.st_mode)&&s.st_uid==getuid()&&s.st_nlink==1&&s.st_size==4&&
        read(fd,token,4)==4&&!memcmp(token,"arm\n",4);
    close(fd); if(!valid)return 0;
    int expected=0;return atomic_compare_exchange_strong(&claimed,&expected,1);
}
void ff_shader_pair_abandon(void) { atomic_store(&claimed,0); }
static int write_file(const char *name,const void *data,size_t size) {
    int fd=openat(dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return 0;
    const unsigned char *p=data; size_t left=size; int good=1;
    while(left) { ssize_t n=write(fd,p,left); if(n<0&&errno==EINTR)continue; if(n<=0){good=0;break;} p+=n; left-=(size_t)n; }
    if(good&&fsync(fd))good=0; if(close(fd))good=0;
    if(!good)unlinkat(dir,name,0); return good;
}
void ff_shader_pair_publish(const void *original,size_t original_size,const void *native,size_t native_size) {
    int a=0,b=0,c=0,la=0,lb=0,ok=0;
    if(!original||!native||original_size<32||native_size<32||original_size>MAX_METALLIB||native_size>MAX_METALLIB)goto done;
    unsigned char x[CC_SHA256_DIGEST_LENGTH],y[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(original,(CC_LONG)original_size,x); CC_SHA256(native,(CC_LONG)native_size,y);
    char hx[65],hy[65],record[256];
    for(unsigned i=0;i<32;i++) { snprintf(hx+2*i,3,"%02x",x[i]); snprintf(hy+2*i,3,"%02x",y[i]); }
    int n=snprintf(record,sizeof(record),"{\"format\":\"bedrock-shader-pair\",\"version\":1,\"original_sha256\":\"%s\",\"native_sha256\":\"%s\"}\n",hx,hy);
    if(n<=0||(size_t)n>=sizeof(record))goto done;
    if(!(a=write_file(".pair-original.tmp",original,original_size))||
       !(b=write_file(".pair-native.tmp",native,native_size))||
       !(c=write_file(".pair-ready.tmp",record,(size_t)n)))goto done;
    if(!(la=linkat(dir,".pair-original.tmp",dir,"pair-original.metallib",0)==0))goto done;
    if(!(lb=linkat(dir,".pair-native.tmp",dir,"pair-native.metallib",0)==0))goto done;
    if(linkat(dir,".pair-ready.tmp",dir,"pair-ready.json",0))goto done;
    ok=1;unlinkat(dir,"shader-pair.arm",0);
done:
    if(!ok&&la)unlinkat(dir,"pair-original.metallib",0);
    if(!ok&&lb)unlinkat(dir,"pair-native.metallib",0);
    if(a)unlinkat(dir,".pair-original.tmp",0); if(b)unlinkat(dir,".pair-native.tmp",0); if(c)unlinkat(dir,".pair-ready.tmp",0);
    fprintf(stderr,"[full-frame-shader-pair] %s\n",ok?"complete":"failed");
    if(!ok)ff_shader_pair_abandon();
}
