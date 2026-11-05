/* One explicitly armed, bounded full-game drawable snapshot; opt-in only. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <dispatch/dispatch.h>
#include <stdatomic.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <errno.h>
#include <pthread.h>
#include <CommonCrypto/CommonDigest.h>
#include "shader_variant.h"

static int frame_dir = -1;
static _Atomic int claimed;
#define MAX_TRACKED_SHADERS 256
#define MAX_TRACKED_BYTES (16U*1024U*1024U)
struct tracked_shader { void *shader; void *bytes; size_t length; };
static struct tracked_shader tracked[MAX_TRACKED_SHADERS];
static size_t tracked_bytes;
static pthread_mutex_t shader_lock=PTHREAD_MUTEX_INITIALIZER;
static int shader_done;
static dispatch_queue_t writer;
struct frame_context { id<MTLBuffer> buffer; uint32_t width,height,stride,format; size_t bytes; };

static int write_all(int fd,const void *source,size_t count) {
    const unsigned char *at=source;
    while(count) { ssize_t n=write(fd,at,count); if(n<0&&errno==EINTR)continue; if(n<=0)return 0; at+=n;count-=(size_t)n; }
    return 1;
}
static int put_u32(int fd,uint32_t v) {
    unsigned char b[4]={v,v>>8,v>>16,v>>24}; return write_all(fd,b,4);
}
static void finish_frame(struct frame_context *ctx, int valid) {
    @autoreleasepool {
        int fd=-1,good=0;
        if(valid) {
            fd=openat(frame_dir,".frame.tmp",O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
            if(fd>=0) {
                good=write_all(fd,"BDFRM001",8)&&put_u32(fd,ctx->width)&&put_u32(fd,ctx->height)&&
                     put_u32(fd,ctx->stride)&&put_u32(fd,ctx->format)&&write_all(fd,[ctx->buffer contents],ctx->bytes)&&fsync(fd)==0;
                if(close(fd)!=0)good=0;fd=-1;
                if(good&&linkat(frame_dir,".frame.tmp",frame_dir,"frame.raw",0)!=0)good=0;
                unlinkat(frame_dir,".frame.tmp",0);
            }
        }
        fprintf(stderr,"[full-frame-snapshot] %s width=%u height=%u stride=%u format=%u\n",
                good?"complete":"failed",ctx->width,ctx->height,ctx->stride,ctx->format);
        [ctx->buffer release]; free(ctx);
    }
}

__attribute__((constructor)) static void initialize_snapshot(void) {
    const char *path=getenv("BEDROCK_FULLFRAME_DIR");
    if(!path||path[0]!='/')return;
    int fd=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);struct stat info;
    if(fd<0||fstat(fd,&info)!=0||!S_ISDIR(info.st_mode)||info.st_uid!=getuid()||(info.st_mode&077)!=0){if(fd>=0)close(fd);return;}
    writer=dispatch_queue_create("bedrock.full-frame.snapshot",DISPATCH_QUEUE_SERIAL);
    if(!writer){close(fd);return;} frame_dir=fd;
}

void fullframe_snapshot(id<MTLCommandBuffer> command,id<MTLDrawable> drawable) {
    if(frame_dir<0||atomic_load_explicit(&claimed,memory_order_relaxed))return;
    int arm=openat(frame_dir,"capture.arm",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);struct stat info;char token[4];
    if(arm<0)return;
    int valid=fstat(arm,&info)==0&&S_ISREG(info.st_mode)&&info.st_uid==getuid()&&info.st_nlink==1&&info.st_size==4&&
              read(arm,token,4)==4&&!memcmp(token,"arm\n",4);close(arm);
    if(!valid)return;
    int expected=0;
    if(!atomic_compare_exchange_strong(&claimed,&expected,1))return;
    unlinkat(frame_dir,"capture.arm",0);
    if(![drawable respondsToSelector:@selector(texture)]||![drawable respondsToSelector:@selector(layer)]) {
        fprintf(stderr,"[full-frame-snapshot] unsupported drawable\n");return;
    }
    id<CAMetalDrawable> surface=(id<CAMetalDrawable>)drawable;
    id<MTLTexture> texture=surface.texture;
    NSUInteger width=texture.width,height=texture.height;MTLPixelFormat format=texture.pixelFormat;
    if(!texture||surface.layer.framebufferOnly||width==0||height==0||width>4096||height>4096||
       (format!=MTLPixelFormatBGRA8Unorm&&format!=MTLPixelFormatBGRA8Unorm_sRGB)) {
        fprintf(stderr,"[full-frame-snapshot] unsupported texture\n");return;
    }
    size_t stride=((size_t)width*4+255)&~(size_t)255,bytes=stride*(size_t)height;
    if(bytes>32U*1024U*1024U)return;
    struct frame_context *ctx=calloc(1,sizeof(*ctx));if(!ctx)return;
    ctx->buffer=[[command device] newBufferWithLength:bytes options:MTLResourceStorageModeShared];
    if(!ctx->buffer){free(ctx);return;}
    ctx->width=(uint32_t)width;ctx->height=(uint32_t)height;ctx->stride=(uint32_t)stride;ctx->format=(uint32_t)format;ctx->bytes=bytes;
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    if(!blit){finish_frame(ctx,0);return;}
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(width,height,1) toBuffer:ctx->buffer destinationOffset:0
        destinationBytesPerRow:stride destinationBytesPerImage:bytes];
    [blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        int done=completed.status==MTLCommandBufferStatusCompleted;
        dispatch_async(writer, ^{finish_frame(ctx,done);});
    }];
}

/* Keep bounded initialization bytes until a matching actual compile is seen. */
static int shader_armed(void) {
    if(frame_dir<0)return 0;
    int fd=openat(frame_dir,"shader.arm",O_RDONLY|O_NOFOLLOW|O_CLOEXEC); struct stat info; char token[4];
    if(fd<0)return 0;
    int valid=fstat(fd,&info)==0&&S_ISREG(info.st_mode)&&info.st_uid==getuid()&&info.st_nlink==1&&info.st_size==4&&
        read(fd,token,4)==4&&!memcmp(token,"arm\n",4);
    close(fd); return valid;
}
static void clear_shaders(void) {
    for(unsigned i=0;i<MAX_TRACKED_SHADERS;i++) { free(tracked[i].bytes); memset(&tracked[i],0,sizeof(tracked[i])); }
    tracked_bytes=0;
}
void fullframe_remember_shader(void *shader,const void *bytecode,size_t length) {
    if(!shader||!bytecode||length<32||length>1024U*1024U||memcmp(bytecode,"DXBC",4))return;
    pthread_mutex_lock(&shader_lock);
    if(!shader_done&&shader_armed()&&length<=MAX_TRACKED_BYTES-tracked_bytes) {
        for(unsigned i=0;i<MAX_TRACKED_SHADERS;i++) if(!tracked[i].shader) {
            void *copy=malloc(length);
            if(copy) { memcpy(copy,bytecode,length); tracked[i]=(struct tracked_shader){shader,copy,length}; tracked_bytes+=length; }
            break;
        }
    }
    pthread_mutex_unlock(&shader_lock);
}
void fullframe_forget_shader(void *shader) {
    pthread_mutex_lock(&shader_lock);
    for(unsigned i=0;i<MAX_TRACKED_SHADERS;i++) if(tracked[i].shader==shader) {
        tracked_bytes-=tracked[i].length; free(tracked[i].bytes); memset(&tracked[i],0,sizeof(tracked[i])); break;
    }
    pthread_mutex_unlock(&shader_lock);
}
static int write_private(const char *name,const void *data,size_t length) {
    int fd=openat(frame_dir,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return 0;
    int good=write_all(fd,data,length)&&fsync(fd)==0;
    if(close(fd)!=0)good=0;
    if(!good)unlinkat(frame_dir,name,0);
    return good;
}
void fullframe_shader_variant(void *shader,struct SM50_SHADER_COMPILATION_ARGUMENT_DATA *arg) {
    if(!shader)return;
    pthread_mutex_lock(&shader_lock);
    if(shader_done||!shader_armed()) { pthread_mutex_unlock(&shader_lock); return; }
    struct tracked_shader *found=NULL;
    for(unsigned i=0;i<MAX_TRACKED_SHADERS;i++) if(tracked[i].shader==shader) { found=&tracked[i]; break; }
    if(found) {
        uint32_t words[FF_VARIANT_WORDS]; size_t length=0; int good=0,shader_linked=0,shader_temp=0,variant_temp=0;
        if(ff_variant_encode(arg,words,&length)&&
           CC_SHA256(found->bytes,(CC_LONG)found->length,(unsigned char *)(words+3))&&
           (shader_temp=write_private(".shader.tmp",found->bytes,found->length))&&
           (variant_temp=write_private(".variant.tmp",words,length))) {
            shader_linked=linkat(frame_dir,".shader.tmp",frame_dir,"shader.dxbc",0)==0;
            good=shader_linked&&linkat(frame_dir,".variant.tmp",frame_dir,"shader.variant",0)==0;
            if(shader_linked&&!good)unlinkat(frame_dir,"shader.dxbc",0);
        }
        if(shader_temp)unlinkat(frame_dir,".shader.tmp",0); if(variant_temp)unlinkat(frame_dir,".variant.tmp",0);
        if(good) { shader_done=1; unlinkat(frame_dir,"shader.arm",0); clear_shaders(); }
        fprintf(stderr,"[full-frame-shader-variant] %s bytes=%zu\n",good?"complete":"failed-or-unsupported",length);
    }
    pthread_mutex_unlock(&shader_lock);
}
