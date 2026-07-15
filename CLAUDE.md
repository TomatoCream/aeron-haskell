# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Haskell bindings to the **Aeron C client** (`aeronc.h`) — a low-latency messaging
transport. The receive path is optimized around a C shim; understanding why is
the key to working here.

## Commands

Everything runs through `just`, and every recipe re-enters the Nix dev shell
automatically. **Never run bare `cabal`/`ghc` outside `nix develop`** — a system
GHC with a newer `base` fails resolution and blames an innocent package.

```
just build          # cabal build all
just test           # integration tests (they spawn their OWN aeronmd)
just bench          # poll-path + throughput benchmarks (also self-driving)
just fmt            # fourmolu + cabal-fmt + nixfmt + hlint  (via `nix fmt`)
just fmt-check      # nix flake check  (formatting is a CI check)
just lint           # hlint over src/ app/ test/ bench/
just driver         # run aeronmd in the foreground (for the demo only)
just run            # the demo — needs `just driver` in another terminal
just repl           # cabal repl lib:aeron-haskell
```

- **Running one test:** the test suite (`test/Main.hs`) is a hand-rolled list in
  `main`, not a framework — there is no per-test filter flag. To isolate one,
  comment out the others in the `sequence [...]` block. Each test spawns its own
  throwaway `aeronmd` against a scratch dir, so tests need only `aeronmd` on
  `PATH` (the shell provides it), never a manually started driver.
- **Hermetic build:** `nix build .#default`. Flakes only see **git-tracked**
  files — after adding a new source file, `git add` it or `nix build` reports the
  source dir as nonexistent.

## Architecture

Three layers, bottom-up. Keep raw FFI out of the top layer and idiom out of the
bottom.

- **`Aeron.FFI.Types` / `Aeron.FFI.Raw`** — a 1:1 mirror of `aeronc.h`. `Types`
  is hsc2hs (`.hsc`): opaque handles, struct layouts via `#peek`/`#poke`, error
  sentinels via `#const`. `Raw` is the raw `foreign import`s. No marshalling.
- **`Aeron.FFI.Batch` + `cbits/aeron_shim.c`** — the batched receive path.
- **`Aeron` / `Aeron.Error`** — the idiomatic, bracketed interface (`withAeron`,
  `withPublication`, `withPoller`, typed exceptions). This is the public API.

Deep-dive docs: `docs/optimizations.org` (every perf decision, with benchmarks
and the original FunPtr design in an appendix) and `docs/m4-batched-poll.org`
(the shim design record).

### Load-bearing invariants — do not break these

1. **`safe` vs `unsafe` is chosen per foreign import, and it is a correctness
   matter, not a style one.** `unsafe` = a few ns but must not block or re-enter
   Haskell; `safe` = ~100ns+, releases the capability, may block/callback. Hot
   non-blocking calls (`offer`, `try_claim`, poll) are `unsafe`; blocking or
   callback-dispatching calls (`aeron_init`, `aeron_close`, `aeron_main_do_work`)
   are `safe`. Getting this wrong freezes a capability or throws away the perf.

2. **The receive poll goes through the C shim so it can be `unsafe`.**
   `aeron_subscription_poll` takes a per-fragment callback. A Haskell `FunPtr`
   handler forces the poll to be `safe` (GHC forbids an `unsafe` call from
   re-entering Haskell). `cbits/aeron_shim.c` is the handler instead — it records
   `(ptr,len,header)` descriptors into a caller-owned array, calls no Haskell, so
   `ah_poll_batch` is imported `unsafe`. Haskell walks the array afterwards. If
   you touch the poll path, preserve this: no Haskell may run inside the poll.

3. **`Fragment` is a zero-copy view (`Ptr Word8` + len + header ptr), never a
   `ByteString`.** It points into Aeron's mapped log buffer and is valid only
   until the next poll. `fragmentByteString` is the explicit copy-out opt-in.
   Materializing a `ByteString` per fragment would allocate on the hot path and
   defeat the whole design.

4. **All client operations run on the bound thread `withAeron` establishes.**
   `aeron_errmsg()` is thread-local; an unbound Haskell thread can migrate OS
   threads and read the wrong error slot. `withAeron` uses `runInBoundThread`.
   Do not fork an unbound thread and poll from it. (This is why the exe/tests/
   bench all build `-threaded`.)

5. **The public poll API is callback-shaped on purpose**
   (`withPoller :: Subscription -> (Fragment -> IO ()) -> ...`). Both the old
   FunPtr backend and the current shim satisfy it, so the engine can change
   without moving the API. Keep it that way.

### Conductor threading

`conductorMode` in `AeronConfig`: `ConductorThread` (default — Aeron owns a
thread; callbacks fire on a C-spawned thread) or `AgentInvoker` (caller drives
`doWork` in its own loop; for latency budgets where you own your cores). Setup
helpers pump the conductor themselves, so both modes share one API.

## Nix / Aeron packaging gotchas

- **The C client is `pkgs.aeron-cpp`, NOT `pkgs.aeron`** (which is the Java
  distribution — wrapper scripts only, no C library). Pinned to **1.49.0** by
  `flake.lock`; the bundled `aeronmd` comes from the same package, so driver and
  client can never mismatch.
- **Symbols live in `libaeron.so`, not `libaeron_client_shared.so`** (the C++
  wrapper, which exports no `aeron_*` C symbols). Hence `extra-libraries: aeron`.
  aeron-cpp ships no pkg-config file; include/lib dirs come from the Nix
  `buildInputs` (dev shell) and haskell.nix `modules → components.*.libs`
  (`nix build`).
- **The runtime version string lies:** `aeron_version_full()` prints `1.44.1`
  regardless of the real version (Nix builds without git metadata). Use
  `just aeron-info` or `ldd` on a binary — trust the store path, not the string.

## Conventions

- `.hsc` files (hsc2hs): `#include` is a single `#`; `#const` yields negative
  literals, so pattern synonyms need parens (`PublicationResult (-1)`).
- Formatting/lint (fourmolu, hlint) is enforced by `nix flake check`; run
  `just fmt` before committing or the check fails.
