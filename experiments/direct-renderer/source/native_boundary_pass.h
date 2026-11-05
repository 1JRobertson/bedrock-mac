/* Default-off, bounded per-pass correctness readback. Never a timing path. */
#ifndef BEDROCK_BOUNDARY_PASS_H
#define BEDROCK_BOUNDARY_PASS_H
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <errno.h>
#include <stdatomic.h>
#if __has_feature(objc_arc)
#define BOUNDARY_RELEASE(x) ((void)0)
#else
#define BOUNDARY_RELEASE(x) [(x) release]
#endif
static BOOL boundary_pass_write(int directory,NSString *name,NSData *data){
    int fd=openat(directory,name.UTF8String,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0)return NO;const uint8_t *p=data.bytes;size_t left=data.length;
    while(left){ssize_t n=write(fd,p,left);if(n<0&&errno==EINTR)continue;if(n<=0)break;p+=n;left-=(size_t)n;}
    BOOL ok=!left&&!fsync(fd);if(close(fd))ok=NO;return ok;
}
static BOOL boundary_pass_capture(id<MTLCommandBuffer> command,id<MTLTexture> color,
    int directory,NSString *side,uint64_t stream,uint64_t frame,uint64_t payload,void (^done)(BOOL)){
    static _Atomic uint64_t reserved;
    if(!color||!color.width||!color.height||color.width>4096||color.height>4096||
       (color.pixelFormat!=MTLPixelFormatRGBA8Unorm&&color.pixelFormat!=MTLPixelFormatBGRA8Unorm))return NO;
    NSUInteger width=color.width,height=color.height,row=(width*4+255)&~(NSUInteger)255,length=row*height;
    if(length>32u*1024u*1024u||atomic_fetch_add(&reserved,length)>128u*1024u*1024u-length)return NO;
    int fd=dup(directory);if(fd<0)return NO;
    id<MTLBuffer> bytes=[command.device newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLSharedEvent> barrier=[command.device newSharedEvent];
    id<MTLTexture> resolved=nil;
    if(color.sampleCount>1){
        MTLTextureDescriptor *d=[MTLTextureDescriptor texture2DDescriptorWithPixelFormat:color.pixelFormat width:width height:height mipmapped:NO];
        d.usage=MTLTextureUsageRenderTarget;d.storageMode=MTLStorageModePrivate;
        resolved=[command.device newTextureWithDescriptor:d];
    }
    if(!bytes||!barrier||(color.sampleCount>1&&!resolved)){
        BOUNDARY_RELEASE(bytes);BOUNDARY_RELEASE(barrier);BOUNDARY_RELEASE(resolved);close(fd);return NO;
    }
    [command encodeSignalEvent:barrier value:1];[command encodeWaitForEvent:barrier value:1];
    if(resolved){
        MTLRenderPassDescriptor *d=[MTLRenderPassDescriptor renderPassDescriptor];
        d.colorAttachments[0].texture=color;d.colorAttachments[0].resolveTexture=resolved;
        d.colorAttachments[0].loadAction=MTLLoadActionLoad;
        d.colorAttachments[0].storeAction=MTLStoreActionStoreAndMultisampleResolve;
        id<MTLRenderCommandEncoder> e=[command renderCommandEncoderWithDescriptor:d];
        if(!e){BOUNDARY_RELEASE(bytes);BOUNDARY_RELEASE(barrier);BOUNDARY_RELEASE(resolved);close(fd);return NO;}
        [e endEncoding];
    }
    [command encodeSignalEvent:barrier value:2];[command encodeWaitForEvent:barrier value:2];
    id<MTLBlitCommandEncoder> copy=[command blitCommandEncoder];
    if(!copy){BOUNDARY_RELEASE(bytes);BOUNDARY_RELEASE(barrier);BOUNDARY_RELEASE(resolved);close(fd);return NO;}
    [copy copyFromTexture:resolved?:color sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0)
        sourceSize:MTLSizeMake(width,height,1) toBuffer:bytes destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:length];
    [copy endEncoding];
    [command encodeSignalEvent:barrier value:3];[command encodeWaitForEvent:barrier value:3];
    NSUInteger format=color.pixelFormat;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed){@autoreleasepool{
        BOOL ok=completed.status==MTLCommandBufferStatusCompleted&&barrier.signaledValue==3&&(!resolved||resolved.width==width);
        NSString *base=[NSString stringWithFormat:@"boundary-%@-pass-%llu",side,(unsigned long long)payload];
        if(ok)ok=boundary_pass_write(fd,[base stringByAppendingString:@".raw"],[NSData dataWithBytesNoCopy:bytes.contents length:length freeWhenDone:NO]);
        NSDictionary *record=@{@"stream":@(stream),@"frame":@(frame),@"payload":@(payload),@"width":@(width),@"height":@(height),
            @"row_bytes":@(row),@"pixel_format":@(format),@"gpu_completed":@(ok),@"barrier_completed":@(barrier.signaledValue)};
        NSData *json=[NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
        ok=boundary_pass_write(fd,[base stringByAppendingString:@".json"],json)&&ok;close(fd);done(ok);
    }}];
    BOUNDARY_RELEASE(bytes);BOUNDARY_RELEASE(barrier);BOUNDARY_RELEASE(resolved);return YES;
}
#undef BOUNDARY_RELEASE
#endif
