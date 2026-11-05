/* Experimental opt-in, retained-buffer snapshot session at presentation cuts. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "resource_transport.h"
#include <pthread.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

/* One process-local session, one retained object, at most three snapshots.
 * IDs are capture-session IDs, not logical D3D resource or object identities. */
enum { SNAPSHOTS = 3 };
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static id<MTLBuffer> selected, retained;
static NSUInteger selected_offset, retained_offset, retained_length;
static uint64_t generation;
static int state, busy; /* 0 = waiting, 1 = active, 2 = finished */
static char endpoint[sizeof(((struct sockaddr_un *)0)->sun_path)];
static dispatch_queue_t writer;
static int transport_fd = -1;
static ff_resource_channel channel;

__attribute__((constructor)) static void resource_setup(void) {
    const char *value = getenv("BEDROCK_FULLFRAME_RESOURCE_SOCKET");
    if (!value || value[0] != '/' || strlen(value) >= sizeof(endpoint)) return;
    memcpy(endpoint, value, strlen(value) + 1);
    writer = dispatch_queue_create("bedrock.full-frame.resource", DISPATCH_QUEUE_SERIAL);
}

void fullframe_resource_candidate(id<MTLBuffer> buffer, NSUInteger offset) {
    if (!writer || !buffer || offset >= buffer.length || (offset & 3) || buffer.length - offset < 4) return;
    pthread_mutex_lock(&lock);
    if (!state) {
        [buffer retain]; [selected release]; selected = buffer; selected_offset = offset;
    }
    pthread_mutex_unlock(&lock);
}

/* Called only by the serial writer. */
static int connect_receiver(void) {
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX; strcpy(address.sun_path, endpoint);
    int fd = socket(AF_UNIX, SOCK_STREAM, 0), connected = 0;
    if (fd >= 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0) {
        int rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
        if (rc == 0) connected = 1;
        else if (errno == EINPROGRESS) {
            struct pollfd p = {fd, POLLOUT, 0};
            int error = 0; socklen_t size = sizeof(error);
            if (poll(&p, 1, 5000) > 0 && !getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) && !error) connected = 1;
        }
    }
    uid_t uid; gid_t gid;
    if (!connected || getpeereid(fd, &uid, &gid) || uid != getuid() || ff_resource_init(&channel, fd)) {
        if (fd >= 0) close(fd);
        return -1;
    }
    transport_fd = fd;
    return 0;
}

static void finish_session(void) {
    pthread_mutex_lock(&lock);
    state = 2; busy = 0;
    [retained release]; retained = nil;
    [selected release]; selected = nil;
    pthread_mutex_unlock(&lock);
}

static void abort_session(void) {
    finish_session();
    dispatch_async(writer, ^{
        if (transport_fd >= 0) close(transport_fd);
        transport_fd = -1;
    });
}

void fullframe_resource_capture(id<MTLCommandBuffer> command) {
    if (!writer) return;
    pthread_mutex_lock(&lock);
    if (state == 2 || busy || (!state && !selected)) { pthread_mutex_unlock(&lock); return; }
    if (!state) {
        retained = selected; selected = nil; retained_offset = selected_offset;
        retained_length = MIN(retained.length - retained_offset, (NSUInteger)65536) & ~(NSUInteger)3;
        state = 1;
    }
    if (retained.device != command.device) { busy = 1; pthread_mutex_unlock(&lock); abort_session(); return; }
    id<MTLBuffer> source = [retained retain];
    NSUInteger offset = retained_offset, length = retained_length;
    uint64_t version = ++generation;
    busy = 1;
    pthread_mutex_unlock(&lock);

    id<MTLBuffer> staging = [[command device] newBufferWithLength:length options:MTLResourceStorageModeShared];
    id<MTLBlitCommandEncoder> blit = staging ? [command blitCommandEncoder] : nil;
    if (!blit) { [source release]; [staging release]; abort_session(); return; }
    [blit copyFromBuffer:source sourceOffset:offset toBuffer:staging destinationOffset:0 size:length];
    [blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> done) {
        int completed = done.status == MTLCommandBufferStatusCompleted;
        dispatch_async(writer, ^{
            @autoreleasepool {
                int ok = completed && (transport_fd >= 0 || connect_receiver() == 0) &&
                         ff_resource_publish(&channel, 1, version, staging.contents, length) == 0 &&
                         ff_resource_wait_ack(&channel) == 0;
                fprintf(stderr, "[full-frame-resource] %s id=1 generation=%llu bytes=%lu\n",
                        ok ? "acknowledged" : "failed", (unsigned long long)version, (unsigned long)length);
                if (ok && version == SNAPSHOTS) {
                    ok = ff_resource_retire(&channel, 1, version) == 0 && ff_resource_wait_ack(&channel) == 0;
                    fprintf(stderr, "[full-frame-resource] %s id=1 generation=%llu\n",
                            ok ? "retired" : "retire-failed", (unsigned long long)version);
                }
                [staging release]; [source release];
                if (!ok || version == SNAPSHOTS) {
                    if (transport_fd >= 0) close(transport_fd);
                    transport_fd = -1; finish_session();
                } else {
                    pthread_mutex_lock(&lock); busy = 0; pthread_mutex_unlock(&lock);
                }
            }
        });
    }];
}
