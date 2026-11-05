/* Private, bounded geometry control record. Shared by ARC presenter and MRC DXMT. */
#ifndef FF_NATIVE_OVERLAY_RECORD_H
#define FF_NATIVE_OVERLAY_RECORD_H
#import <Foundation/Foundation.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <math.h>
#include <string.h>

static inline uint64_t ff_overlay_now_ns(void) {
    struct timespec ts;
    return clock_gettime(CLOCK_MONOTONIC, &ts) ? 0 : (uint64_t)ts.tv_sec * 1000000000ull + ts.tv_nsec;
}
static inline BOOL ff_overlay_nonce_valid(NSString *nonce) {
    if (![nonce isKindOfClass:NSString.class] || nonce.length != 64) return NO;
    return [nonce rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"] invertedSet]].location == NSNotFound;
}
static inline BOOL ff_overlay_private_directory(NSString *path) {
    /* A private parent prevents another user replacing a source-owned record.
     * Reject symlinks in every component instead of trusting path resolution. */
    if (!path.isAbsolutePath || [path.pathComponents containsObject:@".."] ||
        [path.pathComponents containsObject:@"."] || [path containsString:@"//"]) return NO;
    NSString *part = @"/";
    NSArray *parts = path.stringByDeletingLastPathComponent.pathComponents;
    struct stat st;
    for (NSUInteger i = 1; i < parts.count; ++i) {
        part = [part stringByAppendingPathComponent:parts[i]];
        if (lstat(part.fileSystemRepresentation, &st) || !S_ISDIR(st.st_mode) || S_ISLNK(st.st_mode)) return NO;
    }
    return parts.count > 1 && st.st_uid == getuid() && (st.st_mode & 0777) == 0700;
}
static inline BOOL ff_overlay_integer(id value, uint64_t minimum, uint64_t maximum) {
    if (![value isKindOfClass:NSNumber.class]) return NO;
    double d = [value doubleValue];
    return isfinite(d) && d >= minimum && d <= maximum && floor(d) == d;
}
/* nil means absent, unsafe or malformed; never read more than 4096 bytes. */
static inline NSDictionary *ff_overlay_read_record(NSString *path, NSString *nonce) {
    if (!ff_overlay_nonce_valid(nonce) || !ff_overlay_private_directory(path)) return nil;
    int fd = open(path.fileSystemRepresentation, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    if (fd < 0) return nil;
    struct stat st = {0};
    BOOL valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == getuid() &&
        (st.st_mode & 0777) == 0600 && st.st_nlink == 1 && st.st_size > 0 && st.st_size <= 4096;
    char bytes[4097]; ssize_t count = valid ? read(fd, bytes, sizeof(bytes)) : -1;
    close(fd);
    if (count != st.st_size || !valid) return nil;
    id object = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:(NSUInteger)count] options:0 error:NULL];
    if (![object isKindOfClass:NSDictionary.class]) return nil;
    NSDictionary *r = object;
    if (!ff_overlay_integer(r[@"version"], 1, 1) || ![r[@"nonce"] isEqual:nonce] ||
        !ff_overlay_integer(r[@"owner_pid"], 1, INT32_MAX) ||
        ![r[@"bundle_id"] isKindOfClass:NSString.class] || ![r[@"bundle_id"] length] ||
        [r[@"bundle_id"] length] > 255 || !ff_overlay_integer(r[@"window_number"], 0, INT32_MAX)) return nil;
    return r;
}
static inline BOOL ff_overlay_geometry_valid(NSDictionary *r, uint64_t now) {
    if (!ff_overlay_integer(r[@"source_pid"], 1, INT32_MAX) || ![r[@"source_pid"] isEqual:r[@"owner_pid"]] ||
        !ff_overlay_integer(r[@"window_number"], 1, INT32_MAX) ||
        !ff_overlay_integer(r[@"monotonic_ns"], 1, INT64_MAX) ||
        !ff_overlay_integer(r[@"window_level"], 0, INT32_MAX - 2)) return NO;
    uint64_t time = [r[@"monotonic_ns"] unsignedLongLongValue];
    if (time > now || now - time >= 500000000ull) return NO;
    for (NSString *key in @[@"x", @"y", @"width", @"height", @"scale"]) {
        id value = r[key]; if (![value isKindOfClass:NSNumber.class] || !isfinite([value doubleValue])) return NO;
    }
    double x = [r[@"x"] doubleValue], y = [r[@"y"] doubleValue];
    double width = [r[@"width"] doubleValue], height = [r[@"height"] doubleValue], scale = [r[@"scale"] doubleValue];
    if (fabs(x) > 131072 || fabs(y) > 131072 || width < 1 || height < 1 || width > 16384 || height > 16384 || scale < 1 || scale > 4) return NO;
    for (NSString *key in @[@"active", @"visible", @"miniaturized"])
        if (!ff_overlay_integer(r[key], 0, 1)) return NO;
    return [r[@"active"] boolValue] && [r[@"visible"] boolValue] && ![r[@"miniaturized"] boolValue];
}
#endif
