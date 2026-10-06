/* Correctness probe for retaining more fully freed process-heap LFH groups.
 * Build as Win64 C. Run unchanged against baseline and candidate Wine runtimes.
 * This is not a benchmark and does not require addresses to be reused: neither
 * address reuse nor Wine's internal cache depth is part of the Heap API contract.
 * In the pinned Wine build, a 32-byte request maps to a 48-byte LFH block.
 * 131072 live requests exceed 4096 groups of 31 blocks, exercising cache overflow.
 * Harness arrays use VirtualAlloc to keep their allocations out of that bin.
 */
#define _WIN32_WINNT 0x0600
#include <windows.h>
#include <stdint.h>
#include <stdio.h>

enum { BURST_COUNT = 131072, BURST_ROUNDS = 6, REALLOC_COUNT = 2048,
       MIXED_COUNT = 8192, WORKERS = 4, WORKER_COUNT = 32768, WORKER_ROUNDS = 6 };

struct counts { uint64_t allocations, reallocations, frees; };
struct item { unsigned char *ptr; SIZE_T size; uint32_t token; };
struct barrier { CRITICAL_SECTION lock; CONDITION_VARIABLE changed; unsigned arrived, epoch; };
struct worker { unsigned id; HANDLE heap; struct item *items; struct counts counts; };
static struct barrier barrier;
static struct worker workers[WORKERS];
static volatile LONG failed;
static HANDLE finished;

static void fail(const char *operation, unsigned actor, unsigned round, unsigned index, SIZE_T offset)
{
    DWORD error = GetLastError();
    if (!InterlockedCompareExchange(&failed, 1, 0)) {
        printf("{\"result\":\"fail\",\"operation\":\"%s\",\"actor\":%u,\"round\":%u,"
               "\"index\":%u,\"offset\":%llu,\"last_error\":%lu}\n",
               operation, actor, round, index, (unsigned long long)offset, (unsigned long)error);
        fflush(stdout);
    }
    ExitProcess(1);
}

static unsigned char pattern(uint32_t token, SIZE_T offset)
{
    return (unsigned char)((token >> ((offset & 3) * 8)) ^ (offset * 0x5b));
}

static void fill(struct item *item)
{
    SIZE_T j;
    for (j = 0; j < item->size; ++j) item->ptr[j] = pattern(item->token, j);
}

static void verify(const struct item *item, const char *phase, unsigned actor, unsigned round, unsigned index)
{
    SIZE_T j;
    for (j = 0; j < item->size; ++j)
        if (item->ptr[j] != pattern(item->token, j)) fail(phase, actor, round, index, j);
}

static void verify_zero(const unsigned char *ptr, SIZE_T start, SIZE_T end,
                        unsigned actor, unsigned round, unsigned index)
{
    SIZE_T j;
    for (j = start; j < end; ++j)
        if (ptr[j]) fail("zero_memory", actor, round, index, j);
}

