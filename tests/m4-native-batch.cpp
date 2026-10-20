// Standalone synthetic architecture experiment. No game code or runtime hooks.
// Input extraction, updates, draw submission and GPU execution are not measured.
#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <semaphore.h>
#include <spawn.h>
#include <string>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

extern char **environ;
constexpr uint32_t Capacity = 65536;
constexpr uint64_t Magic = 0x4d34424154434831ULL;
struct Box { float lo[3], hi[3]; };
struct Plane { float v[4]; };
struct alignas(128) Request {
  uint64_t magic;
  uint64_t sequence;
  uint32_t count;
  uint32_t stop;
  Plane planes[6];
};
struct alignas(128) Reply {
  uint64_t sequence;
  uint64_t total_kernel_ns;
  int32_t translated;
  uint32_t error;
};
struct Shared {
  Request request;
  Reply reply;
  alignas(128) Box boxes[Capacity];
  alignas(128) uint8_t output[Capacity];
};
static_assert(sizeof(Request) == 128 && sizeof(Reply) == 128);
static_assert(offsetof(Shared, boxes) == 256);

static uint64_t now_ns() {
  return std::chrono::duration_cast<std::chrono::nanoseconds>(
    std::chrono::steady_clock::now().time_since_epoch()).count();
}
static int translated() {
  int n = 0; size_t len = sizeof(n);
  if (sysctlbyname("sysctl.proc_translated", &n, &len, nullptr, 0) != 0 && errno != ENOENT)
    return -1;
  return n;
}
static void fail(const char *s) { perror(s); exit(1); }
static void checked_wait(sem_t *s) {
  while (sem_wait(s)) if (errno != EINTR) fail("sem_wait");
}
static void post(sem_t *s) { if (sem_post(s)) fail("sem_post"); }

// Identical source for both architectures, strict float operations, no fast math.
// Invalid AABBs/planes remain visible: this prototype never hides malformed data.
__attribute__((noinline)) static void cull(const Box *boxes, uint32_t count,
                                          const Plane *planes, uint8_t *out) {
  bool valid_planes = true;
  for (unsigned p=0; p<6; ++p) for (unsigned k=0; k<4; ++k)
    valid_planes &= std::isfinite(planes[p].v[k]);
  for (uint32_t i=0; i<count; ++i) {
    const Box &b=boxes[i]; bool valid=valid_planes, visible=true;
    for (unsigned k=0; k<3; ++k)
      valid &= std::isfinite(b.lo[k]) && std::isfinite(b.hi[k]) && b.lo[k]<=b.hi[k];
    if (valid) for (unsigned p=0; p<6; ++p) {
      const float *v=planes[p].v;
      float d=v[0]*(v[0]>=0 ? b.hi[0] : b.lo[0]);
      d=d+v[1]*(v[1]>=0 ? b.hi[1] : b.lo[1]);
      d=d+v[2]*(v[2]>=0 ? b.hi[2] : b.lo[2]);
      d=d+v[3];
      if (d<0) { visible=false; break; }
    }
    out[i]=visible;
  }
}

