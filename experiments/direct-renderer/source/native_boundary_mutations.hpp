#pragma once
/* Application-thread Unmap seals bytes BEFORE queued encoding can see reuse.
 * Allocation generation is resolved later on its ordered encoding owner. */
#include "native_boundary_capture.hpp"
#include <atomic>
#include <memory>
#include <unordered_map>
#include <vector>

namespace dxmt::boundary_mutations {
inline bool uploads_configured(){
#ifdef BEDROCK_BOUNDARY_UPLOADS
  static const bool enabled=[] {const char *v=std::getenv("BEDROCK_BOUNDARY_UPLOADS");return v&&std::strcmp(v,"1")==0;}();return enabled;
#else
  return false;
#endif
}
inline bool configured(){
  static const bool enabled=[] {const char *v=std::getenv("BEDROCK_BOUNDARY_MUTATIONS");return v&&std::strcmp(v,"1")==0;}();
  return uploads_configured()||(enabled&&boundary_capture::configured());
}
inline void reject(unsigned reason){
  boundary_capture::writer().reject(reason);
#ifdef BEDROCK_BOUNDARY_UPLOADS
  if(uploads_configured())WMTBoundaryUpload(0,0,0,nullptr,0,0);
#endif
}
inline std::mutex mapped_lock;
inline std::unordered_map<const void *,uint32_t> mapped_types;
inline std::atomic<size_t> pending_bytes{0};
constexpr size_t pending_limit=64u*1024u*1024u;
struct SealedWrite {
  std::vector<uint8_t> bytes;
  explicit SealedWrite(size_t length):bytes(length){}
  ~SealedWrite(){pending_bytes.fetch_sub(bytes.size(),std::memory_order_relaxed);}
};
inline void mapped(const void *resource,uint32_t type){
  if(!configured())return;
  // Reject unsupported writes before Map can expose mutable bytes.
  if(type!=4){reject(12);return;}
  bool invalid=false;
  {std::lock_guard<std::mutex> lock(mapped_lock);
    invalid=!resource||mapped_types.size()>=4096||!mapped_types.emplace(resource,type).second;}
  if(invalid)reject(11);
}
inline std::shared_ptr<SealedWrite> seal(const void *resource,const void *bytes,size_t length){
  if(!configured())return {};
  uint32_t type=0;
  {std::lock_guard<std::mutex> lock(mapped_lock);auto it=mapped_types.find(resource);
    if(it!=mapped_types.end()){type=it->second;mapped_types.erase(it);}}
  if(!uploads_configured()&&!boundary_capture::writer().active())return {};
  // Only WRITE_DISCARD is admitted. No assumptions about NO_OVERWRITE ranges.
  if(type!=4||!bytes||!length||length>32u*1024u*1024u){reject(12);return {};}
  size_t prior=pending_bytes.load(std::memory_order_relaxed);
  do {if(prior>pending_limit-length){reject(13);return {};}}
  while(!pending_bytes.compare_exchange_weak(prior,prior+length,std::memory_order_relaxed));
  std::shared_ptr<SealedWrite> result;
  try {result=std::make_shared<SealedWrite>(length);}
  catch(...){pending_bytes.fetch_sub(length,std::memory_order_relaxed);reject(14);return {};}
  std::memcpy(result->bytes.data(),bytes,length);return result;
}
} // namespace dxmt::boundary_mutations
