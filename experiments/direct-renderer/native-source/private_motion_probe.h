/* Private aggregate-only observation of the texture submitted for presentation.
 * This samples only the owned render texture, stores no pixels and is disabled
 * unless the isolated launcher explicitly enables it. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { PM_W=128, PM_H=64, PM_IW=32, PM_IH=32, PM_SHIFT=8,
       PM_WORLD=PM_W*PM_H, PM_ITEM=PM_IW*PM_IH, PM_TOTAL=PM_WORLD+PM_ITEM };
static unsigned pm_shift(const uint8_t *current,const uint8_t *previous,uint64_t *score){
    uint64_t best=UINT64_MAX;int selected=0;
    for(int dx=-PM_SHIFT;dx<=PM_SHIFT;dx++){
        uint64_t cost=0;
        for(unsigned y=0;y<PM_H;y++)for(int x=PM_SHIFT;x<PM_W-PM_SHIFT;x++)
            cost+=(unsigned)abs((int)current[y*PM_W+x]-(int)previous[y*PM_W+x+dx]);
        if(cost<best||(cost==best&&abs(dx)<abs(selected))){best=cost;selected=dx;}
    }
    *score=best;return (unsigned)(selected+PM_SHIFT);
}
@interface FFPrivateMotion:NSObject {
    id<MTLDevice> _device;id<MTLComputePipelineState> _pipeline;NSLock *_lock;
    uint64_t _issued,_finished;BOOL _seen;
    uint8_t _previous[PM_TOTAL];
}
-(instancetype)initWithDevice:(id<MTLDevice>)device;
-(id<MTLBuffer>)encode:(id<MTLCommandBuffer>)command texture:(id<MTLTexture>)texture serial:(uint64_t *)serial;
-(void)finish:(id<MTLBuffer>)buffer serial:(uint64_t)serial;
@end
@implementation FFPrivateMotion
-(instancetype)initWithDevice:(id<MTLDevice>)device {
    if(!(self=[super init]))return nil;
    _device=device;_lock=[NSLock new];
    NSString *source=@"#include <metal_stdlib>\nusing namespace metal;\n"
      "kernel void pm_sample(texture2d<float,access::read> image [[texture(0)]], device uchar *out [[buffer(0)]], uint i [[thread_position_in_grid]]) {\n"
      " if(i>=9216) return; float x,y; if(i<8192){x=20.0+float(i%128)*4.0;y=50.0+float(i/128)*4.0;}\n"
      " else {uint j=i-8192;x=512.0+float(j%32)*3.0;y=250.0+float(j/32)*4.0;}\n"
      " uint2 p=min(uint2(x*float(image.get_width())/640.0,y*float(image.get_height())/386.0),uint2(image.get_width()-1,image.get_height()-1));\n"
      " float3 c=image.read(p).rgb;out[i]=uchar(clamp(dot(c,float3(0.299,0.587,0.114))*255.0,0.0,255.0)+0.5);}\n";
    NSError *error=nil;id<MTLLibrary> library=[device newLibraryWithSource:source options:nil error:&error];
    id<MTLFunction> function=[library newFunctionWithName:@"pm_sample"];
    _pipeline=function?[device newComputePipelineStateWithFunction:function error:&error]:nil;
    if(!_pipeline)return nil;return self;
}
-(id<MTLBuffer>)encode:(id<MTLCommandBuffer>)command texture:(id<MTLTexture>)texture serial:(uint64_t *)serial {
    id<MTLBuffer> buffer=[_device newBufferWithLength:PM_TOTAL options:MTLResourceStorageModeShared];
    id<MTLComputeCommandEncoder> encoder=buffer?[command computeCommandEncoder]:nil;
    if(!encoder)return nil;
    [encoder setComputePipelineState:_pipeline];[encoder setTexture:texture atIndex:0];[encoder setBuffer:buffer offset:0 atIndex:0];
    [encoder dispatchThreads:MTLSizeMake(PM_TOTAL,1,1) threadsPerThreadgroup:MTLSizeMake(128,1,1)];[encoder endEncoding];
    [_lock lock];*serial=++_issued;[_lock unlock];return buffer;
}
-(void)finish:(id<MTLBuffer>)buffer serial:(uint64_t)serial {
    if(!buffer||!buffer.contents||buffer.length!=PM_TOTAL||!serial)return;
    const uint8_t *current=buffer.contents;unsigned changed=0,itemChanged=0,shift=PM_SHIFT;uint64_t cost=0;
    struct timespec now;if(clock_gettime(CLOCK_MONOTONIC,&now))return;
    [_lock lock];
    BOOL ordered=serial==_finished+1;if(!ordered)_seen=NO;_finished=serial;
    if(_seen){
        for(unsigned i=0;i<PM_WORLD;i++)changed+=abs((int)current[i]-(int)_previous[i])>8;
        for(unsigned i=0;i<PM_ITEM;i++)itemChanged+=abs((int)current[PM_WORLD+i]-(int)_previous[PM_WORLD+i])>8;
        shift=pm_shift(current,_previous,&cost);
    }
    memcpy(_previous,current,PM_TOTAL);_seen=YES;
    uint64_t ns=(uint64_t)now.tv_sec*1000000000ull+(uint64_t)now.tv_nsec;
    printf("[private-camera-frame] time_ns=%llu serial=%llu ordered=%u shift_bias=%u world_changed=%u item_changed=%u match_cost=%llu\n",
        (unsigned long long)ns,(unsigned long long)serial,(unsigned)ordered,shift,changed,itemChanged,(unsigned long long)cost);
    fflush(stdout);[_lock unlock];
}
@end
