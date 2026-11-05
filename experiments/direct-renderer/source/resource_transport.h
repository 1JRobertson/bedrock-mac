/* Bounded, single-flight buffer-snapshot transport for an owned local socket.
 * This is an experimental protocol, not a Metal resource implementation. */
#ifndef FULLFRAME_RESOURCE_TRANSPORT_H
#define FULLFRAME_RESOURCE_TRANSPORT_H
#include <stddef.h>
#include <stdint.h>

#define FF_RESOURCE_MAX_BYTES (8u * 1024u * 1024u)

typedef struct {
    int fd;
    uint64_t next_sequence;
    uint64_t pending_sequence, pending_resource, pending_generation;
} ff_resource_channel;

typedef struct {
    uint64_t resource, generation, sequence;
    size_t length;
    void *bytes; /* owned by caller until ff_resource_ack; NULL for retirement */
    int retire;
} ff_resource_message;

/* fd must be a private, connected stream socket. Caller owns and closes it.
 * A channel with any failed operation must be closed, not reused. */
int ff_resource_init(ff_resource_channel *channel, int fd);
/* Exactly one in-flight message. The producer must freeze the bytes first;
 * resource IDs are never reused within the connection, generations increase. */
int ff_resource_publish(ff_resource_channel *channel, uint64_t resource,
                        uint64_t generation, const void *bytes, size_t length);
int ff_resource_retire(ff_resource_channel *channel, uint64_t resource,
                       uint64_t generation);
/* Blocks until the matching acknowledgement; permits the next message. */
int ff_resource_wait_ack(ff_resource_channel *channel);
/* Allocates an independent snapshot. Validates framing and strict order. */
int ff_resource_receive(ff_resource_channel *channel, ff_resource_message *message);
/* Call only after all consumer CPU/GPU uses complete. Frees message bytes. */
int ff_resource_ack(ff_resource_channel *channel, ff_resource_message *message);
/* For failure cleanup without acknowledging. */
void ff_resource_discard(ff_resource_message *message);
#endif
