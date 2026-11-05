/* One game-command duplicate, executed on native Metal and ACKed on completion. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "resource_transport.h"
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>
#include <poll.h>
#include <signal.h>
#include <string.h>
#include <stdio.h>

static void interrupt(int signum) { (void)signum; }
static uint32_t get32(const unsigned char *p) { uint32_t v = 0; for (unsigned i = 0; i < 4; ++i) v |= (uint32_t)p[i] << (8*i); return v; }
static uint64_t get64(const unsigned char *p) { uint64_t v = 0; for (unsigned i = 0; i < 8; ++i) v |= (uint64_t)p[i] << (8*i); return v; }
static int safe_directory(const char *directory) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)]; strcpy(path, directory);
    for (;;) {
        struct stat info;
        if (lstat(path, &info) || !S_ISDIR(info.st_mode)) return 0;
        if (!strcmp(path, directory) && (info.st_uid != getuid() || (info.st_mode & 077))) return 0;
        char *slash = strrchr(path, '/'); if (!slash || slash == path) break; *slash = 0;
    }
    return 1;
}
int main(int argc, const char **argv) {
    @autoreleasepool {
        struct sigaction action = {0}; action.sa_handler = interrupt; sigemptyset(&action.sa_mask);
        if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return 1;
        if (argc != 2 || argv[1][0] != '/' || strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 2;
        char path[sizeof(((struct sockaddr_un *)0)->sun_path)]; strcpy(path, argv[1]);
        char *slash = strrchr(path, '/'); if (!slash || slash == path) return 2; *slash = 0;
        if (!safe_directory(path)) return 2;
        int listener = socket(AF_UNIX, SOCK_STREAM, 0); if (listener < 0) return 1;
        struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; strcpy(address.sun_path, argv[1]);
        mode_t previous = umask(077); int bound = bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0; umask(previous);
        if (!bound) { close(listener); return 1; }
        struct stat owned, info;
        if (lstat(argv[1], &owned) || !S_ISSOCK(owned.st_mode)) { close(listener); return 1; }
        int result = 1, peer = -1; struct pollfd ready = {listener, POLLIN, 0};
        if (listen(listener, 1) || poll(&ready, 1, 180000) <= 0 || (peer = accept(listener, NULL, NULL)) < 0) goto cleanup;
        uid_t uid; gid_t gid; ff_resource_channel channel; ff_resource_message message;
        if (getpeereid(peer, &uid, &gid) || uid != getuid() || ff_resource_init(&channel, peer) || ff_resource_receive(&channel, &message)) goto cleanup;
        const unsigned char *r = message.bytes;
        if (message.retire || message.resource != 1 || message.generation != 1 || message.length != 40 ||
            memcmp(r, "BFFILL1\0", 8) || get32(r+8) != 1) { ff_resource_discard(&message); goto cleanup; }
        uint32_t value = get32(r+12); uint64_t size = get64(r+16), offset = get64(r+24), length = get64(r+32);
        if (value > 255 || !size || size > 16u*1024u*1024u || !length || offset > size || length > size-offset) { ff_resource_discard(&message); goto cleanup; }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice(); id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:(NSUInteger)size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [queue commandBuffer]; id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        if (!device || !queue || !buffer || !buffer.contents || !command || !encoder) { ff_resource_discard(&message); goto cleanup; }
        unsigned char sentinel = (unsigned char)(value+1); memset(buffer.contents, sentinel, (size_t)size);
        [encoder fillBuffer:buffer range:NSMakeRange((NSUInteger)offset, (NSUInteger)length) value:(uint8_t)value]; [encoder endEncoding];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        [command addCompletedHandler:^(id<MTLCommandBuffer> unused) { (void)unused; dispatch_semaphore_signal(done); }];
        [command commit];
        int valid = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5LL*NSEC_PER_SEC)) == 0 && command.status == MTLCommandBufferStatusCompleted;
        const unsigned char *bytes = buffer.contents;
        for (uint64_t i = 0; valid && i < size; ++i) {
            unsigned char expected = (i >= offset && i-offset < length) ? (unsigned char)value : sentinel;
            if (bytes[i] != expected) valid = 0;
        }
        if (valid && !ff_resource_ack(&channel, &message)) { puts("Live duplicate fill GPU-completed and verified"); result = 0; }
        else ff_resource_discard(&message);
        [buffer release]; [queue release];
cleanup:
        if (peer >= 0) close(peer); close(listener);
        if (!lstat(argv[1], &info) && S_ISSOCK(info.st_mode) && info.st_dev == owned.st_dev && info.st_ino == owned.st_ino) unlink(argv[1]);
        return result;
    }
}
