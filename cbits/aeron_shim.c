#include "aeron_shim.h"

void ah_collect_fragment(
    void *clientd, const uint8_t *buffer, size_t length, aeron_header_t *header)
{
    ah_batch_t *batch = (ah_batch_t *)clientd;

    /*
     * Cannot happen: the poll functions clamp `limit` to `capacity`, and Aeron
     * never delivers more fragments than the limit. Dropping is still the right
     * response to the impossible -- writing past the array would be worse.
     */
    if (batch->count >= batch->capacity)
    {
        return;
    }

    ah_fragment_t *fragment = &batch->fragments[batch->count++];
    fragment->data = buffer;
    fragment->length = length;
    fragment->header = header;
}

int ah_poll_batch(aeron_subscription_t *subscription, ah_batch_t *batch, size_t limit)
{
    batch->count = 0;

    if (limit > batch->capacity)
    {
        limit = batch->capacity;
    }

    const int result = aeron_subscription_poll(
        subscription, ah_collect_fragment, batch, limit);

    if (result < 0)
    {
        return result;
    }

    return (int)batch->count;
}

int ah_poll_batch_assembled(
    aeron_subscription_t *subscription,
    aeron_fragment_assembler_t *assembler,
    ah_batch_t *batch,
    size_t limit)
{
    batch->count = 0;

    if (limit > batch->capacity)
    {
        limit = batch->capacity;
    }

    /*
     * The assembler is the handler; it buffers frames and calls its delegate --
     * ah_collect_fragment, bound to this batch at construction -- once a message
     * is whole. So reassembled messages land in the same descriptor array, and
     * no Haskell runs during the poll here either.
     */
    const int result = aeron_subscription_poll(
        subscription, aeron_fragment_assembler_handler, assembler, limit);

    if (result < 0)
    {
        return result;
    }

    return (int)batch->count;
}
