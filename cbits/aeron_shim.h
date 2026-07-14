#ifndef AERON_HASKELL_SHIM_H
#define AERON_HASKELL_SHIM_H

#include <aeron/aeronc.h>
#include <stddef.h>
#include <stdint.h>

/*
 * Batched fragment collection.
 *
 * aeron_subscription_poll() invokes a handler once per fragment. If that handler
 * is a Haskell closure, the poll must be imported `safe` -- GHC forbids an
 * `unsafe` foreign call from calling back into Haskell -- and every fragment
 * additionally pays a C -> Haskell trampoline.
 *
 * These functions are the handler instead. They call no Haskell at all: they
 * record a (pointer, length, header) descriptor per fragment into a
 * caller-owned array. That makes the poll import legal as `unsafe`, and lets
 * Haskell walk the descriptors afterwards as ordinary Haskell code.
 *
 * The payload is never copied. Only the descriptors are written down, and they
 * point into Aeron's mapped log buffer -- so they are valid only until the next
 * poll on the same subscription.
 */

typedef struct
{
    const uint8_t *data;
    size_t length;
    aeron_header_t *header;
}
ah_fragment_t;

typedef struct
{
    ah_fragment_t *fragments; /* caller-owned, `capacity` entries */
    size_t capacity;
    size_t count;             /* set by the poll functions below */
}
ah_batch_t;

/* The fragment handler. `clientd` must be an ah_batch_t*. */
void ah_collect_fragment(
    void *clientd, const uint8_t *buffer, size_t length, aeron_header_t *header);

/*
 * Poll, collecting up to `limit` fragments into `batch`.
 *
 * `limit` is clamped to the batch capacity, so a fragment can never be dropped
 * on the floor by overflowing the array.
 *
 * Returns the number of fragments collected, or a negative Aeron error.
 */
int ah_poll_batch(aeron_subscription_t *subscription, ah_batch_t *batch, size_t limit);

/*
 * As above, but through a fragment assembler, so `batch` receives whole
 * reassembled messages rather than raw frames.
 *
 * The assembler must have been created with ah_collect_fragment as its delegate
 * and `batch` as the delegate clientd -- the assembler is the poll handler, and
 * it calls our collector once the message is whole.
 *
 * Note that `limit` bounds *fragments* polled, while the returned count is of
 * *messages* assembled, which may be fewer.
 */
int ah_poll_batch_assembled(
    aeron_subscription_t *subscription,
    aeron_fragment_assembler_t *assembler,
    ah_batch_t *batch,
    size_t limit);

#endif /* AERON_HASKELL_SHIM_H */
