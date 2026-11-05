#pragma once
/* Bounded, default-off admission census. Optional Unmap payloads are copied to
 * a separate private sidecar; no pointers or rendering replacement on wire. */
#include <array>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <mutex>
#include <string>
#include <fcntl.h>
#include <sys/stat.h>
#ifdef _WIN32
#include <io.h>
#else
#include <unistd.h>
#endif

namespace dxmt::boundary_capture {
constexpr uint64_t magic = UINT64_C(0x31435042434e4246);
constexpr uint64_t max_records = 4*1024*1024;
constexpr uint64_t max_encoded_bytes = 64*1024*1024; // Same disk budget; compact integers, no dropped events.
constexpr uint64_t max_frames = 600;
enum Kind : uint64_t { BeginChunk=1, EndChunk=2, Render=3, Resource=4,
  DynamicMap=5, OtherEncoder=6, EndCapture=7, Rejected=8, DynamicWrite=9 };
struct Record {
  uint64_t kind, serial, stream, frame, chunk, encoder;
  std::array<uint64_t,10> values;
};
static_assert(sizeof(Record)==128);
inline bool configured() {
  static const bool enabled = [] {const char *p=std::getenv("BEDROCK_BOUNDARY_CAPTURE");return p&&*p;}();
  return enabled;
}
class Writer {
  std::mutex mutex_;
  FILE *file_=nullptr;
  FILE *mutations_=nullptr;
  uint64_t mutation_bytes_=0;
  bool terminal_=false;
  uint64_t serial_=0,frames_=0,stream_=0,frame_=UINT64_MAX,bytes_=0;
  uint64_t frame_limit_=max_frames;
  std::chrono::steady_clock::time_point poll_{};
  void close() {
    if(file_){std::fflush(file_);std::fclose(file_);file_=nullptr;}
    if(mutations_){std::fflush(mutations_);std::fclose(mutations_);mutations_=nullptr;}
    terminal_=true;
  }
  bool raw(Record r) {
    r.serial=++serial_;
    uint8_t encoded[160];size_t size=0;
    auto append=[&](uint64_t value){do{uint8_t b=value&127;value>>=7;encoded[size++]=b|(value?128:0);}while(value);};
    append(r.kind);append(r.serial);append(r.stream);append(r.frame);append(r.chunk);append(r.encoder);
    for(auto value:r.values)append(value);
    if(!file_||std::fwrite(encoded,size,1,file_)!=1){close();return false;}
    bytes_+=size;
    return true;
  }
  void poll() {
    if(file_||terminal_||!configured())return;
    auto now=std::chrono::steady_clock::now();
    if(now-poll_<std::chrono::milliseconds(100))return;
    poll_=now;
    std::string base=std::getenv("BEDROCK_BOUNDARY_CAPTURE");
    if(base.size()>2048){terminal_=true;return;}
    std::string arm=base+".arm";
    FILE *f=std::fopen(arm.c_str(),"rb");if(!f)return;
    char bytes[5]={0};size_t n=std::fread(bytes,1,5,f);std::fclose(f);
    if(n!=4||std::memcmp(bytes,"arm\n",4)||std::remove(arm.c_str())){terminal_=true;return;}
    if(const char *requested=std::getenv("BEDROCK_BOUNDARY_CAPTURE_FRAMES")){
      char *end=nullptr;auto count=std::strtoull(requested,&end,10);
      if(!*requested||*end||count<121||count>max_frames){terminal_=true;return;}
      frame_limit_=count;
    }
#ifdef _WIN32
    int fd=_open(base.c_str(),_O_WRONLY|_O_CREAT|_O_EXCL|_O_BINARY,_S_IREAD|_S_IWRITE);
    if(fd>=0)file_=_fdopen(fd,"wb");
    if(fd>=0&&!file_)_close(fd);
#else
    int fd=::open(base.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
    if(fd>=0)file_=fdopen(fd,"wb");
    if(fd>=0&&!file_)::close(fd);
#endif
    if(!file_){terminal_=true;return;}
    uint64_t header[4]={magic,2,sizeof(Record),frame_limit_};
    if(std::fwrite(header,sizeof(header),1,file_)!=1)close();
  }
public:
  ~Writer(){close();} // An unterminated file is incomplete, never accepted.
  bool active() {
    if(!configured())return false;
    std::lock_guard<std::mutex> lock(mutex_);poll();return file_!=nullptr;
  }
  void reject(uint64_t reason) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(file_)raw({Rejected,0,0,0,0,0,{reason}});
    close();
  }
  void bufferWrite(uint64_t root,uint64_t generation,uint64_t offset,
                   const void *bytes,size_t length) {
    std::lock_guard<std::mutex> lock(mutex_);
    if(!file_)return;
    constexpr uint64_t limit=1536ull*1024*1024; // Disk only; pending copies remain bounded to 64 MiB.
    if(!root||!generation||!bytes||!length||length>32ull*1024*1024||
       offset>UINT64_MAX-length||mutation_bytes_>limit-length||
       serial_>=max_records-1||bytes_>max_encoded_bytes-320){
      raw({Rejected,0,0,0,0,0,{9}});close();return;
    }
    if(!mutations_){
      std::string path=std::string(std::getenv("BEDROCK_BOUNDARY_CAPTURE"))+".mutations";
#ifdef _WIN32
      int fd=_open(path.c_str(),_O_WRONLY|_O_CREAT|_O_EXCL|_O_BINARY,_S_IREAD|_S_IWRITE);
      if(fd>=0)mutations_=_fdopen(fd,"wb");
      if(fd>=0&&!mutations_)_close(fd);
#else
      int fd=::open(path.c_str(),O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600);
      if(fd>=0)mutations_=fdopen(fd,"wb");
      if(fd>=0&&!mutations_)::close(fd);
#endif
    }
    if(!mutations_||std::fwrite(bytes,length,1,mutations_)!=1){
      raw({Rejected,0,0,0,0,0,{10}});close();return;
    }
    const uint64_t position=mutation_bytes_;mutation_bytes_+=length;
    raw({DynamicWrite,0,0,0,0,0,{root,generation,offset,length,position}});
  }
  void emit(Kind kind,uint64_t stream,uint64_t frame,uint64_t chunk,uint64_t encoder,
            std::array<uint64_t,10> values={}) {
    if(!configured())return;
    std::lock_guard<std::mutex> lock(mutex_);poll();if(!file_)return;
    if(serial_>=max_records-1||bytes_>max_encoded_bytes-320){raw({Rejected,0,stream,frame,chunk,encoder,{1}});close();return;}
    if(kind==BeginChunk){
      if(stream_&&stream_!=stream){raw({Rejected,0,stream,frame,chunk,encoder,{2}});close();return;}
      stream_=stream;
      if(frame_!=frame){
        if(frame_!=UINT64_MAX&&frame<=frame_){raw({Rejected,0,stream,frame,chunk,encoder,{3}});close();return;}
        if(frames_==frame_limit_){raw({EndCapture,0,stream,frame,chunk,encoder,{frames_}});close();return;}
        frame_=frame;++frames_;
      }
    }
    raw({kind,0,stream,frame,chunk,encoder,values});
    if(kind==EndChunk&&file_)std::fflush(file_);
  }
};
inline Writer &writer(){static Writer value;return value;}
inline void dynamicMap(uint64_t root,uint64_t generation,uint64_t offset,uint64_t length,uint64_t type) {
  writer().emit(DynamicMap,0,0,0,0,{root,generation,offset,length,type});
}
} // namespace dxmt::boundary_capture
