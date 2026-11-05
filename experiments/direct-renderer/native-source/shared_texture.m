#import "shared_texture.h"
#import <CoreFoundation/CoreFoundation.h>
#include <unistd.h>
#include <math.h>
#include <string.h>

/* NSXPCCoder transports the Metal Mach rights. Never archive this handle to a
 * file/socket: an NSSecureCoding conformance is not portable byte serialization. */
@protocol FFSTWire
- (void)publish:(NSArray<MTLSharedTextureHandle *> *)handles metadata:(NSData *)metadata
    token:(NSString *)token withReply:(void (^)(BOOL accepted, NSInteger result))reply;
- (void)acquire:(NSString *)token registryID:(uint64_t)registryID
    withReply:(void (^)(NSArray<MTLSharedTextureHandle *> *, NSData *, NSInteger))reply;
- (void)complete:(uint64_t)cut result:(NSInteger)result token:(NSString *)token
    withReply:(void (^)(BOOL))reply;
- (void)retire:(uint64_t)cut token:(NSString *)token withReply:(void (^)(BOOL))reply;
@end

static NSXPCInterface *ffst_interface(void) {
    NSXPCInterface *i = [NSXPCInterface interfaceWithProtocol:@protocol(FFSTWire)];
    NSSet *handles = [NSSet setWithObjects:[NSArray class], [MTLSharedTextureHandle class], nil];
    [i setClasses:handles forSelector:@selector(publish:metadata:token:withReply:)
        argumentIndex:0 ofReply:NO];
    [i setClasses:handles forSelector:@selector(acquire:registryID:withReply:)
        argumentIndex:0 ofReply:YES];
    return i;
}

int ffst_pixel_format_supported(uint64_t format) {
    switch (format) {
    case MTLPixelFormatBGRA8Unorm: case MTLPixelFormatBGRA8Unorm_sRGB:
    case MTLPixelFormatRGBA8Unorm: case MTLPixelFormatRGBA8Unorm_sRGB:
    case MTLPixelFormatRGBA16Float: case MTLPixelFormatRGBA32Float:
    case MTLPixelFormatRG16Float: case MTLPixelFormatRG32Float:
    case MTLPixelFormatR16Float: case MTLPixelFormatR32Float:
    case MTLPixelFormatRGB10A2Unorm: case MTLPixelFormatRG11B10Float:
    case MTLPixelFormatDepth16Unorm: case MTLPixelFormatDepth32Float:
    case MTLPixelFormatStencil8: case MTLPixelFormatDepth24Unorm_Stencil8:
    case MTLPixelFormatDepth32Float_Stencil8: return 1;
    default: return 0;
    }
}
int ffst_attachment_format_supported(uint64_t format, FFSTAttachmentRole role) {
    BOOL depth = format == MTLPixelFormatDepth16Unorm || format == MTLPixelFormatDepth32Float ||
        format == MTLPixelFormatDepth24Unorm_Stencil8 || format == MTLPixelFormatDepth32Float_Stencil8;
    BOOL stencil = format == MTLPixelFormatStencil8 || format == MTLPixelFormatDepth24Unorm_Stencil8 ||
        format == MTLPixelFormatDepth32Float_Stencil8;
    return ffst_pixel_format_supported(format) &&
        (role == FFST_COLOR ? !depth && !stencil : role == FFST_DEPTH ? depth : role == FFST_STENCIL && stencil);
}
int ffst_sample_count_supported(id<MTLDevice> device, uint64_t count) {
    return device && (count == 1 || count == 2 || count == 4 || count == 8) &&
        [device supportsTextureSampleCount:(NSUInteger)count];
}
static BOOL ffst_texture_supported(id<MTLTexture> t) {
    return t && ffst_pixel_format_supported(t.pixelFormat) && t.width && t.height && t.width <= 8192 &&
        t.height <= 8192 && t.depth == 1 && t.arrayLength == 1 && t.mipmapLevelCount == 1 &&
        t.storageMode == MTLStorageModePrivate && t.allocatedSize &&
        ((t.textureType == MTLTextureType2D && t.sampleCount == 1) ||
         (t.textureType == MTLTextureType2DMultisample && t.sampleCount > 1 &&
          ffst_sample_count_supported(t.device, t.sampleCount)));
}
static id<MTLDevice> ffst_device(uint64_t registry) {
    for (id<MTLDevice> d in MTLCopyAllDevices()) if (d.registryID == registry) return d;
    return nil;
}