static int helper(const char *path, const char *req_name, const char *done_name) {
  alarm(120); // Bound an orphaned helper if its client unexpectedly exits.
  int fd=open(path,O_RDWR); if(fd<0) fail("open");
  struct stat st{}; if(fstat(fd,&st) || st.st_size!=sizeof(Shared)) return 2;
  auto *s=static_cast<Shared*>(mmap(nullptr,sizeof(Shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
  close(fd); if(s==MAP_FAILED) fail("mmap");
  sem_t *req=sem_open(req_name,0), *done=sem_open(done_name,0);
  if(req==SEM_FAILED || done==SEM_FAILED) fail("sem_open");
  s->reply.translated=translated(); post(done);
  for (;;) {
    checked_wait(req);
    if(s->request.magic!=Magic || s->request.count>Capacity) { s->reply.error=1; post(done); break; }
    if(s->request.stop) break;
    const auto start=now_ns();
    cull(s->boxes,s->request.count,s->request.planes,s->output);
    s->reply.total_kernel_ns+=now_ns()-start;
    s->reply.sequence=s->request.sequence;
    post(done);
  }
  sem_close(req); sem_close(done); munmap(s,sizeof(Shared)); return 0;
}

struct Session {
  std::string path, req_name, done_name;
  Shared *s=nullptr;
  sem_t *req=SEM_FAILED,*done=SEM_FAILED;
  pid_t child=-1;
  explicit Session(const char *executable) {
    const char *ipc=getenv("BEDROCK_M4_IPC_FILE"), *id=getenv("BEDROCK_M4_SESSION");
    if(!ipc || !id || strlen(id)!=16) { fprintf(stderr,"Use run-m4-native-batch.py\n"); exit(2); }
    path=ipc;
    int fd=open(path.c_str(),O_RDWR|O_CREAT|O_EXCL,0600); if(fd<0) fail("open exclusive");
    if(ftruncate(fd,sizeof(Shared))) fail("ftruncate");
    s=static_cast<Shared*>(mmap(nullptr,sizeof(Shared),PROT_READ|PROT_WRITE,MAP_SHARED,fd,0));
    close(fd); if(s==MAP_FAILED) fail("mmap");
    memset(s,0,sizeof(*s)); s->request.magic=Magic;
    req_name="/b4r"+std::string(id); done_name="/b4d"+std::string(id);
    req=sem_open(req_name.c_str(),O_CREAT|O_EXCL,0600,0);
    done=sem_open(done_name.c_str(),O_CREAT|O_EXCL,0600,0);
    if(req==SEM_FAILED || done==SEM_FAILED) fail("sem_open exclusive");
    char *args[]={const_cast<char*>(executable),const_cast<char*>("--helper"),
      path.data(),req_name.data(),done_name.data(),nullptr};
    int rc=posix_spawn(&child,executable,nullptr,nullptr,args,environ);
    if(rc) { errno=rc; fail("spawn"); }
    checked_wait(done);
    // Both mappings and semaphore handles now exist. Remove filesystem names
    // immediately so an unexpected client/helper exit cannot leave stale names.
    unlink(path.c_str()); sem_unlink(req_name.c_str()); sem_unlink(done_name.c_str());
    if(translated()!=1 || s->reply.translated!=0) {
      fprintf(stderr,"Expected Rosetta client and native helper, got %d/%d\n",translated(),s->reply.translated);
      exit(3);
    }
  }
  void run(uint32_t n) {
    s->request.count=n; ++s->request.sequence; post(req); checked_wait(done);
    if(s->reply.error || s->reply.sequence!=s->request.sequence) {
      fprintf(stderr,"Invalid helper reply\n"); exit(4);
    }
  }
  ~Session() {
    s->request.stop=1; post(req); int status; waitpid(child,&status,0);
    sem_close(req); sem_close(done); sem_unlink(req_name.c_str()); sem_unlink(done_name.c_str());
    munmap(s,sizeof(Shared)); unlink(path.c_str());
  }
};
static void init(Shared *s) {
  uint32_t rng=981724;
  auto random=[&](){ rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; };
  for(uint32_t i=0;i<Capacity;++i) for(unsigned k=0;k<3;++k) {
    s->boxes[i].lo[k]=float(int(random()%8192)-4096)/32;
    s->boxes[i].hi[k]=s->boxes[i].lo[k]+float(1+random()%256)/32;
  }
  const Plane planes[6]={{{1,0,0,80}},{{-1,0,0,80}},{{0,1,0,60}},
    {{0,-1,0,60}},{{0,0,1,100}},{{0,0,-1,100}}};
  memcpy(s->request.planes,planes,sizeof(planes));
  s->boxes[0]={{-80,-60,-100},{-80,-60,-100}};
  s->boxes[1]={{NAN,0,0},{0,0,0}};
  s->boxes[2]={{1,1,1},{-1,-1,-1}};
  s->boxes[3]={{INFINITY,0,0},{INFINITY,0,0}};
  s->boxes[4]={{0,0,0},{1,1,1}};
  s->boxes[5]={{81,0,0},{82,1,1}};
  s->boxes[6]={{80,0,0},{80,0,0}};
}
static bool verify(Session &session) {
  Shared *s=session.s; std::vector<uint8_t> reference(Capacity);
  for(unsigned fixture=0; fixture<64; ++fixture) {
    s->request.planes[0].v[3]=80.0f+float(fixture)/32;
    if(fixture==63) s->request.planes[0].v[0]=NAN;
    cull(s->boxes,Capacity,s->request.planes,reference.data());
    session.run(Capacity);
    if(memcmp(reference.data(),s->output,Capacity)) return false;
    if(!s->output[0] || !s->output[1] || !s->output[2] || !s->output[3]) return false;
    if(!s->output[4] || !s->output[6] || (fixture!=63 && s->output[5])) return false;
    if(fixture!=63 && std::count(reference.begin(),reference.end(),1)==Capacity) return false;
    if(fixture==63 && std::count(reference.begin(),reference.end(),1)!=Capacity) return false;
  }
  init(s); return true;
}
static volatile uint64_t checksum=0;
int main(int argc,char **argv) {
  if(argc==5 && !strcmp(argv[1],"--helper")) return helper(argv[2],argv[3],argv[4]);
  if(argc<2) { fprintf(stderr,"usage: probe-x64 /absolute/probe-arm64 [--verify-only]\n"); return 1; }
  alarm(120);
  Session session(argv[1]); init(session.s);
  if(!verify(session)) { fprintf(stderr,"Cross-architecture correctness failed\n"); return 5; }
  printf("{\"kind\":\"verification\",\"client_translated\":%d,\"helper_translated\":%d,\"fixtures\":64,\"boxes_per_fixture\":65536,\"match\":true}\n",translated(),session.s->reply.translated); fflush(stdout);
  if(argc==3 && !strcmp(argv[2],"--verify-only")) return 0;
  const char *enabled=getenv("BEDROCK_M4_TIMING");
  if(!enabled || strcmp(enabled,"1")) {
    fprintf(stderr,"Use the runner to check for a competing game before timing.\n"); return 2;
  }
  const unsigned sizes[]={0,64,256,1024,4096,16384,65536};
  for(unsigned n:sizes) {
    unsigned iterations=n ? std::clamp(2097152/n,64u,2000u) : 2000;
    for(unsigned warm=0;warm<128;++warm) {
      cull(session.s->boxes,n,session.s->request.planes,session.s->output); session.run(n);
    }
    for(unsigned trial=0;trial<11;++trial) {
      double local_ns=0,remote_ns=0,kernel_ns=0;
      for(unsigned half=0;half<2;++half) {
        bool remote=((trial+half)%2)==1;
        const auto previous_kernel=session.s->reply.total_kernel_ns, start=now_ns();
        for(unsigned i=0;i<iterations;++i) {
          if(remote) session.run(n);
          else cull(session.s->boxes,n,session.s->request.planes,session.s->output);
        }
        double elapsed=double(now_ns()-start)/iterations;
        if(remote) { remote_ns=elapsed; kernel_ns=double(session.s->reply.total_kernel_ns-previous_kernel)/iterations; }
        else local_ns=elapsed;
        for(unsigned i=0;i<n;++i) checksum+=session.s->output[i];
      }
      printf("{\"kind\":\"trial\",\"boxes\":%u,\"trial\":%u,\"iterations\":%u,\"rosetta_ns\":%.3f,\"arm64_with_ipc_ns\":%.3f,\"arm64_kernel_ns\":%.3f}\n",n,trial,iterations,local_ns,remote_ns,kernel_ns); fflush(stdout);
    }
  }
  return 0;
}