static struct item *new_items(unsigned count)
{
    struct item *items = VirtualAlloc(NULL, count * sizeof(*items), MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
    if (!items) fail("harness_virtual_alloc", 0, 0, count, 0);
    return items;
}

static void delete_items(struct item *items)
{
    if (!VirtualFree(items, 0, MEM_RELEASE)) fail("harness_virtual_free", 0, 0, 0, 0);
}

static void allocate_item(HANDLE heap, struct item *item, SIZE_T size, uint32_t token, DWORD flags,
                          struct counts *counts, unsigned actor, unsigned round, unsigned index)
{
    item->ptr = HeapAlloc(heap, flags, size);
    if (!item->ptr) fail("heap_alloc", actor, round, index, size);
    if ((uintptr_t)item->ptr & 15) fail("allocation_alignment", actor, round, index, size);
    item->size = size;
    item->token = token;
    ++counts->allocations;
    if (flags & HEAP_ZERO_MEMORY) verify_zero(item->ptr, 0, size, actor, round, index);
    fill(item);
}

static void free_item(HANDLE heap, struct item *item, struct counts *counts,
                      unsigned actor, unsigned round, unsigned index)
{
    if (!HeapFree(heap, 0, item->ptr)) fail("heap_free", actor, round, index, item->size);
    item->ptr = NULL;
    ++counts->frees;
}

static void validate_heap(HANDLE heap, unsigned actor)
{
    if (!HeapValidate(heap, 0, NULL)) fail("heap_validate", actor, 0, 0, 0);
}

static void check_size(HANDLE heap, const struct item *item, unsigned index)
{
    SIZE_T size = HeapSize(heap, 0, item->ptr);
    if (size == (SIZE_T)-1 || size < item->size) fail("heap_size", 0, 0, index, size);
}

static void test_bursts(HANDLE heap, struct counts *counts)
{
    struct item *items = new_items(BURST_COUNT);
    unsigned round, i;
    ULONG mode = 0;
    for (round = 0; round < BURST_ROUNDS; ++round) {
        for (i = 0; i < BURST_COUNT; ++i)
            allocate_item(heap, &items[i], 32, (round << 20) | i,
                          (round & 1) ? HEAP_ZERO_MEMORY : 0, counts, 0, round, i);
        check_size(heap, &items[0], 0);
        check_size(heap, &items[BURST_COUNT - 1], BURST_COUNT - 1);
        /* Free alternating blocks first, checking survivors while the heap fragments. */
        for (i = 0; i < BURST_COUNT; i += 2) {
            verify(&items[i], "burst_even", 0, round, i);
            free_item(heap, &items[i], counts, 0, round, i);
        }
        for (i = BURST_COUNT - 1; i > 0; i -= 2) {
            verify(&items[i], "burst_survivor", 0, round, i);
            free_item(heap, &items[i], counts, 0, round, i);
            if (i == 1) break;
        }
        validate_heap(heap, 0);
    }
    if (!HeapQueryInformation(heap, HeapCompatibilityInformation, &mode, sizeof(mode), NULL) || mode != 2)
        fail("lfh_not_active", 0, 0, mode, 0);
    delete_items(items);
}

static void resize_item(HANDLE heap, struct item *item, SIZE_T size, DWORD flags,
                        struct counts *counts, unsigned index)
{
    SIZE_T old_size = item->size, preserved = old_size < size ? old_size : size;
    unsigned char *ptr = HeapReAlloc(heap, flags, item->ptr, size);
    if (!ptr) fail("heap_realloc", 0, 0, index, size);
    item->ptr = ptr;
    item->size = preserved;
    verify(item, "realloc_preservation", 0, 0, index);
    if ((flags & HEAP_ZERO_MEMORY) && size > old_size) verify_zero(ptr, old_size, size, 0, 0, index);
    item->size = size;
    check_size(heap, item, index);
    fill(item);
    ++counts->reallocations;
}

static void test_realloc(HANDLE heap, struct counts *counts)
{
    struct item *items = new_items(REALLOC_COUNT);
    unsigned i;
    for (i = 0; i < REALLOC_COUNT; ++i)
        allocate_item(heap, &items[i], 32, 0x40000000u | i, 0, counts, 0, 0, i);
    for (i = 0; i < REALLOC_COUNT; ++i) {
        resize_item(heap, &items[i], 97, HEAP_ZERO_MEMORY, counts, i);
        resize_item(heap, &items[i], 17, 0, counts, i);
        resize_item(heap, &items[i], 4096, HEAP_ZERO_MEMORY, counts, i);
        resize_item(heap, &items[i], 32, 0, counts, i);
    }
    for (i = 0; i < REALLOC_COUNT; ++i) {
        verify(&items[i], "realloc_neighbor", 0, 0, i);
        free_item(heap, &items[i], counts, 0, 0, i);
    }
    validate_heap(heap, 0);
    delete_items(items);
}

static void test_mixed(HANDLE heap, unsigned actor, struct counts *counts)
{
    /* Multiple neighboring requests share bins; this count also overflows the
     * original 33-group cache in the private heap's 48-byte block-size bin.
     */
    static const SIZE_T sizes[] = {1, 8, 16, 17, 31, 32, 33, 47, 48, 49, 64, 96, 256, 1024, 4096, 16384, 65537};
    struct item *items = new_items(MIXED_COUNT);
    unsigned i;
    for (i = 0; i < MIXED_COUNT; ++i)
        allocate_item(heap, &items[i], sizes[i % (sizeof(sizes) / sizeof(*sizes))],
                      0x50000000u | (actor << 20) | i, HEAP_ZERO_MEMORY, counts, actor, 0, i);
    for (i = 0; i < MIXED_COUNT; i += 2) {
        verify(&items[i], "mixed_before_free", actor, 0, i);
        free_item(heap, &items[i], counts, actor, 0, i);
    }
    for (i = 0; i < MIXED_COUNT; i += 2)
        allocate_item(heap, &items[i], sizes[(i + 1) % (sizeof(sizes) / sizeof(*sizes))],
                      0x60000000u | (actor << 20) | i, HEAP_ZERO_MEMORY, counts, actor, 1, i);
    for (i = MIXED_COUNT; i-- > 0;) {
        verify(&items[i], "mixed_after_reuse", actor, 1, i);
        check_size(heap, &items[i], i);
        free_item(heap, &items[i], counts, actor, 1, i);
    }
    validate_heap(heap, actor);
    delete_items(items);
}

static void meet(unsigned actor, unsigned round)
{
    unsigned epoch;
    EnterCriticalSection(&barrier.lock);
    epoch = barrier.epoch;
    if (++barrier.arrived == WORKERS) {
        barrier.arrived = 0;
        ++barrier.epoch;
        WakeAllConditionVariable(&barrier.changed);
    } else {
        while (epoch == barrier.epoch)
            if (!SleepConditionVariableCS(&barrier.changed, &barrier.lock, 30000))
                fail("barrier_wait", actor, round, 0, 0);
    }
    LeaveCriticalSection(&barrier.lock);
}

static DWORD WINAPI run_worker(void *opaque)
{
    struct worker *worker = opaque;
    unsigned round, i, owner;
    for (round = 0; round < WORKER_ROUNDS; ++round) {
        for (i = 0; i < WORKER_COUNT; ++i)
            allocate_item(worker->heap, &worker->items[i], 32,
                          0x80000000u | (worker->id << 24) | (round << 20) | i,
                          (round & 1) ? HEAP_ZERO_MEMORY : 0,
                          &worker->counts, worker->id, round, i);
        meet(worker->id, round); /* Publish complete arrays before another thread reads them. */
        /* Interleave frees from all workers within each allocation owner's array.
         * This stresses concurrent frees of distinct blocks in the same LFH group,
         * including the race to free its final blocks. Each item has one freer.
         */
        for (owner = 0; owner < WORKERS; ++owner) {
            struct worker *other = &workers[owner];
            for (i = worker->id; i < WORKER_COUNT; i += WORKERS) {
                verify(&other->items[i], "cross_thread_content", worker->id, round, i);
                free_item(worker->heap, &other->items[i], &worker->counts, worker->id, round, i);
            }
        }
        meet(worker->id, round); /* Finish all cross-thread frees before overwriting arrays. */
    }
    return 0;
}

static void test_workers(HANDLE heap, struct counts *counts)
{
    HANDLE threads[WORKERS];
    unsigned i;
    InitializeCriticalSection(&barrier.lock);
    InitializeConditionVariable(&barrier.changed);
    for (i = 0; i < WORKERS; ++i) {
        workers[i].id = i;
        workers[i].heap = heap;
        workers[i].items = new_items(WORKER_COUNT);
    }
    for (i = 0; i < WORKERS; ++i) {
        threads[i] = CreateThread(NULL, 0, run_worker, &workers[i], 0, NULL);
        if (!threads[i]) fail("create_worker", i, 0, 0, 0);
    }
    if (WaitForMultipleObjects(WORKERS, threads, TRUE, 90000) != WAIT_OBJECT_0)
        fail("join_workers", 0, 0, 0, 0);
    for (i = 0; i < WORKERS; ++i) {
        DWORD exit_code;
        if (!GetExitCodeThread(threads[i], &exit_code) || exit_code) fail("worker_exit", i, 0, 0, 0);
        CloseHandle(threads[i]);
        delete_items(workers[i].items);
        counts->allocations += workers[i].counts.allocations;
        counts->frees += workers[i].counts.frees;
    }
    DeleteCriticalSection(&barrier.lock);
    validate_heap(heap, 0); /* Includes groups returned by thread-detach cleanup. */
}

static DWORD WINAPI watchdog(void *unused)
{
    (void)unused;
    if (WaitForSingleObject(finished, 120000) != WAIT_OBJECT_0) fail("deadline", 0, 0, 0, 0);
    return 0;
}

int main(void)
{
    struct counts counts = {0};
    HANDLE heap = GetProcessHeap(), private_heap, guard;
    unsigned i;
    finished = CreateEventW(NULL, TRUE, FALSE, NULL);
    if (!finished) fail("create_deadline_event", 0, 0, 0, 0);
    guard = CreateThread(NULL, 0, watchdog, NULL, 0, NULL);
    if (!guard) fail("create_watchdog", 0, 0, 0, 0);
    test_bursts(heap, &counts);
    test_realloc(heap, &counts);
    test_mixed(heap, 0, &counts);
    /* Repeated create/destroy catches retained groups escaping private-heap lifetime. */
    for (i = 1; i <= 2; ++i) {
        private_heap = HeapCreate(0, 0, 0);
        if (!private_heap) fail("create_private_heap", i, 0, 0, 0);
        test_mixed(private_heap, i, &counts);
        if (!HeapDestroy(private_heap)) fail("destroy_private_heap", i, 0, 0, 0);
    }
    test_workers(heap, &counts);
    /* Refill after all worker threads exit, testing their cached groups' lifetime. */
    test_bursts(heap, &counts);
    if (counts.allocations != counts.frees) fail("count_mismatch", 0, 0, 0, 0);
    if (!SetEvent(finished) || WaitForSingleObject(guard, 5000) != WAIT_OBJECT_0)
        fail("stop_watchdog", 0, 0, 0, 0);
    CloseHandle(guard);
    CloseHandle(finished);
    printf("{\"result\":\"pass\",\"allocations\":%llu,\"reallocations\":%llu,\"frees\":%llu,"
           "\"burst_live_blocks\":%u,\"workers\":%u,\"worker_rounds\":%u,\"private_heaps\":2,\"lfh\":true}\n",
           (unsigned long long)counts.allocations, (unsigned long long)counts.reallocations,
           (unsigned long long)counts.frees, BURST_COUNT, WORKERS, WORKER_ROUNDS);
    return 0;
}