/* All wire integers are explicit little-endian uint64, never native C layout. */
static void ffst_word(NSMutableData *d, uint64_t n) {
    n = CFSwapInt64HostToLittle(n); [d appendBytes:&n length:sizeof(n)];
}
static uint64_t ffst_read(const uint8_t *p, size_t index) {
    uint64_t n; memcpy(&n, p + index * 8, 8); return CFSwapInt64LittleToHost(n);
}
@interface FFSTMeta : NSObject
@property (nonatomic) uint64_t cut;
@property (nonatomic) uint64_t registry;
@property (nonatomic) uint64_t bytes;
@property (nonatomic, strong) NSArray<NSValue *> *infos;
@property (nonatomic, strong) NSArray<NSValue *> *attachments;
@end
@implementation FFSTMeta @end

static NSData *ffst_encode(uint64_t cut, uint64_t registry, uint64_t bytes,
    NSArray<NSValue *> *infos, const FFSTAttachmentRef *refs, size_t refCount) {
    NSMutableData *d = [NSMutableData data];
    for (NSNumber *n in @[@1, @(cut), @(registry), @(bytes), @(infos.count), @(refCount)])
        ffst_word(d, n.unsignedLongLongValue);
    for (NSValue *value in infos) {
        FFSTTextureInfo i; [value getValue:&i size:sizeof(i)];
        uint64_t words[] = {i.source_id, i.source_generation, i.source_level, i.source_slice,
            i.pixel_format, i.texture_type, i.width, i.height, i.sample_count, i.usage, i.allocated_bytes};
        for (size_t k = 0; k < 11; ++k) ffst_word(d, words[k]);
    }
    for (size_t k = 0; k < refCount; ++k) {
        ffst_word(d, refs[k].role); ffst_word(d, refs[k].attachment_index); ffst_word(d, refs[k].texture_index);
    }
    return d;
}
static FFSTMeta *ffst_decode(NSData *data) {
    if (data.length < 6 * 8 || data.length > (6 + 11 * FFST_MAX_TEXTURES + 3 * FFST_MAX_ATTACHMENTS) * 8)
        return nil;
    const uint8_t *p = data.bytes;
    uint64_t count = ffst_read(p, 4), refs = ffst_read(p, 5);
    if (ffst_read(p, 0) != 1 || !ffst_read(p, 1) || !count || count > FFST_MAX_TEXTURES ||
        !refs || refs > FFST_MAX_ATTACHMENTS || data.length != (6 + 11 * count + 3 * refs) * 8)
        return nil;
    FFSTMeta *m = [FFSTMeta new]; m.cut = ffst_read(p, 1); m.registry = ffst_read(p, 2);
    m.bytes = ffst_read(p, 3);
    NSMutableArray *infos = [NSMutableArray array], *attachments = [NSMutableArray array];
    uint64_t total = 0;
    for (size_t k = 0; k < count; ++k) {
        size_t j = 6 + k * 11;
        FFSTTextureInfo i = {ffst_read(p,j), ffst_read(p,j+1), ffst_read(p,j+2), ffst_read(p,j+3),
            ffst_read(p,j+4), ffst_read(p,j+5), ffst_read(p,j+6), ffst_read(p,j+7),
            ffst_read(p,j+8), ffst_read(p,j+9), ffst_read(p,j+10)};
        if (!i.source_id || !i.source_generation || !ffst_pixel_format_supported(i.pixel_format) || !i.width ||
            !i.height || i.width > 8192 || i.height > 8192 || !i.allocated_bytes ||
            i.allocated_bytes > (1ull << 30) || total > (1ull << 30) - i.allocated_bytes ||
            !((i.texture_type == MTLTextureType2D && i.sample_count == 1) ||
              (i.texture_type == MTLTextureType2DMultisample &&
               (i.sample_count == 2 || i.sample_count == 4 || i.sample_count == 8)))) return nil;
        total += i.allocated_bytes;
        [infos addObject:[NSValue valueWithBytes:&i objCType:@encode(FFSTTextureInfo)]];
    }
    uint64_t seen = 0, used = 0;
    FFSTTextureInfo base; [infos[0] getValue:&base size:sizeof(base)];
    for (NSValue *value in infos) {
        FFSTTextureInfo i; [value getValue:&i size:sizeof(i)];
        if (i.width != base.width || i.height != base.height || i.sample_count != base.sample_count) return nil;
    }
    for (size_t k = 0; k < refs; ++k) {
        size_t j = 6 + count * 11 + k * 3;
        FFSTAttachmentRef a = {ffst_read(p,j), ffst_read(p,j+1), ffst_read(p,j+2)};
        if (a.texture_index >= count || a.role < FFST_COLOR || a.role > FFST_STENCIL ||
            (a.role == FFST_COLOR ? a.attachment_index >= 8 : a.attachment_index != 0)) return nil;
        uint64_t bit = a.role == FFST_COLOR ? a.attachment_index : a.role == FFST_DEPTH ? 8 : 9;
        if (seen & (1ull << bit)) return nil;
        seen |= 1ull << bit; used |= 1ull << a.texture_index;
        FFSTTextureInfo i; [infos[a.texture_index] getValue:&i size:sizeof(i)];
        if (!ffst_attachment_format_supported(i.pixel_format, (FFSTAttachmentRole)a.role)) return nil;
        [attachments addObject:[NSValue valueWithBytes:&a objCType:@encode(FFSTAttachmentRef)]];
    }
    if (total != m.bytes || used != ((1ull << count) - 1)) return nil;
    /* Depth+stencil of the same allocation must alias the same imported object. */
    for (size_t x = 0; x < infos.count; ++x) for (size_t y = x + 1; y < infos.count; ++y) {
        FFSTTextureInfo a, b; [infos[x] getValue:&a size:sizeof(a)]; [infos[y] getValue:&b size:sizeof(b)];
        if (a.source_id == b.source_id && a.source_generation == b.source_generation &&
            a.source_level == b.source_level && a.source_slice == b.source_slice) return nil;
    }
    m.infos = infos; m.attachments = attachments; return m;
}
static NSArray<id<MTLTexture>> *ffst_import(id<MTLDevice> device,
    NSArray<MTLSharedTextureHandle *> *handles, FFSTMeta *meta) {
    if (!meta || device.registryID != meta.registry || handles.count != meta.infos.count) return nil;
    NSMutableArray *textures = [NSMutableArray array];
    for (size_t k = 0; k < handles.count; ++k) {
        MTLSharedTextureHandle *h = handles[k];
        if (![h isKindOfClass:[MTLSharedTextureHandle class]] || h.device.registryID != meta.registry) return nil;
        id<MTLTexture> t = [device newSharedTextureWithHandle:h];
        FFSTTextureInfo i; [meta.infos[k] getValue:&i size:sizeof(i)];
        if (!ffst_texture_supported(t) || t.device.registryID != meta.registry ||
            t.pixelFormat != i.pixel_format || t.textureType != i.texture_type ||
            t.width != i.width || t.height != i.height || t.sampleCount != i.sample_count ||
            t.usage != i.usage || t.allocatedSize != i.allocated_bytes) return nil;
        [textures addObject:t];
    }
    return textures;
}

