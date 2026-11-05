#include "frame_stream.h"
#include <inttypes.h>
#include <stdio.h>

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr,"usage: frame-stream-inspect capture.ffs\n"); return 2; }
  FILE *file = fopen(argv[1],"rb");
  if (!file) { perror("capture"); return 2; }
  ffs_record record;
  ffs_collector *c = NULL;
  int truncated = 0;
  for (;;) {
    size_t n = fread(&record,1,sizeof(record),file);
    if (!n) break;
    if (n != sizeof(record)) { truncated = 1; break; }
    if (!c) c = ffs_create(record.stream,1,FFS_MAX_RECORDS);
    if (!c || !ffs_consume(c,&record)) break;
  }
  if (ferror(file)) truncated = 1;
  fclose(file);
  ffs_summary s = ffs_inspect(c);
  if (truncated) s.status = FFS_INVALID;
  printf("{\"status\":\"%s\",\"error\":%u,\"frame\":%" PRIu64 ",\"chunks\":%" PRIu64
      ",\"encoders\":%" PRIu64 ",\"commands\":%" PRIu64 ",\"resources\":%" PRIu64
      ",\"dependencies\":%" PRIu64 ",\"presents\":%" PRIu64 ",\"replay_eligible\":false}\n",
      ffs_status_name(s.status),(unsigned)s.error,s.frame,s.chunks,s.encoders,s.commands,s.resources,s.dependencies,s.presents);
  ffs_destroy(c);
  return s.status == FFS_COMPLETE || s.status == FFS_UNSUPPORTED_FRAME ? 0 : 1;
}
