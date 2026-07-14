{- | Raw @foreign import@s for the Aeron C client, 1:1 with @aeronc.h@.

== Choosing @unsafe@ vs @safe@

This is the single most consequential decision in the binding, so it is made
per function rather than globally:

* @unsafe@ costs a few nanoseconds but blocks the capability for the duration
  of the call and __may not call back into Haskell__. Used for calls Aeron
  documents as non-blocking: 'c_aeron_publication_offer',
  'c_aeron_publication_try_claim', the @is_connected@ predicates.

* @safe@ costs ~100ns+ and releases the capability. Required for anything that
  can block (mapping the CnC file, joining the conductor thread) and for
  anything that invokes a Haskell 'FunPtr'.

'c_aeron_subscription_poll' is @safe@ /only/ because the fragment handler is
currently a Haskell 'FunPtr', and re-entering Haskell from an @unsafe@ call is
forbidden. Once the batched C shim lands it will become @unsafe@.
-}
module Aeron.FFI.Raw (
  -- * Errors
  c_aeron_errcode,
  c_aeron_errmsg,

  -- * Context
  c_aeron_context_init,
  c_aeron_context_close,
  c_aeron_context_set_dir,
  c_aeron_context_set_client_name,

  -- * Client
  c_aeron_init,
  c_aeron_start,
  c_aeron_close,

  -- * Publication
  c_aeron_async_add_publication,
  c_aeron_async_add_publication_poll,
  c_aeron_publication_offer,
  c_aeron_publication_try_claim,
  c_aeron_buffer_claim_commit,
  c_aeron_buffer_claim_abort,
  c_aeron_publication_is_connected,
  c_aeron_publication_close,

  -- * Subscription
  c_aeron_async_add_subscription,
  c_aeron_async_add_subscription_poll,
  c_aeron_subscription_poll,
  c_aeron_subscription_is_connected,
  c_aeron_subscription_close,

  -- * Callbacks
  mkFragmentHandler,

  -- * Version
  c_aeron_version_full,
) where

import Aeron.FFI.Types (
  Aeron,
  AeronContext,
  AsyncAddPublication,
  AsyncAddSubscription,
  BufferClaim,
  FragmentHandlerC,
  Publication,
  Subscription,
 )
import Data.Int (Int32, Int64)
import Data.Word (Word8)
import Foreign.C.String (CString)
import Foreign.C.Types (CBool (..), CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr)

-- Errors -------------------------------------------------------------------

{- $errors
Both of these read __thread-local__ state, so they are only meaningful when
called from the same OS thread that made the failing call. See "Aeron.Error".
-}

foreign import ccall unsafe "aeron/aeronc.h aeron_errcode"
  c_aeron_errcode :: IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_errmsg"
  c_aeron_errmsg :: IO CString

-- Context ------------------------------------------------------------------

foreign import ccall safe "aeron/aeronc.h aeron_context_init"
  c_aeron_context_init :: Ptr (Ptr AeronContext) -> IO CInt

foreign import ccall safe "aeron/aeronc.h aeron_context_close"
  c_aeron_context_close :: Ptr AeronContext -> IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_context_set_dir"
  c_aeron_context_set_dir :: Ptr AeronContext -> CString -> IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_context_set_client_name"
  c_aeron_context_set_client_name :: Ptr AeronContext -> CString -> IO CInt

-- Client -------------------------------------------------------------------

-- | Maps the CnC file: does real file I/O and can block.
foreign import ccall safe "aeron/aeronc.h aeron_init"
  c_aeron_init :: Ptr (Ptr Aeron) -> Ptr AeronContext -> IO CInt

-- | Spawns the client conductor thread.
foreign import ccall safe "aeron/aeronc.h aeron_start"
  c_aeron_start :: Ptr Aeron -> IO CInt

-- | Joins the conductor thread; blocks.
foreign import ccall safe "aeron/aeronc.h aeron_close"
  c_aeron_close :: Ptr Aeron -> IO CInt

-- Publication --------------------------------------------------------------