@interface FFSTEntry : NSObject
@property (nonatomic, strong) FFSTMeta *meta;
@property (nonatomic, strong) NSData *wire;
@property (nonatomic, strong) NSArray<MTLSharedTextureHandle *> *handles;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *textures;
@property (nonatomic, strong) NSDate *created;
@property (nonatomic) NSInteger state; /* 0 queued, 1 acquired, 2 completed pending retirement */
@property (nonatomic) NSInteger result;
@property (copy) void (^reply)(BOOL, NSInteger);
@property (copy) void (^consumerReply)(BOOL);
@end
@implementation FFSTEntry @end
@class FFSTBroker;
@interface FFSTEndpoint : NSObject <FFSTWire>
@property (weak) FFSTBroker *broker;
@property (weak) NSXPCConnection *connection;
@end
@interface FFSTBroker : NSObject <NSXPCListenerDelegate>
@property (nonatomic, strong) NSXPCListener *listener;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, strong) NSString *token;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic) uint32_t maxCuts;
@property (nonatomic) uint64_t maxBytes;
@property (nonatomic) uint64_t bytes;
@property (nonatomic) double age;
@property (nonatomic, strong) NSDate *lastRoleChange;
@property (nonatomic) pid_t producerPID;
@property (nonatomic) pid_t consumerPID;
@property (nonatomic, strong) NSXPCConnection *producer;
@property (nonatomic, strong) NSXPCConnection *consumer;
@property (nonatomic, strong) NSMutableArray<NSXPCConnection *> *connections;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, FFSTEntry *> *entries;
@property (nonatomic, strong) NSMutableArray<NSNumber *> *order;
@property (nonatomic) uint64_t lastCut;
@property (atomic) BOOL closed;
@property (nonatomic) BOOL claimedProducer;
@property (nonatomic) BOOL claimedConsumer;
- (BOOL)claim:(NSXPCConnection *)connection token:(NSString *)token producer:(BOOL)producer;
- (void)close:(FFSTResult)result;
@end
@implementation FFSTBroker
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    (void)listener;
    if (connection.effectiveUserIdentifier != getuid()) return NO;
    __block BOOL accept = NO;
    dispatch_sync(self.queue, ^{
        if (self.closed || self.connections.count >= 4) return;
        [self.connections addObject:connection]; accept = YES;
    });
    if (!accept) return NO;
    FFSTEndpoint *endpoint = [FFSTEndpoint new]; endpoint.broker = self; endpoint.connection = connection;
    connection.exportedInterface = ffst_interface(); connection.exportedObject = endpoint;
    __weak FFSTBroker *weakSelf = self; __weak NSXPCConnection *weakConnection = connection;
    connection.invalidationHandler = ^{
        FFSTBroker *b = weakSelf; if (!b) return;
        dispatch_async(b.queue, ^{
            NSXPCConnection *c = weakConnection;
            if (!c) return;
            if (c == b.producer) {
                if (b.entries.count) [b close:FFST_DISCONNECTED];
                b.producer = nil; b.lastRoleChange = [NSDate date];
            } else if (c == b.consumer) {
                BOOL gpuOutstanding = NO;
                for (FFSTEntry *e in b.entries.allValues) if (e.state != 2) gpuOutstanding = YES;
                if (gpuOutstanding) [b close:FFST_DISCONNECTED];
                b.consumer = nil; b.lastRoleChange = [NSDate date];
            }
            /* Empty/GPU-complete disconnects may race the other peer's already
             * sent ACK. Parent cleanup (or bounded orphan expiry) owns shutdown. */
            [b.connections removeObject:c];
        });
    };
    connection.interruptionHandler = ^{ [weakConnection invalidate]; };
    [connection resume]; return YES;
}
- (BOOL)claim:(NSXPCConnection *)c token:(NSString *)token producer:(BOOL)producer {
    if (self.closed || !c || c.effectiveUserIdentifier != getuid() || ![token isEqualToString:self.token]) return NO;
    pid_t expected = producer ? self.producerPID : self.consumerPID;
    if (expected && c.processIdentifier != expected) return NO;
    if (producer) {
        if (self.producer) return self.producer == c;
        if (self.claimedProducer || c == self.consumer) return NO;
        self.claimedProducer = YES; self.producer = c; self.lastRoleChange = [NSDate date];
    } else {
        if (self.consumer) return self.consumer == c;
        if (self.claimedConsumer || c == self.producer) return NO;
        self.claimedConsumer = YES; self.consumer = c; self.lastRoleChange = [NSDate date];
    }
    return YES;
}
- (void)close:(FFSTResult)result {
    if (self.closed) return; self.closed = YES;
    for (FFSTEntry *e in self.entries.allValues) {
        if (e.reply) { e.reply(NO, result); e.reply = nil; }
        if (e.consumerReply) { e.consumerReply(NO); e.consumerReply = nil; }
    }
    [self.entries removeAllObjects]; [self.order removeAllObjects]; self.bytes = 0;
    [self.listener invalidate];
    for (NSXPCConnection *c in [self.connections copy]) [c invalidate];
    [self.connections removeAllObjects]; self.producer = nil; self.consumer = nil;
}
@end
@implementation FFSTEndpoint
- (void)publish:(NSArray<MTLSharedTextureHandle *> *)handles metadata:(NSData *)wire
    token:(NSString *)token withReply:(void (^)(BOOL, NSInteger))reply {
    FFSTBroker *b = self.broker; NSXPCConnection *c = self.connection;
    if (!b) { reply(NO, FFST_CLOSED); return; }
    dispatch_async(b.queue, ^{
        FFSTMeta *m = ffst_decode(wire);
        if (![b claim:c token:token producer:YES] || !m || m.registry != b.device.registryID ||
            b.entries.count >= b.maxCuts || m.bytes > b.maxBytes || b.bytes > b.maxBytes - m.bytes ||
            m.cut <= b.lastCut) {
            reply(NO, FFST_REJECTED); return;
        }
        NSArray *textures = ffst_import(b.device, handles, m);
        if (!textures) { reply(NO, FFST_REJECTED); return; }
        FFSTEntry *e = [FFSTEntry new]; e.meta = m; e.wire = wire; e.handles = handles;
        e.textures = textures; e.created = [NSDate date]; e.reply = reply;
        b.entries[@(m.cut)] = e; [b.order addObject:@(m.cut)]; b.lastCut = m.cut; b.bytes += m.bytes;
    });
}
- (void)acquire:(NSString *)token registryID:(uint64_t)registry
    withReply:(void (^)(NSArray<MTLSharedTextureHandle *> *, NSData *, NSInteger))reply {
    FFSTBroker *b = self.broker; NSXPCConnection *c = self.connection;
    if (!b) { reply(@[], [NSData data], FFST_CLOSED); return; }
    dispatch_async(b.queue, ^{
        if (![b claim:c token:token producer:NO] || registry != b.device.registryID) {
            reply(@[], [NSData data], FFST_REJECTED); return;
        }
        /* The pinned consumer may import several cuts before one GPU commit.
         * All queued/acquired/retiring entries retain the same hard cut/byte
         * admission bounds; no other connection may claim this role. */
        for (NSNumber *cut in b.order) {
            FFSTEntry *e = b.entries[cut]; if (e.state != 0) continue;
            e.state = 1; reply(e.handles, e.wire, FFST_OK); return;
        }
        reply(@[], [NSData data], FFST_EMPTY);
    });
}
- (void)complete:(uint64_t)cut result:(NSInteger)result token:(NSString *)token withReply:(void (^)(BOOL))reply {
    FFSTBroker *b = self.broker; NSXPCConnection *c = self.connection;
    if (!b) { reply(NO); return; }
    dispatch_async(b.queue, ^{
        FFSTEntry *e = b.entries[@(cut)];
        if (![b claim:c token:token producer:NO] || !e || e.state != 1 ||
            (result != FFST_OK && result != FFST_GPU_FAILED && result != FFST_REJECTED)) { reply(NO); return; }
        e.state = 2; e.result = result; e.consumerReply = reply;
        void (^producerReply)(BOOL, NSInteger) = e.reply; e.reply = nil;
        if (producerReply) producerReply(YES, result);
    });
}
- (void)retire:(uint64_t)cut token:(NSString *)token withReply:(void (^)(BOOL))reply {
    FFSTBroker *b = self.broker; NSXPCConnection *c = self.connection;
    if (!b) { reply(NO); return; }
    dispatch_async(b.queue, ^{
        FFSTEntry *e = b.entries[@(cut)];
        if (![b claim:c token:token producer:YES] || !e || e.state != 2) { reply(NO); return; }
        b.bytes -= e.meta.bytes; [b.entries removeObjectForKey:@(cut)]; [b.order removeObject:@(cut)];
        reply(YES);
        void (^consumerReply)(BOOL) = e.consumerReply; e.consumerReply = nil;
        if (consumerReply) consumerReply(YES);
    });
}
@end

