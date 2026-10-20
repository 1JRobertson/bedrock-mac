/* SPDX-License-Identifier: GPL-3.0-or-later
 * Synthetic allocator-contract tests; contains no Minecraft code or payload.
 */
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "current_reserve.h"

struct fixture {
    uint64_t allocator[20], arena[20], owner[2];
};
struct descriptor { uint64_t words[6]; unsigned char valid, canary[7]; };
static void set64(void *p, size_t offset, uint64_t value) { memcpy((char *)p + offset, &value, 8); }
static uint64_t get64(const void *p, size_t offset) { uint64_t n; memcpy(&n, (const char *)p + offset, 8); return n; }
static uint32_t get32(const void *p, size_t offset) { uint32_t n; memcpy(&n, (const char *)p + offset, 4); return n; }
static uint16_t get16(const void *p, size_t offset) { uint16_t n; memcpy(&n, (const char *)p + offset, 2); return n; }
static void setup(struct fixture *f, uint64_t first, uint64_t second)
{
    memset(f, 0, sizeof(*f));
    set64(f->allocator, 0, (uintptr_t)f->arena);
    set64(f->arena, 0, 0x12345000);
    set64(f->arena, 8, (uintptr_t)f->owner);
    set64(f->arena, 0x48, 32); set64(f->arena, 0x50, first); set64(f->arena, 0x58, 32);
    set64(f->arena, 0x60, 0x1000000); set64(f->arena, 0x68, second); set64(f->arena, 0x70, 0x1000000);
    set64(f->arena, 0x88, 77);
}
static struct descriptor poison(void)
{
    struct descriptor d;
    memset(&d, 0xa5, sizeof(d));
    return d;
}
static void canary(const struct descriptor *d)
{
    for (unsigned i = 0; i < sizeof(d->canary); ++i) assert(d->canary[i] == 0xa5);
}
static void cases(void)
{
    struct fixture f;
    struct descriptor d = poison(), untouched = d;
    setup(&f, 1056, 0);
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 1);
    assert(d.words[0] == 0x12345000 && d.words[1] == (uintptr_t)f.owner);
    assert(d.words[2] == 32 && d.words[3] == 528 && d.words[4] == 0 && d.words[5] == 77);
    assert(get64(f.arena, 0x58) == 560 && get64(f.arena, 0x40) == 528);
    assert(get64(f.arena, 0x78) == 528 && get64(f.allocator, 0x18) == 528);
    assert(get64(f.arena, 0x90) == 77 && ((unsigned char *)f.arena)[0x98] == 1);
    assert(get32(f.owner, 8) == 1 && get16(f.arena, 0x80) == 1);
    canary(&d);
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 1);
    assert(d.words[2] == 560 && get32(f.owner, 8) == 2);
    d = poison();
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 0);
    assert(!memcmp(&d, &untouched, 48));
    assert(get16(f.arena, 0x80) == 2 && get32(f.owner, 8) == 2);
    canary(&d);

    /* Total free space fits, but neither interval does: one physical attempt,
       no bytes charged, then the original generic allocator owns fallback. */
    setup(&f, 320, 320); d = poison();
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 0);
    assert(get16(f.arena, 0x80) == 1 && get64(f.arena, 0x58) == 32);
    assert(get64(f.arena, 0x70) == 0x1000000 && get64(f.allocator, 0x18) == 0);
    assert(!memcmp(&d, &untouched, 48)); canary(&d);
    setup(&f, 32, 1024); d = poison();
    assert(bad_try_current(f.allocator, &d, 1024, 1) == 1 && d.valid == 1);
    assert(d.words[2] == 0x1000000 && d.words[3] == 1024);
    assert(get64(f.arena, 0x58) == 32 && get64(f.arena, 0x70) == 0x1000400);

    /* Unsupported requests preserve every input byte for the original wrapper. */
    for (unsigned which = 0; which < 4; ++which) {
        size_t bytes = which == 0 ? 0 : which == 1 ? 1025 : 528;
        size_t alignment = which == 2 ? 16 : 1;
        setup(&f, 4096, 0); d = poison();
        if (which == 3) set64(f.allocator, 0x90, 1);
        struct fixture before = f;
        assert(bad_try_current(f.allocator, &d, bytes, alignment) == 0);
        assert(!memcmp(&d, &untouched, sizeof(d)) && !memcmp(&before, &f, sizeof(f)));
    }
    setup(&f, 4096, 0); set64(f.arena, 0x48, UINT64_MAX - 1); d = poison();
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 0);
    assert(get16(f.arena, 0x80) == 0); canary(&d);
    setup(&f, 4096, 0); set64(f.allocator, 0, 0); d = poison();
    assert(bad_try_current(f.allocator, &d, 528, 1) == 1 && d.valid == 0); canary(&d);
}

enum { THREADS = 7, PER_THREAD = 2000 };
struct worker { struct fixture *fixture; uint64_t offsets[PER_THREAD]; };
static void *reserve(void *opaque)
{
    struct worker *w = opaque;
    for (unsigned i = 0; i < PER_THREAD; ++i) {
        struct descriptor d = poison();
        assert(bad_try_current(w->fixture->allocator, &d, 528, 1) == 1 && d.valid == 1);
        assert(d.words[3] == 528 && d.words[5] == 77);
        w->offsets[i] = d.words[2]; canary(&d);
    }
    return NULL;
}
static void concurrent(void)
{
    struct fixture f;
    struct worker *workers = calloc(THREADS, sizeof(*workers));
    unsigned char *seen = calloc(THREADS * PER_THREAD, 1);
    pthread_t threads[THREADS];
    assert(workers && seen);
    setup(&f, THREADS * PER_THREAD * 528, 0);
    for (unsigned i = 0; i < THREADS; ++i) {
        workers[i].fixture = &f;
        assert(!pthread_create(&threads[i], NULL, reserve, &workers[i]));
    }
    for (unsigned i = 0; i < THREADS; ++i) assert(!pthread_join(threads[i], NULL));
    for (unsigned i = 0; i < THREADS; ++i) for (unsigned j = 0; j < PER_THREAD; ++j) {
        uint64_t offset = workers[i].offsets[j] - 32;
        assert(offset % 528 == 0 && offset / 528 < THREADS * PER_THREAD);
        assert(!seen[offset / 528]); seen[offset / 528] = 1;
    }
    assert(get16(f.arena, 0x80) == THREADS * PER_THREAD);
    assert(get32(f.owner, 8) == THREADS * PER_THREAD);
    assert(get64(f.arena, 0x78) == THREADS * PER_THREAD * 528);
    assert(get64(f.arena, 0x40) == THREADS * PER_THREAD * 528);
    assert(get64(f.allocator, 0x18) == THREADS * PER_THREAD * 528);
    free(seen); free(workers);
}
int main(void)
{
    cases(); concurrent();
    puts("exact-current contract and 14000 concurrent reservations passed");
    return 0;
}
