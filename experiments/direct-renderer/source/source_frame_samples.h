/* Optional bounded source-frame observations. The caller serializes all access. */
#ifndef BEDROCK_SOURCE_FRAME_SAMPLES_H
#define BEDROCK_SOURCE_FRAME_SAMPLES_H
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define FF_SOURCE_FRAME_SAMPLE_CAPACITY 16384u

typedef struct {
    uint64_t stream, frame, first_chunk, begin_monotonic_ns;
} ff_source_frame_sample;
typedef struct {
    ff_source_frame_sample *samples;
    size_t count, head;
    uint64_t total, overflow, missing_timestamps, invalid_identity, counter_overflow;
    char run_id[33];
    int directory_fd;
} ff_source_frame_samples;

/* The launcher creates the private directory. Never replace an existing file. */
static inline int ff_source_frame_samples_open(ff_source_frame_samples *s, const char *directory, const char *run_id) {
    s->directory_fd = -1;
    if (!directory || directory[0] != '/' || !run_id || strnlen(run_id, 33) != 32) return 0;
    for (size_t i = 0; i < 32; ++i)
        if (!((run_id[i] >= '0' && run_id[i] <= '9') || (run_id[i] >= 'a' && run_id[i] <= 'f'))) return 0;
    int fd = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat st;
    if (fd < 0) return 0;
    if (fstat(fd, &st) || !S_ISDIR(st.st_mode) || st.st_uid != getuid() || (st.st_mode & 077)) {
        close(fd); return 0;
    }
    ff_source_frame_sample *samples = calloc(FF_SOURCE_FRAME_SAMPLE_CAPACITY, sizeof(*samples));
    if (!samples) { close(fd); return 0; }
    memcpy(s->run_id, run_id, sizeof(s->run_id));
    s->samples = samples; s->directory_fd = fd; return 1;
}

static inline void ff_source_frame_counter_increment(uint64_t *value, uint64_t *overflow) {
    if (*value < UINT64_MAX) ++*value;
    else *overflow = 1;
}

static inline void ff_source_frame_samples_record(ff_source_frame_samples *s,
    uint64_t stream, uint64_t frame, uint64_t first_chunk, uint64_t begin_ns) {
    if (!s->samples) return;
    ff_source_frame_counter_increment(&s->total, &s->counter_overflow);
    /* Chunk zero is not forbidden by the wire protocol. */
    if (!stream || !frame) {
        ff_source_frame_counter_increment(&s->invalid_identity, &s->counter_overflow); return;
    }
    if (!begin_ns) {
        ff_source_frame_counter_increment(&s->missing_timestamps, &s->counter_overflow); return;
    }
    size_t index;
    if (s->count < FF_SOURCE_FRAME_SAMPLE_CAPACITY) {
        index = (s->head + s->count++) % FF_SOURCE_FRAME_SAMPLE_CAPACITY;
    } else {
        index = s->head; s->head = (s->head + 1) % FF_SOURCE_FRAME_SAMPLE_CAPACITY;
        ff_source_frame_counter_increment(&s->overflow, &s->counter_overflow);
    }
    s->samples[index] = (ff_source_frame_sample){stream, frame, first_chunk, begin_ns};
}

/* Call only after observations have stopped. Abrupt exits or write failures
 * leave no completed receipt. Check process status separately; a normal exit
 * after a renderer error may still produce a receipt. */
static inline int ff_source_frame_samples_write(ff_source_frame_samples *s) {
    static const char temporary[] = ".source-frame-samples.tmp";
    static const char final[] = "source-frame-samples.json";
    if (!s->samples || s->directory_fd < 0) return 0;
    int fd = openat(s->directory_fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return 0;
    FILE *out = fdopen(fd, "w");
    if (!out) { close(fd); unlinkat(s->directory_fd, temporary, 0); return 0; }
    (void)setvbuf(out, NULL, _IOFBF, 65536);
    int ok = fprintf(out, "{\"format\":\"bedrock-native-source-frame-samples\",\"version\":1,"
        "\"clock\":\"CLOCK_MONOTONIC nanoseconds\",\"run_id\":\"%s\",\"sample_window\":\"tail\","
        "\"capacity\":%u,\"total\":%" PRIu64 ",\"overflow\":%" PRIu64 ","
        "\"missing_timestamps\":%" PRIu64 ",\"invalid_identity\":%" PRIu64 ","
        "\"counter_overflow\":%" PRIu64 ",\"samples\":[",
        s->run_id, FF_SOURCE_FRAME_SAMPLE_CAPACITY, s->total, s->overflow, s->missing_timestamps,
        s->invalid_identity, s->counter_overflow) >= 0;
    for (size_t i = 0; ok && i < s->count; ++i) {
        ff_source_frame_sample x = s->samples[(s->head + i) % FF_SOURCE_FRAME_SAMPLE_CAPACITY];
        ok = fprintf(out, "%s{\"stream\":%" PRIu64 ",\"frame\":%" PRIu64 ","
            "\"first_chunk\":%" PRIu64 ",\"begin_monotonic_ns\":%" PRIu64 "}",
            i ? "," : "", x.stream, x.frame, x.first_chunk, x.begin_monotonic_ns) >= 0;
    }
    if (ok) ok = fprintf(out, "]}\n") >= 0;
    if (ferror(out)) ok = 0;
    if (fclose(out)) ok = 0;
    if (ok && linkat(s->directory_fd, temporary, s->directory_fd, final, 0)) ok = 0;
    unlinkat(s->directory_fd, temporary, 0);
    return ok;
}

static inline void ff_source_frame_samples_close(ff_source_frame_samples *s) {
    if (s->directory_fd >= 0) close(s->directory_fd);
    s->directory_fd = -1; free(s->samples); s->samples = NULL;
}
#endif
