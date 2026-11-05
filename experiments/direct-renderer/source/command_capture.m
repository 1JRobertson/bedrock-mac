/* Opt-in capture of one actual DXMT blit fill. No game buffer bytes or handles. */
#import <Metal/Metal.h>
#import <dispatch/dispatch.h>
#include "resource_transport.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <poll.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>

#define FILL_MAX_BUFFER (16u * 1024u * 1024u)
static atomic_flag capture_busy = ATOMIC_FLAG_INIT;
static _Atomic int captured;
static int capture_dir = -1;
static char fill_endpoint[sizeof(((struct sockaddr_un *)0)->sun_path)];
static dispatch_queue_t fill_writer;

static void send_live_fill(const unsigned char record[40]) {
    if (!fill_writer) return;
    unsigned char *copy = malloc(40);
    if (!copy) return;
    memcpy(copy, record, 40);
    dispatch_async(fill_writer, ^{
        int ok = 0, fd = socket(AF_UNIX, SOCK_STREAM, 0);
        if (fd >= 0 && fcntl(fd, F_SETFL, O_NONBLOCK) == 0) {
            struct sockaddr_un address = {0};
            address.sun_family = AF_UNIX; strcpy(address.sun_path, fill_endpoint);
            int rc = connect(fd, (struct sockaddr *)&address, sizeof(address));
            int connected = rc == 0;
            if (!connected && errno == EINPROGRESS) {
                struct pollfd ready = {fd, POLLOUT, 0};
                int error = 0; socklen_t size = sizeof(error);
                if (poll(&ready, 1, 5000) > 0 && !getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) && !error) connected = 1;
            }
            uid_t uid; gid_t gid; ff_resource_channel channel;
            if (connected && getpeereid(fd, &uid, &gid) == 0 && uid == getuid() &&
                !ff_resource_init(&channel, fd) && !ff_resource_publish(&channel, 1, 1, copy, 40) &&
                !ff_resource_wait_ack(&channel)) ok = 1;
        }
        if (fd >= 0) close(fd);
        if (ok) {
            int ack = openat(capture_dir, "fill.ack", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
            if (ack >= 0) { (void)write(ack, "completed\n", 10); close(ack); }
        }
        fprintf(stderr, "[full-frame-fill] live duplicate %s\n", ok ? "GPU-completion acknowledged" : "failed");
        free(copy);
    });
}

__attribute__((constructor)) static void initialize_fill_capture(void) {
    const char *path = getenv("BEDROCK_FULLFRAME_DIR");
    if (!path || path[0] != '/') return;
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) { close(fd); return; }
    capture_dir = fd;
    const char *endpoint = getenv("BEDROCK_FULLFRAME_FILL_SOCKET");
    if (endpoint && endpoint[0] == '/' && strlen(endpoint) < sizeof(fill_endpoint)) {
        strcpy(fill_endpoint, endpoint);
        fill_writer = dispatch_queue_create("bedrock.full-frame.fill", DISPATCH_QUEUE_SERIAL);
    }
}

static void put32(unsigned char *p, uint32_t v) {
    for (unsigned i = 0; i < 4; ++i) p[i] = (unsigned char)(v >> (8 * i));
}
static void put64(unsigned char *p, uint64_t v) {
    for (unsigned i = 0; i < 8; ++i) p[i] = (unsigned char)(v >> (8 * i));
}

/* Called immediately before DXMT submits the original encoder command. */
void fullframe_capture_fill(id<MTLBuffer> buffer, uint64_t offset, uint64_t length, unsigned value) {
    if (capture_dir < 0 || atomic_load(&captured) || !buffer) return;
    uint64_t size = (uint64_t)[buffer length];
    if (!size || size > FILL_MAX_BUFFER || !length || offset > size || length > size - offset || value > 255) return;
    if (atomic_flag_test_and_set(&capture_busy)) return;
    if (atomic_load(&captured)) { atomic_flag_clear(&capture_busy); return; }
    struct stat arm;
    if (fstatat(capture_dir, "fill.arm", &arm, AT_SYMLINK_NOFOLLOW) || !S_ISREG(arm.st_mode) || arm.st_uid != getuid()) {
        atomic_flag_clear(&capture_busy); return;
    }
    unsigned char record[40] = {'B','F','F','I','L','L','1','\0'};
    put32(record + 8, 1); put32(record + 12, value);
    put64(record + 16, size); put64(record + 24, offset); put64(record + 32, length);
    int fd = openat(capture_dir, "fill.bin", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd >= 0) {
        (void)unlinkat(capture_dir, "fill.arm", 0);
        size_t written = 0;
        while (written < sizeof(record)) {
            ssize_t n = write(fd, record + written, sizeof(record) - written);
            if (n < 0 && errno == EINTR) continue;
            if (n <= 0) break;
            written += (size_t)n;
        }
        close(fd);
        if (written == sizeof(record)) send_live_fill(record);
        /* A partial record is left in place and rejected by the reader. */
        atomic_store(&captured, 1);
    }
    atomic_flag_clear(&capture_busy);
}