-- | Only enqueues the registration for the conductor; does not block.
foreign import ccall unsafe "aeron/aeronc.h aeron_async_add_publication"
  c_aeron_async_add_publication ::
    Ptr (Ptr AsyncAddPublication) -> Ptr Aeron -> CString -> Int32 -> IO CInt

-- | Returns 1 when complete, 0 while pending, -1 on error.
foreign import ccall unsafe "aeron/aeronc.h aeron_async_add_publication_poll"
  c_aeron_async_add_publication_poll ::
    Ptr (Ptr Publication) -> Ptr AsyncAddPublication -> IO CInt

{- | Hot path. Non-blocking by contract, and the reserved-value supplier is
always passed as NULL here, so nothing can re-enter Haskell.
-}
foreign import ccall unsafe "aeron/aeronc.h aeron_publication_offer"
  c_aeron_publication_offer ::
    Ptr Publication ->
    Ptr Word8 ->
    CSize ->
    Ptr () -> -- reserved_value_supplier: always NULL
    Ptr () -> -- clientd
    IO Int64

-- | Hot path, zero-copy: hands back a pointer into the term buffer.
foreign import ccall unsafe "aeron/aeronc.h aeron_publication_try_claim"
  c_aeron_publication_try_claim ::
    Ptr Publication -> CSize -> Ptr BufferClaim -> IO Int64

foreign import ccall unsafe "aeron/aeronc.h aeron_buffer_claim_commit"
  c_aeron_buffer_claim_commit :: Ptr BufferClaim -> IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_buffer_claim_abort"
  c_aeron_buffer_claim_abort :: Ptr BufferClaim -> IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_publication_is_connected"
  c_aeron_publication_is_connected :: Ptr Publication -> IO CBool

-- | Takes an @on_close_complete@ notification, always NULL here.
foreign import ccall safe "aeron/aeronc.h aeron_publication_close"
  c_aeron_publication_close :: Ptr Publication -> Ptr () -> Ptr () -> IO CInt

-- Subscription -------------------------------------------------------------

-- | The two image handlers are passed as NULL until M3.
foreign import ccall unsafe "aeron/aeronc.h aeron_async_add_subscription"
  c_aeron_async_add_subscription ::
    Ptr (Ptr AsyncAddSubscription) ->
    Ptr Aeron ->
    CString ->
    Int32 ->
    Ptr () -> -- on_available_image
    Ptr () -> -- available_clientd
    Ptr () -> -- on_unavailable_image
    Ptr () -> -- unavailable_clientd
    IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_async_add_subscription_poll"
  c_aeron_async_add_subscription_poll ::
    Ptr (Ptr Subscription) -> Ptr AsyncAddSubscription -> IO CInt

{- | @safe@ because @handler@ is a Haskell 'FunPtr' and an @unsafe@ call may not
re-enter Haskell. This is the one call on the hot path paying a real toll; the
batched C shim exists to remove it.
-}
foreign import ccall safe "aeron/aeronc.h aeron_subscription_poll"
  c_aeron_subscription_poll ::
    Ptr Subscription ->
    FunPtr FragmentHandlerC ->
    Ptr () -> -- clientd
    CSize -> -- fragment_limit
    IO CInt

foreign import ccall unsafe "aeron/aeronc.h aeron_subscription_is_connected"
  c_aeron_subscription_is_connected :: Ptr Subscription -> IO CBool

foreign import ccall safe "aeron/aeronc.h aeron_subscription_close"
  c_aeron_subscription_close :: Ptr Subscription -> Ptr () -> Ptr () -> IO CInt

-- Callbacks ----------------------------------------------------------------

{- | Wrap a Haskell fragment handler as a C function pointer.

The returned 'FunPtr' owns a stable pointer to the closure and must be
released with 'Foreign.Ptr.freeHaskellFunPtr'.
-}
foreign import ccall "wrapper"
  mkFragmentHandler :: FragmentHandlerC -> IO (FunPtr FragmentHandlerC)

-- Version ------------------------------------------------------------------

{- | Beware: the Nix-packaged library reports a stale hardcoded version string
regardless of the actual version. Use @ldd@ to check what was linked.
-}
foreign import ccall unsafe "aeron/aeronc.h aeron_version_full"
  c_aeron_version_full :: IO CString
