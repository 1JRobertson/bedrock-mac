#ifndef BEDROCK_NATIVE_CHUNK_WORKER_H
#define BEDROCK_NATIVE_CHUNK_WORKER_H
/* Main-thread event pump; endpoint and diagnostic directory belong to the
 * isolated launcher. GPU execution and transport access run off AppKit. */
int ffst_native_chunk_worker(int directory,const char *endpoint,long timeout,int present);
int ffst_native_chunk_initialize(const char *endpoint);
#endif
