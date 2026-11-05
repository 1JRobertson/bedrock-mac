/* Opt-in shadow translation: original x86 compilation remains authoritative. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "shader_variant.h"
#include "shader_protocol.h"
#include "shader_pair.h"
#include "shader_handles.h"
#include <CommonCrypto/CommonDigest.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#define MAX_SHADERS 256
#define MAX_BYTES (16u*1024u*1024u)
struct shader_entry { void *handle; void *bytes; size_t length; };
static struct shader_entry shaders[MAX_SHADERS];
static size_t tracked;
static pthread_mutex_t lock=PTHREAD_MUTEX_INITIALIZER;
static _Atomic int busy, attempted;
static int substitute;
static char endpoint[sizeof(((struct sockaddr_un *)0)->sun_path)];
static dispatch_queue_t queue;
__attribute__((constructor)) static void shader_client_setup(void) {
    const char *p=getenv("BEDROCK_FULLFRAME_SHADER_SOCKET");
    if(!p||p[0]!='/'||strlen(p)>=sizeof(endpoint))return;
    const char *mode=getenv("BEDROCK_FULLFRAME_SHADER_SUBSTITUTE"); substitute=mode&&!strcmp(mode,"1");
    strcpy(endpoint,p); queue=dispatch_queue_create("bedrock.shader.shadow",DISPATCH_QUEUE_SERIAL);
}
int ff_shader_service_enabled(void) { return queue != NULL; }
void ff_shader_track(void *shader,const void *data,size_t length) {
    if(!queue||!shader||!data||length<32||length>FF_SHADER_MAX_DXBC||memcmp(data,"DXBC",4))return;
    pthread_mutex_lock(&lock);
    if(length<=MAX_BYTES-tracked) for(unsigned i=0;i<MAX_SHADERS;i++) if(!shaders[i].handle) {
        void *copy=malloc(length); if(copy) { memcpy(copy,data,length); shaders[i]=(struct shader_entry){shader,copy,length}; tracked+=length; } break;
    }
    pthread_mutex_unlock(&lock);
}
void ff_shader_untrack(void *shader) {
    pthread_mutex_lock(&lock); for(unsigned i=0;i<MAX_SHADERS;i++) if(shaders[i].handle==shader) {
        tracked-=shaders[i].length; free(shaders[i].bytes); memset(&shaders[i],0,sizeof(shaders[i])); break;
    } pthread_mutex_unlock(&lock);
}
struct request { struct ff_shader_request header; uint32_t variant[FF_VARIANT_WORDS]; char name[256];
    void *dxbc; void *original; size_t original_size; int pair; unsigned char reference[CC_SHA256_DIGEST_LENGTH]; };
static void *send_request(struct request *r,void *original_handle) {
    void *replacement=NULL;
    int fd=-1,ok=0; unsigned char *result=NULL; struct sockaddr_un address={0};
    address.sun_family=AF_UNIX; strcpy(address.sun_path,endpoint);
    fd=socket(AF_UNIX,SOCK_STREAM,0); if(fd<0)goto done;
    int one=1; setsockopt(fd,SOL_SOCKET,SO_NOSIGPIPE,&one,sizeof(one));
    if(fcntl(fd,F_SETFL,O_NONBLOCK)<0)goto done;
    int64_t deadline=ff_shader_now()+FF_SHADER_TIMEOUT_MS;
    int rc=connect(fd,(struct sockaddr *)&address,sizeof(address));
    if(rc<0&&errno==EINPROGRESS) {
        struct pollfd item={fd,POLLOUT,0}; int error=0; socklen_t n=sizeof(error);
        if(poll(&item,1,FF_SHADER_TIMEOUT_MS)<=0||getsockopt(fd,SOL_SOCKET,SO_ERROR,&error,&n)||error)goto done;
    } else if(rc<0)goto done;
    uid_t uid; gid_t gid; if(getpeereid(fd,&uid,&gid)||uid!=getuid())goto done;
    if(!ff_shader_io(fd,&r->header,sizeof(r->header),1,deadline)||
       !ff_shader_io(fd,r->name,r->header.name,1,deadline)||
       !ff_shader_io(fd,r->dxbc,r->header.dxbc,1,deadline)||
       !ff_shader_io(fd,r->variant,r->header.variant,1,deadline))goto done;
    struct ff_shader_response h;
    if(!ff_shader_io(fd,&h,sizeof(h),0,deadline)||h.magic!=FF_SHADER_MAGIC||h.version!=1||h.status||
       h.length<32||h.length>FF_SHADER_MAX_METAL)goto done;
    result=malloc(h.length); if(!result||!ff_shader_io(fd,result,h.length,0,deadline))goto done;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH]; CC_SHA256(result,h.length,digest);
    if(r->pair) { ff_shader_pair_publish(r->original,r->original_size,result,h.length); r->pair=0; }
    fprintf(stderr,"[full-frame-shader-service] translated bytes=%u byte_identical=%s\n",h.length,
            memcmp(digest,r->reference,sizeof(digest))?"false":"true"); ok=1;
    if(original_handle) {
        @autoreleasepool {
            id<MTLDevice> device=MTLCreateSystemDefaultDevice(); NSError *error=nil;
            dispatch_data_t data=dispatch_data_create(result,h.length,NULL,NULL);
            id<MTLLibrary> library=data?[device newLibraryWithData:data error:&error]:nil;
            id<MTLFunction> function=[library newFunctionWithName:[NSString stringWithUTF8String:r->name]];
            if(function)replacement=ff_shader_handle_create(original_handle,result,h.length);
            fprintf(stderr,"[full-frame-shader-substitution] local_load=%s shim=%s\n",function?"accepted":"rejected",replacement?"created":"fallback");
            [function release]; [library release]; if(data)dispatch_release(data);
        }
    }
done:
    if(!ok)fprintf(stderr,"[full-frame-shader-service] skipped-or-failed; original retained\n");
    if(r->pair)ff_shader_pair_abandon();
    if(fd>=0)close(fd); free(result); free(r->original); free(r->dxbc); free(r); atomic_store(&busy,0);
    return replacement;
}
void *ff_shader_compare(void *shader,struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *args,const char *name,
                       const void *reference,size_t reference_size,void *original_handle) {
    if(!queue||!shader||!name||!reference||reference_size<32||reference_size>FF_SHADER_MAX_METAL)return original_handle;
    size_t name_size=strnlen(name,FF_SHADER_MAX_NAME+1); if(!ff_shader_name_valid(name,name_size)||atomic_exchange(&busy,1))return original_handle;
    struct request *r=calloc(1,sizeof(*r)); if(!r) { atomic_store(&busy,0); return original_handle; }
    size_t variant_size=0; if(!ff_variant_encode(args,r->variant,&variant_size))goto fail;
    pthread_mutex_lock(&lock);
    for(unsigned i=0;i<MAX_SHADERS;i++) if(shaders[i].handle==shader) {
        r->dxbc=malloc(shaders[i].length); if(r->dxbc) { memcpy(r->dxbc,shaders[i].bytes,shaders[i].length); r->header.dxbc=(uint32_t)shaders[i].length; } break;
    }
    pthread_mutex_unlock(&lock);
    if(!r->dxbc)goto fail;
    CC_SHA256(r->dxbc,r->header.dxbc,(unsigned char *)(r->variant+3)); CC_SHA256(reference,(CC_LONG)reference_size,r->reference);
    if(ff_shader_pair_claim()) {
        r->original=malloc(reference_size);
        if(r->original) { memcpy(r->original,reference,reference_size); r->original_size=reference_size; r->pair=1; }
        else ff_shader_pair_abandon();
    }
    memcpy(r->name,name,name_size); r->header.magic=FF_SHADER_MAGIC; r->header.version=1;
    r->header.name=(uint32_t)name_size; r->header.variant=(uint32_t)variant_size;
    if(substitute) {
        if(atomic_exchange(&attempted,1))goto fail;
        void *replacement=send_request(r,original_handle);
        return replacement?replacement:original_handle;
    }
    dispatch_async(queue,^{(void)send_request(r,NULL);}); return original_handle;
fail:
    if(r->pair)ff_shader_pair_abandon();
    free(r->original); free(r->dxbc); free(r); atomic_store(&busy,0); return original_handle;
}
