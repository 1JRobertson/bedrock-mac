// SPDX-License-Identifier: GPL-3.0-or-later
// Exercises the actual C slab core with fake frame ownership. The game must
// independently supply the consumer-quiescence boundary; these tests cannot.
#include "frame_slab_core.h"
#include <array>
#include <atomic>
#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <thread>
#include <vector>

struct Context {
    std::mutex mutex;
    std::atomic<size_t> allocations{0}, frees{0}, live{0};
    bool fail = false;
    uint64_t serial = 0;
};
static void *allocate(void *opaque, size_t bytes)
{
    auto &context = *static_cast<Context *>(opaque);
    context.allocations++;
    if (context.fail) return nullptr;
    void *p = std::malloc(bytes); assert(p); context.live++; return p;
}
static void deallocate(void *opaque, void *p)
{
    auto &context = *static_cast<Context *>(opaque);
    assert(context.live); context.live--; context.frees++; std::free(p);
}
static void lock(void *opaque) { static_cast<Context *>(opaque)->mutex.lock(); }
static void unlock(void *opaque) { static_cast<Context *>(opaque)->mutex.unlock(); }
static bfa_api api(Context &context) { return {&context, allocate, deallocate, lock, unlock, &context.serial}; }
static unsigned char *data(const bfa_descriptor &d) { return *static_cast<unsigned char **>(d.backing) + d.offset; }
struct Record { unsigned char *pointer; size_t size; unsigned char value; };

