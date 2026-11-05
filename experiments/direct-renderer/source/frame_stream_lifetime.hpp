#pragma once
/* Source allocation destruction and superseded generations, shared across PE
 * translation units. Generation zero means destruction of the whole root.
 * This queue contains integer identities only; native GPU release is separate. */
#include <cstdint>
#include <mutex>
#include <vector>
#include <cstdlib>
#include <cstring>
namespace dxmt {
struct FrameStreamLifetime {
  struct Root {uint64_t kind,root,generation;};
  inline static std::mutex mutex;
  inline static std::vector<Root> released;
  inline static bool overflow=false;
  static bool enabled(){const char *mode=std::getenv("DXMT_CHUNK_STREAM");return mode&&!std::strcmp(mode,"1");}
  static void release(uint64_t kind,uint64_t root,uint64_t generation=0) {
    if(!root)return;std::lock_guard<std::mutex> lock(mutex);
    if(released.size()==4096){overflow=true;return;}released.push_back({kind,root,generation});
  }
  static bool take(std::vector<Root> &out) {
    std::lock_guard<std::mutex> lock(mutex);if(overflow)return false;out.swap(released);return true;
  }
  static void discard(){std::lock_guard<std::mutex> lock(mutex);released.clear();overflow=false;}
};
}
