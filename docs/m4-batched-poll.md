# M4: batched poll via a C shim

Status: **not started**. Everything below is design, not code.

## The problem

`aeron_subscription_poll` takes a C function pointer and calls it once per
fragment. We currently satisfy that with a Haskell closure wrapped by
`foreign import ccall "wrapper"`, which forces two costs on the hottest path in
the binding:

1. **The poll import must be `safe`.** GHC forbids an `unsafe` foreign call from
   calling back into Haskell. Our fragment handler *is* Haskell, so `unsafe` is
   not merely slower to reason about — it is illegal. A `safe` call releases the
   capability and costs ~100ns+, against a few ns for `unsafe`.
2. **A trampoline per fragment.** Every fragment crosses C → Haskell through the
   wrapper stub.

So the current `pollFragments` pays a safe-call toll on every poll *and* a
re-entry toll on every fragment. For a control plane this is irrelevant. Under a
latency budget it is the dominant cost in the binding.

## The fix

Add `cbits/aeron_shim.c` with a fragment handler written **in C**, which does not
call Haskell at all. It only records a descriptor per fragment into a
caller-supplied array:

```c
typedef struct {
    const uint8_t *data;
    size_t length;
    aeron_header_t *header;
} ah_fragment_t;

typedef struct {
    ah_fragment_t *fragments;  /* caller-owned, capacity entries */
    size_t capacity;
    size_t count;
} ah_batch_t;

/* Passed as the poll handler; clientd is an ah_batch_t*. */
void ah_collect_fragment(void *clientd, const uint8_t *buffer, size_t length,
                         aeron_header_t *header);

/* One call: poll, collect, return the count. */
int ah_poll_batch(aeron_subscription_t *sub, ah_batch_t *batch, size_t limit);
```

Haskell then calls `ah_poll_batch` as an **`unsafe`** import — legal precisely
because no Haskell runs during it — and afterwards walks the descriptor array,
invoking the user's handler per entry from ordinary Haskell code.

**The shim buys soundness, not just speed.** It is what makes the `unsafe` import
legal in the first place. That framing matters: this is not a micro-optimisation
bolted onto a working design, it is the design the C API actually wants.

Data is still zero-copy — only the `(pointer, length, header)` triples are
written down, never the payload.

## What must not change

The public signature stays as it is:

```haskell
withPoller     :: Subscription -> (Fragment -> IO ()) -> (Poller -> IO a) -> IO a
pollFragments  :: Poller -> Int -> IO Int
```

A callback-shaped API is satisfiable by **both** backends: the FunPtr one calls
the handler from C, the batched one calls it from Haskell after the fact. So M4
is an internal swap, not an API break. This was the reason for choosing that
shape back in M2.

`Fragment` must stay a zero-copy view (`Ptr Word8` + length + header pointer).
The moment it becomes a `ByteString` we allocate per fragment and no shim can win
that back.

## Invariants to enforce and document

- **Descriptor pointers are valid only until the next poll.** Aeron commits the
  stream position at the end of the poll; the term buffer is not overwritten
  immediately, but the only contract worth relying on is "consume before you poll
  again". The handler loop runs inside `pollFragments`, so this holds by
  construction — but it must be documented, because it is the sharp edge of the
  whole approach.
- **`aeron_header_t *` is transient.** It is not owned by us and must not be
  stashed. Anything needed later has to be copied out (see
  `aeron_header_values`), which is a follow-on if we expose header access.
- **The batch array is per-`Poller`**, allocated once at `withPoller` and reused.
  Allocating it per poll would reintroduce exactly the allocation we are removing.
- **Overflow.** `ah_poll_batch` must be called with `limit <= capacity`, or the
  shim silently drops fragments. Clamp on the Haskell side and assert in C.

## Assembler interaction

`withAssemblingPoller` currently passes Aeron's own
`aeron_fragment_assembler_handler` with the assembler as `clientd`. The batched
path cannot reuse that directly, since it needs *its* clientd to be the batch.
The shim therefore needs a second entry point that chains: assembler → shim
collector → batch. Worth doing after the plain path is proven, not alongside it.

## Order of work

**Benchmark first, then the shim.** M4 is an optimisation, and an optimisation
without a baseline is a guess. Concretely:

1. Add a benchmark: IPC, one publisher, one subscriber, fixed message size, measure
   round-trip latency percentiles and fragments/sec through the *current*
   FunPtr path. Commit the numbers.
2. Build the shim and the `unsafe` import behind the unchanged API.
3. Re-run the identical benchmark. Compare.
4. Only then decide whether the C file has earned its place. If the delta is
   small, the simpler pure-Haskell binding is the better artifact and the shim
   should be dropped.

That last point is the honest one: the whole exercise is falsifiable, and the
benchmark is what makes it so.

## Acceptance

- The existing seven integration tests pass unchanged against the new backend —
  that is the proof the API did not move.
- `aeron_subscription_poll`'s import (via the shim) is `unsafe`.
- Zero Haskell allocation per fragment on the poll path.
- A measured, recorded improvement over the M3 baseline.

## Not in scope

Aeron Archive and Cluster. Counters. Controlled/block poll. These are separate
surfaces and none of them changes the design above.
