/* One private local socket and a retained, bounded buffer-snapshot session. */
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

static void interrupt(int signal_number) { (void)signal_number; }

static int safe_directory(const char *directory) {
    char path[sizeof(((struct sockaddr_un *)0)->sun_path)];
    strcpy(path, directory);
    for (;;) {
        struct stat info;
        if (lstat(path, &info) || !S_ISDIR(info.st_mode)) return 0;
        if (!strcmp(path, directory) && (info.st_uid != getuid() || (info.st_mode & 077))) return 0;
        char *slash = strrchr(path, '/');
        if (!slash || slash == path) break;
        *slash = 0;
    }
    return 1;
}

/* Returned output owns the verified native resource until its next version or
 * retirement. All work has completed before returning a successful result. */
static id<MTLBuffer> verify_snapshot(id<MTLDevice> device, id<MTLCommandQueue> queue,
                                     const ff_resource_message *message) {
    id<MTLBuffer> input = [device newBufferWithBytes:message->bytes length:message->length options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [device newBufferWithLength:message->length options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> command = [queue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!input || !output || !command || !blit) { [input release]; [output release]; return nil; }
    [blit copyFromBuffer:input sourceOffset:0 toBuffer:output destinationOffset:0 size:message->length];
    [blit endEncoding];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    [command addCompletedHandler:^(id<MTLCommandBuffer> unused) { (void)unused; dispatch_semaphore_signal(done); }];
    [command commit];
    int completed = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 5LL * NSEC_PER_SEC)) == 0;
    int valid = completed && command.status == MTLCommandBufferStatusCompleted &&
                !memcmp(message->bytes, output.contents, message->length);
    [input release];
    if (!valid) { [output release]; return nil; }
    return output;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        struct sigaction action = {0}; action.sa_handler = interrupt;
        sigemptyset(&action.sa_mask);
        if (sigaction(SIGTERM, &action, NULL) || sigaction(SIGINT, &action, NULL)) return 1;
        if (argc != 2 || argv[1][0] != '/' || strlen(argv[1]) >= sizeof(((struct sockaddr_un *)0)->sun_path)) return 2;
        char path[sizeof(((struct sockaddr_un *)0)->sun_path)]; strcpy(path, argv[1]);
        char *slash = strrchr(path, '/'); if (!slash || slash == path) return 2;
        *slash = 0; struct stat info;
        if (!safe_directory(path)) return 2;
        int listener = socket(AF_UNIX, SOCK_STREAM, 0); if (listener < 0) return 1;
        struct sockaddr_un address = {0}; address.sun_family = AF_UNIX; strcpy(address.sun_path, argv[1]);
        mode_t previous = umask(077);
        int bound = bind(listener, (struct sockaddr *)&address, sizeof(address)) == 0;
        umask(previous);
        if (!bound) { close(listener); return 1; }
        struct stat owned;
        if (lstat(argv[1], &owned) || !S_ISSOCK(owned.st_mode)) { close(listener); return 1; }
        int result = 1, peer = -1;
        struct pollfd ready = {listener, POLLIN, 0};
        if (listen(listener, 1) || poll(&ready, 1, 180000) <= 0 || (peer = accept(listener, NULL, NULL)) < 0) goto cleanup;
        uid_t uid; gid_t gid; ff_resource_channel channel;
        if (getpeereid(peer, &uid, &gid) || uid != getuid() || ff_resource_init(&channel, peer)) goto cleanup;
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (!device || !queue) { [queue release]; goto cleanup; }
        id<MTLBuffer> current = nil;
        size_t length = 0;
        for (uint64_t version = 1; version <= 3; ++version) {
            ff_resource_message message;
            if (ff_resource_receive(&channel, &message)) goto session_end;
            if (message.retire || message.resource != 1 || message.generation != version ||
                (version > 1 && message.length != length)) { ff_resource_discard(&message); goto session_end; }
            id<MTLBuffer> next = verify_snapshot(device, queue, &message);
            if (!next) { ff_resource_discard(&message); goto session_end; }
            length = message.length;
            [current release]; current = next;
            if (ff_resource_ack(&channel, &message)) { ff_resource_discard(&message); goto session_end; }
            printf("GPU blit matched id=1 generation=%llu bytes=%zu\n", (unsigned long long)version, length);
            fflush(stdout);
        }
        {
            ff_resource_message message;
            if (ff_resource_receive(&channel, &message)) goto session_end;
            if (!message.retire || message.resource != 1 || message.generation != 3) {
                ff_resource_discard(&message); goto session_end;
            }
            [current release]; current = nil;
            if (ff_resource_ack(&channel, &message)) { ff_resource_discard(&message); goto session_end; }
            printf("GPU resource retired id=1 generation=3\n");
            result = 0;
        }
session_end:
        [current release]; [queue release];
cleanup:
        if (peer >= 0) close(peer);
        close(listener);
        if (!lstat(argv[1], &info) && S_ISSOCK(info.st_mode) && info.st_dev == owned.st_dev && info.st_ino == owned.st_ino) unlink(argv[1]);
        return result;
    }
}
