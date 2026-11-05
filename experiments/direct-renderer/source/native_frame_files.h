#ifndef FULLFRAME_NATIVE_FRAME_FILES_H
#define FULLFRAME_NATIVE_FRAME_FILES_H
#import "native_frame_execute.h"

/* Reads one producer-completed immutable frame publication. Caller retains its
 * root FD; the returned request owns payload directory FDs and imported leases.
 * No directory scan, GPU encoding or original-renderer suppression occurs here. */
FFSTNativeFrameRequest *ffst_frame_request_from_files(int directory, NSString *marker,
    NSString **failure);
#endif