static void delayed_readers(size_t chunk)
{
    Context context; bfa_pool pool;
    assert(bfa_init(&pool, api(context), chunk, 16 * 1024 * 1024, 32 * 1024 * 1024));
    auto key = bfa_register_frame(&pool, 1, 0x2040, 71, 3); assert(key.incarnation);
    std::array<std::vector<Record>, 7> records;
    std::vector<std::thread> workers;
    for (size_t t = 0; t < records.size(); ++t) workers.emplace_back([&, t] {
        bfa_worker_cache cache{}; bfa_lease lease{};
        assert(bfa_enter(&pool, 0x2040, 71, 3, &lease));
        for (size_t i = 0; i < 2000; ++i) {
            size_t bytes = i % 100 == 0 ? 80 : i % 313 == 0 ? 112 : 528;
            bfa_descriptor d;
            assert(bfa_allocate(&lease, &cache, bytes, 1, &d));
            assert(!d.control && d.size == bytes && d.generation == 71);
            assert(reinterpret_cast<uintptr_t>(data(d)) % 16 == 0);
            auto value = static_cast<unsigned char>((i + t) % 251 + 1);
            std::memset(data(d), value, bytes); records[t].push_back({data(d), bytes, value});
        }
        bfa_leave(&lease);
    });
    for (auto &thread : workers) thread.join();
    assert(bfa_close(&pool, key));
    // Closing admission and dropping all producer leases must not free payloads.
    for (const auto &part : records) for (const auto &r : part)
        for (size_t i = 0; i < r.size; ++i) assert(r.pointer[i] == r.value);
    auto stats = bfa_get_statistics(&pool);
    assert(stats.reserved_bytes && stats.live_scopes == 1 && stats.refills < 14000 / 4);
    assert(bfa_retire_after_quiescence(&pool, key));
    assert(!bfa_get_statistics(&pool).reserved_bytes && !context.live);
    assert(context.allocations == context.frees);
}
static void lifetime_and_cache_reuse()
{
    Context context; bfa_pool pool; bfa_worker_cache cache{}; bfa_key previous{};
    for (unsigned iteration = 0; iteration < 1000; ++iteration) {
        // Same pool address, frame, token, allocator and generation; serial persists.
        assert(bfa_init(&pool, api(context), 4096, 16384, 32768));
        auto key = bfa_register_frame(&pool, 1, 0x2040, 7, 3);
        assert(key.incarnation && key.incarnation != previous.incarnation);
        if (previous.incarnation) assert(!bfa_retire_after_quiescence(&pool, previous));
        auto captured = bfa_capture_key(&pool, 1, 0x2040);
        assert(captured.slot == key.slot && captured.incarnation == key.incarnation);
        assert(!bfa_capture_key(&pool, 2, 0x2040).incarnation);
        bfa_lease lease{}; bfa_descriptor d, next;
        assert(!bfa_enter(&pool, 0x2040, 8, 3, &lease));
        assert(!bfa_enter(&pool, 0x2040, 7, 4, &lease));
        assert(bfa_enter(&pool, 0x2040, 7, 3, &lease));
        assert(bfa_allocate(&lease, &cache, 528, 1, &d) && d.offset == 0);
        std::memset(data(d), 0x71, 528);
        assert(!bfa_retire_after_quiescence(&pool, key)); // Active producer blocks free.
        bfa_lease rejected{}; assert(!bfa_enter(&pool, 0x2040, 7, 3, &rejected));
        assert(bfa_allocate(&lease, &cache, 80, 1, &next)); // Existing task may finish.
        bfa_leave(&lease); bfa_leave(&lease);
        for (size_t i = 0; i < 528; ++i) assert(data(d)[i] == 0x71);
        assert(bfa_retire_after_quiescence(&pool, key)); assert(!context.live);
        previous = key;
    }
    assert(context.allocations == context.frees);
}
static void out_of_order_retirement()
{
    Context context; bfa_pool pool; bfa_worker_cache cache{}; bfa_lease lease{};
    assert(bfa_init(&pool, api(context), 16384, 32768, 65536));
    auto old = bfa_register_frame(&pool, 1, 0x2040, 7, 3);
    auto later = bfa_register_frame(&pool, 2, 0x3040, 8, 3);
    assert(old.incarnation && later.incarnation);
    assert(bfa_enter(&pool, 0x2040, 7, 3, &lease));
    bfa_descriptor d; assert(bfa_allocate(&lease, &cache, 528, 1, &d));
    std::memset(data(d), 0x7c, 528); bfa_leave(&lease);
    assert(bfa_retire_after_quiescence(&pool, later));
    for (size_t i = 0; i < 528; ++i) assert(data(d)[i] == 0x7c);
    assert(context.live == 1); assert(bfa_retire_after_quiescence(&pool, old));
    assert(!context.live);
}
static void failures_and_bounds()
{
    Context context; bfa_pool pool; bfa_worker_cache cache{}; bfa_lease lease{};
    const size_t charge = 4096 + sizeof(bfa_chunk);
    assert(bfa_init(&pool, api(context), 4096, 2 * charge, 2 * charge));
    auto key = bfa_register_frame(&pool, 1, 0x2040, 7, 3); assert(key.incarnation);
    assert(bfa_enter(&pool, 0x2040, 7, 3, &lease));
    bfa_descriptor canary{reinterpret_cast<void *>(1), reinterpret_cast<void *>(2), 3, 4, 5, 6}, d = canary;
    context.fail = true;
    assert(!bfa_allocate(&lease, &cache, 1024, 1, &d));
    assert(!std::memcmp(&d, &canary, sizeof(d)) && !pool.reserved && !pool.slots[key.slot].reserved);
    context.fail = false;
    for (unsigned i = 0; i < 8; ++i) assert(bfa_allocate(&lease, &cache, 1024, 1, &d));
    assert(pool.reserved == 2 * charge && context.live == 2);
    d = canary; auto allocations = context.allocations.load();
    for (auto bytes : {size_t(0), size_t(1), size_t(1025)}) {
        assert(!bfa_allocate(&lease, &cache, bytes, 1, &d));
        assert(!std::memcmp(&d, &canary, sizeof(d)));
    }
    assert(!bfa_allocate(&lease, &cache, 80, 16, &d));
    assert(context.allocations == allocations); // Cap fails before backing allocation.
    bfa_leave(&lease); assert(bfa_retire_after_quiescence(&pool, key)); assert(!context.live);

    std::vector<bfa_key> keys; unsigned rejected = 0;
    for (uintptr_t i = 0; i < 128; ++i) {
        auto k = bfa_register_frame(&pool, i + 1, 0x100040 + i * 0x80, i, 3);
        if (k.incarnation) keys.push_back(k); else ++rejected;
    }
    assert(rejected && keys.size() <= BFA_SLOTS);
    for (auto k : keys) assert(bfa_retire_after_quiescence(&pool, k));
    context.serial = UINT64_MAX;
    assert(!bfa_register_frame(&pool, 1, 0x2040, 7, 3).incarnation);
    assert(!bfa_get_statistics(&pool).live_scopes);
}
int main()
{
    for (size_t chunk : {4096, 16384, 65536}) delayed_readers(chunk);
    lifetime_and_cache_reuse(); out_of_order_retirement(); failures_and_bounds();
    std::puts("frame slab passed: 42000 delayed-reader allocations, 1000 cache/pool reuses, failure and bounds checks");
}
