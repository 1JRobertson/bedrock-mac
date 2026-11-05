#pragma once
/* Optional, synchronous PE-side entry point for an ordered native producer.
 * Local pointers are borrowed for the duration of a callback ONLY. This is
 * deliberately not a wire ABI, GPU completion, or permission to skip DXMT. */
#include <atomic>
#include <cstdint>

namespace dxmt {
namespace native_entry {

constexpr uint32_t kVersion = 1;
enum class Stage : uint32_t {
  Encoder = 1, RenderPass = 2, ClearPass = 3, ResolvePass = 4,
  VisibilityState = 5, TimestampState = 6, PendingQueries = 7, Readbacks = 8
};
/* Prelude visits use this ordinal and occur before the first encoder. */
constexpr uint32_t kPrelude = UINT32_MAX;

struct Chunk {
  uint64_t stream, frame, chunk, initializer, completion;
  uint32_t encoders, reserved;
};

/* Sink and user storage must remain alive for the process lifetime. Callbacks
 * may run on multiple DXMT contexts concurrently. Never hold a source pointer
 * after returning, re-enter DXMT, or confuse this observation with completion.
 * Return false on unsupported input or transport failure. finish still runs and
 * reports failure; the existing source renderer always continues normally. */
struct Sink {
  uint32_t version, bytes;
  void *user;
  bool (*begin)(void *, const Chunk &);
  bool (*visit)(void *, const Chunk &, uint32_t ordinal, Stage, const void *object);
  void (*finish)(void *, const Chunk &, const void *readbacks, bool accepted);
};

inline std::atomic<const Sink *> installed{nullptr};
inline std::atomic<uint64_t> next_stream{1};

/* Install once before producing any chunk. Never replace/unregister a sink
 * while callbacks may be active. A missing or invalid sink leaves DXMT intact. */
inline bool install(const Sink *sink) {
  if (!sink || sink->version != kVersion || sink->bytes != sizeof(Sink) ||
      !sink->begin || !sink->visit || !sink->finish) return false;
  const Sink *empty = nullptr;
  return installed.compare_exchange_strong(empty, sink, std::memory_order_release,
                                            std::memory_order_relaxed);
}

class Session {
  const Sink *sink_;
  Chunk chunk_;
  bool accepted_;
public:
  Session(const Chunk &chunk) : sink_(installed.load(std::memory_order_acquire)), chunk_(chunk), accepted_(false) {
    if (sink_) accepted_ = sink_->begin(sink_->user, chunk_);
  }
  void visit(uint32_t ordinal, Stage stage, const void *object) {
    if (sink_ && accepted_) accepted_ = object && sink_->visit(sink_->user, chunk_, ordinal, stage, object);
  }
  void finish(const void *readbacks) {
    if (sink_) sink_->finish(sink_->user, chunk_, readbacks, accepted_);
    sink_ = nullptr;
  }
  Session(const Session &) = delete;
  Session &operator=(const Session &) = delete;
};

class Source {
  const uint64_t stream_ = next_stream.fetch_add(1, std::memory_order_relaxed);
public:
  Session begin(uint64_t frame, uint64_t chunk, uint64_t initializer,
                uint64_t completion, uint32_t encoders) {
    return Session(Chunk{stream_, frame, chunk, initializer, completion, encoders, 0});
  }
};
} // namespace native_entry
} // namespace dxmt
