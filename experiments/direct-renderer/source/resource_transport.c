#include "resource_transport.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <poll.h>
#include <time.h>

/* Fixed wire header: magic, version, kind, sequence, id, generation, length.
 * Integers are big endian; no pointers or host structs cross the socket. */
enum { HEADER_SIZE = 40, PUBLISH = 1, RETIRE = 2, ACK = 3 };

static void put64(unsigned char *p, uint64_t v) {
    for (int i = 7; i >= 0; --i) { p[i] = (unsigned char)v; v >>= 8; }
}
static uint64_t get64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
    return v;
}
static void header(unsigned char *p, unsigned kind, uint64_t seq,
                   uint64_t id, uint64_t generation, uint64_t length) {
    memset(p, 0, HEADER_SIZE);
    memcpy(p, "FFRT", 4); p[4] = 1; p[5] = (unsigned char)kind;
    put64(p + 8, seq); put64(p + 16, id); put64(p + 24, generation);
    put64(p + 32, length);
}
static int valid(const unsigned char *p) {
    return !memcmp(p, "FFRT", 4) && p[4] == 1 && !p[6] && !p[7];
}
static int transfer(int fd, void *buffer, size_t length, int writing) {
    unsigned char *p = buffer;
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
    int64_t deadline = (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000 + 10000;
    while (length) {
        if (clock_gettime(CLOCK_MONOTONIC, &now)) return -1;
        int64_t remaining = deadline - ((int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000);
        if (remaining <= 0) return -1;
        struct pollfd pollfd = {fd, writing ? POLLOUT : POLLIN, 0};
        int ready = poll(&pollfd, 1, (int)remaining);
        if (ready < 0 && errno == EINTR) continue;
        if (ready <= 0) return -1;
        ssize_t n;
        if (writing) {
#ifdef MSG_NOSIGNAL
            n = send(fd, p, length, MSG_NOSIGNAL | MSG_DONTWAIT);
#else
            n = send(fd, p, length, MSG_DONTWAIT);
#endif
        } else n = recv(fd, p, length, MSG_DONTWAIT);
        if (n < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
        if (n <= 0) return -1;
        p += n; length -= (size_t)n;
    }
    return 0;
}
int ff_resource_init(ff_resource_channel *c, int fd) {
    if (!c || fd < 0) return -1;
#ifdef SO_NOSIGPIPE
    int one = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one))) return -1;
#endif
    memset(c, 0, sizeof(*c)); c->fd = fd; c->next_sequence = 1;
    return 0;
}
static int send_message(ff_resource_channel *c, unsigned kind, uint64_t id,
                        uint64_t generation, const void *bytes, size_t length) {
    unsigned char h[HEADER_SIZE];
    if (!c || c->pending_sequence || !c->next_sequence || !id || !generation ||
        length > FF_RESOURCE_MAX_BYTES || (kind == PUBLISH && (!length || !bytes))) return -1;
    header(h, kind, c->next_sequence, id, generation, length);
    c->pending_sequence = c->next_sequence; c->pending_resource = id;
    c->pending_generation = generation;
    if (transfer(c->fd, h, sizeof(h), 1) ||
        (length && transfer(c->fd, (void *)bytes, length, 1))) return -1;
    return 0;
}
int ff_resource_publish(ff_resource_channel *c, uint64_t id, uint64_t generation,
                        const void *bytes, size_t length) {
    return send_message(c, PUBLISH, id, generation, bytes, length);
}
int ff_resource_retire(ff_resource_channel *c, uint64_t id, uint64_t generation) {
    return send_message(c, RETIRE, id, generation, NULL, 0);
}
int ff_resource_wait_ack(ff_resource_channel *c) {
    unsigned char h[HEADER_SIZE];
    if (!c || !c->pending_sequence || transfer(c->fd, h, sizeof(h), 0)) return -1;
    if (!valid(h) || h[5] != ACK || get64(h+8) != c->pending_sequence ||
        get64(h+16) != c->pending_resource || get64(h+24) != c->pending_generation ||
        get64(h+32)) return -1;
    c->pending_sequence = 0; ++c->next_sequence;
    return 0;
}
int ff_resource_receive(ff_resource_channel *c, ff_resource_message *m) {
    unsigned char h[HEADER_SIZE]; uint64_t length;
    if (!c || !m || c->pending_sequence || !c->next_sequence) return -1;
    memset(m, 0, sizeof(*m));
    if (transfer(c->fd, h, sizeof(h), 0) || !valid(h)) return -1;
    length = get64(h+32);
    if ((h[5] != PUBLISH && h[5] != RETIRE) || get64(h+8) != c->next_sequence ||
        !get64(h+16) || !get64(h+24) || length > FF_RESOURCE_MAX_BYTES ||
        (h[5] == PUBLISH && !length) || (h[5] == RETIRE && length)) return -1;
    m->sequence = get64(h+8); m->resource = get64(h+16);
    m->generation = get64(h+24); m->length = (size_t)length; m->retire = h[5] == RETIRE;
    if (length) {
        m->bytes = malloc((size_t)length);
        if (!m->bytes || transfer(c->fd, m->bytes, m->length, 0)) {
            ff_resource_discard(m); return -1;
        }
    }
    c->pending_sequence = m->sequence; c->pending_resource = m->resource;
    c->pending_generation = m->generation;
    return 0;
}
int ff_resource_ack(ff_resource_channel *c, ff_resource_message *m) {
    unsigned char h[HEADER_SIZE];
    if (!c || !m || !c->pending_sequence || m->sequence != c->pending_sequence ||
        m->resource != c->pending_resource || m->generation != c->pending_generation) return -1;
    header(h, ACK, m->sequence, m->resource, m->generation, 0);
    if (transfer(c->fd, h, sizeof(h), 1)) return -1;
    ff_resource_discard(m); c->pending_sequence = 0; ++c->next_sequence;
    return 0;
}
void ff_resource_discard(ff_resource_message *m) {
    if (m) { free(m->bytes); memset(m, 0, sizeof(*m)); }
}