@interface FFSTClient : NSObject
@property (nonatomic, strong) NSXPCConnection *connection;
@property (nonatomic, strong) NSString *token;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) dispatch_queue_t queue;
@property (atomic) BOOL closed;
@property (nonatomic) pid_t brokerPID;
- (BOOL)peerValid;
- (void)close;
@end
@implementation FFSTClient
- (BOOL)peerValid {
    return !self.closed && self.connection.effectiveUserIdentifier == getuid() &&
        (!self.brokerPID || self.connection.processIdentifier == self.brokerPID);
}
- (void)close { self.closed = YES; [self.connection invalidate]; }
@end
@interface FFSTProducerClient : FFSTClient
@property (nonatomic) uint32_t maxCuts;
@property (nonatomic) uint64_t maxBytes;
@property (nonatomic) uint64_t bytes;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, FFSTEntry *> *pending;
@property (nonatomic) uint64_t lastCut;
@end
@implementation FFSTProducerClient
- (void)close {
    if (self.closed) return; [super close];
    for (FFSTEntry *e in self.pending.allValues) if (e.reply) { e.reply(NO, FFST_DISCONNECTED); e.reply = nil; }
    [self.pending removeAllObjects]; self.bytes = 0;
}
@end
@interface FFSTConsumerClient : FFSTClient
@property (nonatomic) BOOL acquiring;
@property (nonatomic) uint32_t outstandingLeases;
@property (copy) void (^acquireReply)(FFSTLease, FFSTResult);
@end
@implementation FFSTConsumerClient
- (void)close {
    if (self.closed) return; [super close];
    if (self.acquireReply) { self.acquireReply(NULL, FFST_DISCONNECTED); self.acquireReply = nil; }
    self.acquiring = NO;
}
@end
@interface FFSTLeaseObject : NSObject
@property (nonatomic, strong) FFSTConsumerClient *client;
@property (nonatomic, strong) FFSTMeta *meta;
@property (nonatomic, strong) NSArray<id<MTLTexture>> *textures;
@property (nonatomic) BOOL consumed;
@property (nonatomic) BOOL retired; /* Terminal callback, confined to client.queue. */
@end
@implementation FFSTLeaseObject @end

