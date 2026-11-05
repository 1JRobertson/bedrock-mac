#import "native_persistent_resources.h"
#include "persistent_resource_source.h"
#include <stdio.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) { fprintf(stderr,"failed line %d: %s\n",__LINE__,#x); return 1; } } while (0)
typedef struct { __unsafe_unretained FFPRRegistry *registry; __unsafe_unretained FFPRBatch *batch; int fail; } Fixture;
static int emit(void *context,const FFPSEvent *event) {
    Fixture *f=context; if(f->fail)return 0;
    FFPRHandle target={event->target.object,event->target.generation}, source={event->source.object,event->source.generation};
    switch(event->operation) {
    case FFPS_CREATE: return [f->registry createBuffer:target length:event->length];
    case FFPS_WRITE: return [f->registry writeBuffer:target offset:event->offset bytes:event->bytes length:event->length batch:f->batch];
    case FFPS_COPY: return [f->registry copyBuffer:source sourceOffset:event->source_offset destination:target destinationOffset:event->offset length:event->length batch:f->batch];
    case FFPS_DESTROY: return [f->registry destroyBuffer:target];
    }
    return 0;
}
int main(void) { @autoreleasepool {
    id<MTLDevice> device=MTLCreateSystemDefaultDevice(); CHECK(device);
    id<MTLCommandQueue> queue=[device newCommandQueue]; CHECK(queue);
    FFPRRegistry *registry=[[FFPRRegistry alloc] initWithDevice:device];
    FFPRHandle a={1,1}, b={2,1}, next={1,2};
    id<MTLCommandBuffer> command=[queue commandBuffer]; FFPRBatch *batch=[[FFPRBatch alloc] initWithCommandBuffer:command];
    Fixture fixture={registry,batch,0}; FFPSSource *source=ffps_create(emit,&fixture); CHECK(source);
    FFPSHandle sa={1,1}, sb={2,1}, snext={1,2};
    fixture.fail=1; CHECK(!ffps_buffer_create(source,sa,16)); fixture.fail=0;
    CHECK(ffps_buffer_create(source,sa,16)); CHECK(ffps_buffer_create(source,sb,16));
    CHECK(!ffps_buffer_create(source,sa,16));
    unsigned char data[16]; for (int i=0;i<16;i++) data[i]=(unsigned char)i;
    CHECK(ffps_buffer_write(source,sa,0,data,16)); memset(data,255,16);
    CHECK(![registry writeBuffer:a offset:15 bytes:data length:2 batch:batch]);
    CHECK(ffps_buffer_copy(source,sa,0,sb,0,16));
    CHECK(![registry copyBuffer:b sourceOffset:0 destination:b destinationOffset:1 length:8 batch:batch]);
    id<MTLBuffer> captured=[registry buffer:b batch:batch]; CHECK(captured);
    fixture.fail=1; CHECK(!ffps_buffer_destroy(source,sa)); fixture.fail=0;
    CHECK(ffps_buffer_destroy(source,sa)); CHECK(![registry buffer:a batch:batch]);
    CHECK(!ffps_buffer_create(source,sa,16)); CHECK(ffps_buffer_create(source,snext,16));
    CHECK(ffps_buffer_destroy(source,sb)); ffps_free(source);
    id<MTLBuffer> readback=[device newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit=[command blitCommandEncoder];
    [blit copyFromBuffer:captured sourceOffset:0 toBuffer:readback destinationOffset:0 size:16]; [blit endEncoding];
    CHECK([batch finish]); CHECK(![batch finish]); CHECK(![registry buffer:next batch:batch]);
    [command commit]; [command waitUntilCompleted]; CHECK(command.status==MTLCommandBufferStatusCompleted);
    for (int i=0;i<16;i++) CHECK(((unsigned char *)readback.contents)[i]==i);
    /* A destroyed but GPU-referenced allocation remains charged until the
       completion handler releases its batch, including across registry reuse. */
    FFPRRegistry *limited=[[FFPRRegistry alloc] initWithDevice:device budget:16];
    FFPRHandle x={10,1}, y={11,1}; CHECK([limited createBuffer:x length:16]);
    id<MTLCommandBuffer> c2=[queue commandBuffer]; FFPRBatch *b2=[[FFPRBatch alloc] initWithCommandBuffer:c2];
    CHECK([limited buffer:x batch:b2]); CHECK([limited destroyBuffer:x]);
    CHECK(![limited createBuffer:y length:16]); CHECK([b2 finish]);
    [c2 commit]; [c2 waitUntilCompleted]; CHECK(c2.status==MTLCommandBufferStatusCompleted);
    CHECK([limited createBuffer:y length:16]);
    puts("persistent resource GPU fixture passed"); return 0;
} }
