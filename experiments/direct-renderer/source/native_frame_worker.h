#ifndef FULLFRAME_NATIVE_FRAME_WORKER_H
#define FULLFRAME_NATIVE_FRAME_WORKER_H
/* Main-thread event loop. Directory remains owned by the caller. */
int ffst_native_frame_worker(int directory, long timeout, int present);
#endif
