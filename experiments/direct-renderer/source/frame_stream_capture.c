/* Optional Unix bridge receiver. Link with frame_stream.c; never linked into
 * the frozen CUT03 candidate unless the caller explicitly selects this path. */
#include "frame_stream.h"
#include <errno.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <inttypes.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static pthread_mutex_t capture_mutex = PTHREAD_MUTEX_INITIALIZER;
static ffs_collector *capture;
static int capture_fd = -1, directory_fd = -1;
static char partial_name[128];
static void (*event_observer)(const ffs_record *);
static int observer_checked;
typedef uint32_t (*chunk_receiver)(const ffs_record *, uint64_t);
static chunk_receiver chunk_record_receiver;
static pthread_once_t chunk_receiver_once = PTHREAD_ONCE_INIT;

static void resolve_chunk_receiver(void) {
  /* The paired receiver belongs to this bridge image and shares its lifetime. */
  chunk_record_receiver = (chunk_receiver)dlsym(RTLD_DEFAULT, "fullframe_chunk_stream_record");
}

static int claim_arm(void) {
  int fd = openat(directory_fd,"frame.arm",O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
  if (fd < 0) return 0;
  struct stat opened, current;
  char bytes[5] = {0};
  int valid = !fstat(fd,&opened) && S_ISREG(opened.st_mode) && opened.st_uid == getuid() &&
      !(opened.st_mode & 077) && opened.st_nlink == 1 && opened.st_size == 4;
  if (valid) {
    ssize_t n;
    do { n = read(fd,bytes,sizeof(bytes)); } while (n < 0 && errno == EINTR);
    valid = n == 4 && !memcmp(bytes,"arm\n",4) &&
        !fstatat(directory_fd,"frame.arm",&current,AT_SYMLINK_NOFOLLOW) &&
        current.st_dev == opened.st_dev && current.st_ino == opened.st_ino && current.st_nlink == 1;
  }
  close(fd);
  return valid && !unlinkat(directory_fd,"frame.arm",0) && !fsync(directory_fd);
}

static void close_capture(void) {
  if (capture_fd >= 0) { close(capture_fd); capture_fd = -1; }
  if (directory_fd >= 0) { close(directory_fd); directory_fd = -1; }
  ffs_destroy(capture); capture = NULL;
}

static int start_capture(const ffs_record *r) {
  const char *path = getenv("BEDROCK_FULLFRAME_FRAME_STREAM_DIRECTORY");
  if (!path || path[0] != '/' || r->kind != FFS_FRAME_BEGIN || r->sequence != 1) return 0;
  directory_fd = open(path,O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
  struct stat s;
  if (directory_fd < 0 || fstat(directory_fd,&s) || s.st_uid != getuid() || (s.st_mode & 077)) {
    close_capture(); return 0;
  }
  /* The launcher's atomic hardlink publication can briefly have nlink2. Treat
   * that as unarmed and retry only at the next frame's first chunk. */
  if (!claim_arm()) { close_capture(); return 0; }
  snprintf(partial_name,sizeof(partial_name),"frame-%" PRIu64 "-%" PRIu64 ".partial",r->stream,r->frame);
  capture_fd = openat(directory_fd,partial_name,O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0600);
  capture = ffs_create(r->stream,1,FFS_MAX_RECORDS);
  if (capture_fd < 0 || !capture) { close_capture(); return 0; }
  return 1;
}

/* Called synchronously through paired Winemetal Unixcall132. The packet is
 * copied before returning; producer-local pointers are absent from the ABI. */
__attribute__((visibility("default"))) uint32_t
fullframe_frame_stream_record(const ffs_record *record, uint64_t bytes) {
  if (!record || bytes != sizeof(*record)) return FFS_EMIT_REJECT;
  const char *chunk_path=getenv("BEDROCK_FULLFRAME_CHUNK_STREAM");
  if(chunk_path&&chunk_path[0]=='/'){
    pthread_once(&chunk_receiver_once, resolve_chunk_receiver);
    return chunk_record_receiver?chunk_record_receiver(record,bytes):FFS_EMIT_REJECT;
  }
  pthread_mutex_lock(&capture_mutex);
  int ok = FFS_EMIT_REJECT;
  if (!capture && !start_capture(record)) { ok = FFS_EMIT_IDLE; goto done; }
  ffs_summary before = ffs_inspect(capture);
  if (before.stream != record->stream || before.records == FFS_MAX_RECORDS) goto done;
  ffs_record copy = *record;
  const unsigned char *p = (const unsigned char *)&copy;
  size_t remaining = sizeof(copy);
  while (remaining) {
    ssize_t written = write(capture_fd,p,remaining);
    if (written < 0 && errno == EINTR) continue;
    if (written <= 0) goto failed;
    remaining -= (size_t)written; p += written;
  }
  if (!ffs_consume(capture,&copy)) goto failed;
  if (!observer_checked) { event_observer=dlsym(RTLD_DEFAULT,"fullframe_frame_stream_event"); observer_checked=1; }
  if (event_observer && copy.kind != FFS_FRAME_END) event_observer(&copy);
  ok = FFS_EMIT_ACCEPT;
  if (copy.kind == FFS_FRAME_END) {
    ffs_summary s = ffs_inspect(capture);
    char final_name[128];
    snprintf(final_name,sizeof(final_name),"frame-%" PRIu64 "-%" PRIu64 ".%s.ffs",s.stream,s.frame,ffs_status_name(s.status));
    if (fsync(capture_fd) || linkat(directory_fd,partial_name,directory_fd,final_name,0) ||
        unlinkat(directory_fd,partial_name,0) || fsync(directory_fd)) ok = FFS_EMIT_REJECT;
    if (ok == FFS_EMIT_ACCEPT && event_observer) event_observer(&copy);
    fprintf(stderr,"[full-frame-stream] status=%s chunks=%" PRIu64 " encoders=%" PRIu64 " commands=%" PRIu64 " resources=%" PRIu64 "\n",
        ffs_status_name(s.status),s.chunks,s.encoders,s.commands,s.resources);
    close_capture();
  }
  goto done;
failed:
  /* Keep the partial ledger as explicit evidence. No final marker is created. */
  close_capture();
  ok = FFS_EMIT_REJECT;
done:
  pthread_mutex_unlock(&capture_mutex); return (uint32_t)ok;
}

__attribute__((destructor)) static void capture_cleanup(void) {
  pthread_mutex_lock(&capture_mutex); close_capture(); pthread_mutex_unlock(&capture_mutex);
}