static void ffst_connect(FFSTClient *client, NSString *service, NSString *token,
    id<MTLDevice> device, pid_t pid) {
    client.token = [token copy]; client.device = device; client.brokerPID = pid;
    client.queue = dispatch_queue_create("bedrock.fullframe.shared-texture.client", DISPATCH_QUEUE_SERIAL);
    client.connection = [[NSXPCConnection alloc] initWithMachServiceName:service options:0];
    client.connection.remoteObjectInterface = ffst_interface();
    __weak FFSTClient *weak = client;
    client.connection.invalidationHandler = ^{
        FFSTClient *c = weak; if (c) dispatch_async(c.queue, ^{ [c close]; });
    };
    client.connection.interruptionHandler = ^{
        FFSTClient *c = weak; if (c) dispatch_async(c.queue, ^{ [c close]; });
    };
    [client.connection resume];
}
static BOOL ffst_config(NSString *service, NSString *token, id<MTLDevice> device) {
    return service.length >= 16 && service.length <= 160 && token.length >= 32 && token.length <= 128 && device;
}
FFSTProducer ffst_producer_create(NSString *service, NSString *token, id<MTLDevice> device,
    uint32_t maxCuts, uint64_t maxBytes, pid_t pid) {
    if (!ffst_config(service, token, device) || !maxCuts || maxCuts > 16 || !maxBytes || maxBytes > (1ull << 30)) return NULL;
    FFSTProducerClient *p = [FFSTProducerClient new]; p.maxCuts = maxCuts; p.maxBytes = maxBytes;
    p.pending = [NSMutableDictionary dictionary];
    ffst_connect(p, service, token, device, pid);
    dispatch_queue_set_specific(p.queue, (__bridge const void *)p, (__bridge void *)p, NULL);
    return (__bridge_retained void *)p;
}
void ffst_producer_destroy(FFSTProducer handle) {
    if (!handle) return; FFSTProducerClient *p = (__bridge_transfer FFSTProducerClient *)handle;
    dispatch_async(p.queue, ^{ [p close]; });
}
static void ffst_producer_finish(FFSTProducerClient *p, NSNumber *cut, FFSTResult result) {
    FFSTEntry *e = p.pending[cut]; if (!e) return;
    p.bytes -= e.meta.bytes; [p.pending removeObjectForKey:cut];
    void (^callback)(BOOL, NSInteger) = e.reply; e.reply = nil;
    if (callback) callback(YES, result);
}
int ffst_producer_publish(FFSTProducer handle, id<MTLCommandBuffer> command, uint64_t cut,
    const FFSTTextureInput *inputs, size_t count, const FFSTAttachmentRef *refs, size_t refCount,
    FFSTCompletion completion) {
    if (!handle || !command || command.status != MTLCommandBufferStatusCompleted || !cut || !inputs ||
        !refs || !completion || !count || count > FFST_MAX_TEXTURES || !refCount || refCount > FFST_MAX_ATTACHMENTS) return 0;
    FFSTProducerClient *p = (__bridge FFSTProducerClient *)handle;
    if (command.commandQueue.device.registryID != p.device.registryID) return 0;
    NSMutableArray *textures = [NSMutableArray array], *handles = [NSMutableArray array], *infos = [NSMutableArray array];
    uint64_t total = 0;
    for (size_t k = 0; k < count; ++k) {
        id<MTLTexture> t = inputs[k].texture;
        if (!ffst_texture_supported(t) || t.device.registryID != p.device.registryID ||
            [textures containsObject:t] || t.allocatedSize > p.maxBytes || total > p.maxBytes - t.allocatedSize) return 0;
        MTLSharedTextureHandle *h = [t newSharedTextureHandle]; if (!h) return 0;
        FFSTTextureInfo i = {inputs[k].source_id, inputs[k].source_generation, inputs[k].source_level,
            inputs[k].source_slice, t.pixelFormat, t.textureType, t.width, t.height, t.sampleCount, t.usage, t.allocatedSize};
        [textures addObject:t]; [handles addObject:h]; [infos addObject:[NSValue valueWithBytes:&i objCType:@encode(FFSTTextureInfo)]];
        total += t.allocatedSize;
    }
    NSData *wire = ffst_encode(cut, p.device.registryID, total, infos, refs, refCount);
    FFSTMeta *meta = ffst_decode(wire); if (!meta) return 0;
    __block BOOL accepted = NO;
    void (^submit)(void) = ^{
        if (p.closed || p.pending.count >= p.maxCuts || p.bytes > p.maxBytes - total ||
            cut <= p.lastCut) return;
        FFSTEntry *e = [FFSTEntry new]; e.meta = meta; e.wire = wire; e.handles = handles; e.textures = textures;
        e.reply = ^(BOOL ok, NSInteger result) { (void)ok; completion(cut, (FFSTResult)result); };
        p.pending[@(cut)] = e; p.bytes += total; p.lastCut = cut; accepted = YES;
        id<FFSTWire> proxy = [p.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            (void)error; dispatch_async(p.queue, ^{ [p close]; });
        }];
        [proxy publish:handles metadata:wire token:p.token withReply:^(BOOL remoteAccepted, NSInteger result) {
            dispatch_async(p.queue, ^{
                if (!p.pending[@(cut)]) return;
                if (![p peerValid]) { [p close]; return; }
                if (!remoteAccepted) { ffst_producer_finish(p, @(cut), (FFSTResult)result); return; }
                id<FFSTWire> retireProxy = [p.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
                    (void)error; dispatch_async(p.queue, ^{ [p close]; });
                }];
                [retireProxy retire:cut token:p.token withReply:^(BOOL retired) {
                    dispatch_async(p.queue, ^{
                        ffst_producer_finish(p, @(cut), retired && [p peerValid] ? (FFSTResult)result : FFST_DISCONNECTED);
                    });
                }];
            });
        }];
    };
    if (dispatch_get_specific((__bridge const void *)p) == (__bridge void *)p) submit();
    else dispatch_sync(p.queue, submit);
    return accepted;
}
FFSTConsumer ffst_consumer_create(NSString *service, NSString *token, id<MTLDevice> device, pid_t pid) {
    if (!ffst_config(service, token, device)) return NULL;
    FFSTConsumerClient *c = [FFSTConsumerClient new]; ffst_connect(c, service, token, device, pid);
    return (__bridge_retained void *)c;
}
void ffst_consumer_destroy(FFSTConsumer handle) {
    if (!handle) return; FFSTConsumerClient *c = (__bridge_transfer FFSTConsumerClient *)handle;
    dispatch_async(c.queue, ^{ [c close]; });
}
void ffst_consumer_acquire(FFSTConsumer handle, void (^completion)(FFSTLease, FFSTResult)) {
    if (!completion) return;
    if (!handle) { completion(NULL, FFST_CLOSED); return; }
    FFSTConsumerClient *c = (__bridge FFSTConsumerClient *)handle;
    dispatch_async(c.queue, ^{
        if (c.closed || c.acquiring || c.outstandingLeases >= FFST_MAX_OUTSTANDING_LEASES) {
            completion(NULL, c.closed ? FFST_CLOSED : FFST_REJECTED); return;
        }
        c.acquiring = YES; c.acquireReply = completion;
        id<FFSTWire> proxy = [c.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            (void)error; dispatch_async(c.queue, ^{ [c close]; });
        }];
        [proxy acquire:c.token registryID:c.device.registryID withReply:^(NSArray *handles, NSData *wire, NSInteger result) {
            dispatch_async(c.queue, ^{
                void (^callback)(FFSTLease, FFSTResult) = c.acquireReply;
                c.acquireReply = nil; c.acquiring = NO; if (!callback) return;
                if (![c peerValid]) { [c close]; callback(NULL, FFST_DISCONNECTED); return; }
                if (result != FFST_OK) { callback(NULL, (FFSTResult)result); return; }
                FFSTMeta *meta = ffst_decode(wire); NSArray *textures = ffst_import(c.device, handles, meta);
                if (!textures) { [c close]; callback(NULL, FFST_REJECTED); return; }
                FFSTLeaseObject *lease = [FFSTLeaseObject new]; lease.client = c; lease.meta = meta; lease.textures = textures;
                ++c.outstandingLeases; callback((__bridge_retained void *)lease, FFST_OK);
            });
        }];
    });
}
uint64_t ffst_lease_cut_id(FFSTLease lease) { return lease ? ((__bridge FFSTLeaseObject *)lease).meta.cut : 0; }
size_t ffst_lease_texture_count(FFSTLease lease) { return lease ? ((__bridge FFSTLeaseObject *)lease).textures.count : 0; }
size_t ffst_lease_attachment_count(FFSTLease lease) { return lease ? ((__bridge FFSTLeaseObject *)lease).meta.attachments.count : 0; }
id<MTLTexture> ffst_lease_texture(FFSTLease lease, size_t index) {
    if (!lease) return nil; FFSTLeaseObject *l = (__bridge FFSTLeaseObject *)lease;
    return index < l.textures.count ? l.textures[index] : nil;
}
int ffst_lease_texture_info(FFSTLease lease, size_t index, FFSTTextureInfo *info) {
    if (!lease || !info) return 0; FFSTLeaseObject *l = (__bridge FFSTLeaseObject *)lease;
    if (index >= l.meta.infos.count) return 0; [l.meta.infos[index] getValue:info size:sizeof(*info)]; return 1;
}
int ffst_lease_attachment(FFSTLease lease, size_t index, FFSTAttachmentRef *a) {
    if (!lease || !a) return 0; FFSTLeaseObject *l = (__bridge FFSTLeaseObject *)lease;
    if (index >= l.meta.attachments.count) return 0; [l.meta.attachments[index] getValue:a size:sizeof(*a)]; return 1;
}
static void ffst_complete(FFSTLeaseObject *lease, FFSTResult result, FFSTCompletion completion) {
    FFSTConsumerClient *c = lease.client;
    dispatch_async(c.queue, ^{
        /* Keep lease alive in both success/error blocks until an explicit reply. */
        void (^done)(FFSTResult) = ^(FFSTResult value) {
            if (lease.retired) return; lease.retired = YES;
            if (c.outstandingLeases) --c.outstandingLeases;
            if (completion) completion(lease.meta.cut, value);
        };
        if (c.closed) { done(FFST_DISCONNECTED); return; }
        id<FFSTWire> proxy = [c.connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
            (void)error; dispatch_async(c.queue, ^{ done(FFST_DISCONNECTED); [c close]; });
        }];
        [proxy complete:lease.meta.cut result:result token:c.token withReply:^(BOOL ok) {
            dispatch_async(c.queue, ^{ done(ok && [c peerValid] ? result : FFST_DISCONNECTED); });
        }];
    });
}
int ffst_consumer_finish(FFSTLease handle, id<MTLCommandBuffer> command, FFSTCompletion completion) {
    if (!handle || !command || command.status > MTLCommandBufferStatusEnqueued) return 0;
    FFSTLeaseObject *lease = (__bridge FFSTLeaseObject *)handle;
    if (lease.consumed || command.commandQueue.device.registryID != lease.meta.registry) return 0;
    lease.consumed = YES; id transferred = CFBridgingRelease(handle); (void)transferred;
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        ffst_complete(lease, completed.status == MTLCommandBufferStatusCompleted ? FFST_OK : FFST_GPU_FAILED, completion);
    }];
    return 1;
}
void ffst_consumer_abandon(FFSTLease handle, FFSTCompletion completion) {
    if (!handle) return; FFSTLeaseObject *lease = (__bridge_transfer FFSTLeaseObject *)handle;
    if (lease.consumed) return; lease.consumed = YES; ffst_complete(lease, FFST_REJECTED, completion);
}
int ffst_broker_run(NSString *service, NSString *token, uint64_t registry, uint32_t maxCuts,
    uint64_t maxBytes, double age, pid_t producerPID, pid_t consumerPID) {
    id<MTLDevice> device = ffst_device(registry);
    if (!ffst_config(service, token, device) || !maxCuts || maxCuts > 16 || !maxBytes ||
        maxBytes > (1ull << 30) || !isfinite(age) || age < 1 || age > 300) return 2;
    FFSTBroker *b = [FFSTBroker new]; b.token = token; b.device = device; b.maxCuts = maxCuts;
    b.maxBytes = maxBytes; b.age = age; b.producerPID = producerPID; b.consumerPID = consumerPID;
    b.queue = dispatch_queue_create("bedrock.fullframe.shared-texture.broker", DISPATCH_QUEUE_SERIAL);
    b.entries = [NSMutableDictionary dictionary]; b.order = [NSMutableArray array];
    b.connections = [NSMutableArray array];
    b.listener = [[NSXPCListener alloc] initWithMachServiceName:service]; b.listener.delegate = b;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, b.queue);
    __weak FFSTBroker *weak = b;
    b.lastRoleChange = [NSDate date];
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        FFSTBroker *strong = weak; if (!strong || strong.closed) return;
        /* Idle orphan service is bounded even if runner dies before bootout. */
        if ((!strong.producer || !strong.consumer) && [strong.lastRoleChange timeIntervalSinceNow] < -60) {
            [strong close:FFST_EXPIRED]; return;
        }
        for (FFSTEntry *e in strong.entries.allValues)
            if ([e.created timeIntervalSinceNow] < -strong.age) { [strong close:FFST_EXPIRED]; return; }
    });
    dispatch_resume(timer); [b.listener resume];
    while (!b.closed) @autoreleasepool {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    dispatch_source_cancel(timer); dispatch_sync(b.queue, ^{}); return 0;
}
