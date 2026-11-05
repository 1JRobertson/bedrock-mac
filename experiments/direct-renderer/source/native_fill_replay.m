/* Re-execute one captured DXMT fill on an independently owned ARM64 Metal buffer. */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FILL_MAX_BUFFER (16u * 1024u * 1024u)
static uint32_t get32(const unsigned char *p) {
    uint32_t v = 0; for (unsigned i = 0; i < 4; ++i) v |= (uint32_t)p[i] << (8 * i); return v;
}
static uint64_t get64(const unsigned char *p) {
    uint64_t v = 0; for (unsigned i = 0; i < 8; ++i) v |= (uint64_t)p[i] << (8 * i); return v;
}
static int read_record(const char *path, unsigned char out[40]) {
    if (path[0] != '/') return 0;
    int fd = open(path, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || !S_ISREG(st.st_mode) || st.st_size != 40) { close(fd); return 0; }
    size_t n = 0;
    while (n < 40) {
        ssize_t got = read(fd, out + n, 40 - n);
        if (got < 0 && errno == EINTR) continue;
        if (got <= 0) { close(fd); return 0; }
        n += (size_t)got;
    }
    close(fd);
    return !memcmp(out, "BFFILL1\0", 8) && get32(out + 8) == 1;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        unsigned char record[40];
        if (argc != 2 || !read_record(argv[1], record)) { fprintf(stderr, "Invalid capture; supply an absolute capture path\n"); return 2; }
        uint32_t value = get32(record + 12);
        uint64_t size = get64(record + 16), offset = get64(record + 24), length = get64(record + 32);
        if (value > 255 || !size || size > FILL_MAX_BUFFER || !length || offset > size || length > size - offset) {
            fprintf(stderr, "Unsupported capture bounds\n"); return 2;
        }
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        id<MTLCommandQueue> queue = [device newCommandQueue];
        id<MTLBuffer> buffer = [device newBufferWithLength:(NSUInteger)size options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> command = [queue commandBuffer];
        id<MTLBlitCommandEncoder> encoder = [command blitCommandEncoder];
        if (!device || !queue || !buffer || !command || !encoder || !buffer.contents) { fprintf(stderr, "Metal setup failed\n"); return 1; }
        unsigned char sentinel = (unsigned char)(value + 1);
        memset(buffer.contents, sentinel, (size_t)size);
        [encoder fillBuffer:buffer range:NSMakeRange((NSUInteger)offset, (NSUInteger)length) value:(uint8_t)value];
        [encoder endEncoding]; [command commit]; [command waitUntilCompleted];
        if (command.status != MTLCommandBufferStatusCompleted) { fprintf(stderr, "Metal execution failed\n"); return 1; }
        const unsigned char *bytes = buffer.contents;
        for (uint64_t i = 0; i < size; ++i) {
            unsigned char expected = (i >= offset && i - offset < length) ? (unsigned char)value : sentinel;
            if (bytes[i] != expected) { fprintf(stderr, "Metal result mismatch at byte %llu\n", (unsigned long long)i); return 1; }
        }
        printf("{\"command\":\"fill_buffer\",\"buffer_size\":%llu,\"offset\":%llu,\"length\":%llu,\"value\":%u,\"verified\":true}\n", (unsigned long long)size, (unsigned long long)offset, (unsigned long long)length, value);
        return 0;
    }
}
