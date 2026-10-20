/* SPDX-License-Identifier: GPL-3.0-or-later
 * Atomic controller for the optional, exact-build frame-slab experiment.
 * This changes one requested setting; existing frames keep their own pool.
 */
/* Darwin exposes O_NOFOLLOW in its full namespace; glibc uses POSIX.1-2008.
 * Keep the actual flag: silently defining it to zero would follow symlinks. */
#if defined(__APPLE__)
#ifndef _DARWIN_C_SOURCE
#define _DARWIN_C_SOURCE 1
#endif
#elif !defined(_POSIX_C_SOURCE)
#define _POSIX_C_SOURCE 200809L
#endif
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define CONTROL_MAGIC UINT64_C(0x3142414c53465242)
#define CONTROL_SIZE (16u * 8u + 512u * 128u)
static int fail(const char *message)
{
    fprintf(stderr, "%s\n", message);
    return 1;
}
int main(int argc, char **argv)
{
    struct stat info;
    uint64_t chunk, *header;
    int fd, status_only;
    if (argc != 3) return fail("Usage: frame-slab-control CONTROL_FILE status|CHUNK_KIB (0,4,16,64)");
    status_only = !strcmp(argv[2], "status");
    if (status_only || !strcmp(argv[2], "0")) chunk = 0;
    else if (!strcmp(argv[2], "4")) chunk = 4096;
    else if (!strcmp(argv[2], "16")) chunk = 16384;
    else if (!strcmp(argv[2], "64")) chunk = 65536;
    else return fail("Chunk size must be exactly 0, 4, 16, or 64 KiB");
    fd = open(argv[1], (status_only ? O_RDONLY : O_RDWR) | O_NOFOLLOW);
    if (fd < 0) return fail("Cannot open existing control file");
    if (fstat(fd, &info) || !S_ISREG(info.st_mode) || info.st_uid != getuid() || info.st_size != CONTROL_SIZE) {
        close(fd); return fail("Control file must be owned by this user and have the exact format size");
    }
    header = mmap(NULL, CONTROL_SIZE, PROT_READ | (status_only ? 0 : PROT_WRITE), MAP_SHARED, fd, 0);
    if (header == MAP_FAILED) { close(fd); return fail("Cannot map control file"); }
    if (header[0] != CONTROL_MAGIC || header[1] != 1 || header[2] != CONTROL_SIZE) {
        munmap(header, CONTROL_SIZE); close(fd); return fail("Unsupported or uninitialized control file");
    }
    /* Aligned, lock-free 64-bit release store matches the adapter's acquire load.
       File writes or Python buffer copies do not establish this atomic contract. */
    if (!__atomic_always_lock_free(8, 0)) {
        munmap(header, CONTROL_SIZE); close(fd); return fail("Controller requires lock-free 64-bit atomics");
    }
    if (status_only) {
        /* These fields are independently atomic, not a coherent frame snapshot.
           Never read the hot, ordinary per-thread counters while the game runs. */
        unsigned long long requested = __atomic_load_n(&header[3], __ATOMIC_ACQUIRE);
        unsigned long long applied = __atomic_load_n(&header[4], __ATOMIC_ACQUIRE);
        unsigned long long registered = __atomic_load_n(&header[5], __ATOMIC_ACQUIRE);
        unsigned long long retired = __atomic_load_n(&header[6], __ATOMIC_ACQUIRE);
        unsigned long long reserved = __atomic_load_n(&header[12], __ATOMIC_ACQUIRE);
        unsigned long long peak = __atomic_load_n(&header[13], __ATOMIC_ACQUIRE);
        unsigned long long live = __atomic_load_n(&header[15], __ATOMIC_ACQUIRE);
        printf("{\"individual_atomic_snapshot\":true,\"coherent_snapshot\":false,"
               "\"requested_chunk_bytes\":%llu,\"applied_chunk_bytes\":%llu,"
               "\"frames_registered\":%llu,\"frames_retired\":%llu,"
               "\"reserved_bytes\":%llu,\"sum_pool_peak_bytes\":%llu,\"live_scopes\":%llu}\n",
               requested, applied, registered, retired, reserved, peak, live);
        munmap(header, CONTROL_SIZE); close(fd); return 0;
    }
    __atomic_store_n(&header[3], chunk, __ATOMIC_RELEASE);
    munmap(header, CONTROL_SIZE); close(fd);
    printf("Requested %llu KiB for newly registered frames\n", (unsigned long long)(chunk / 1024));
    return 0;
}
