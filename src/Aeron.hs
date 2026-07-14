{- | Idiomatic Haskell interface to the Aeron C client.

== Threading

Every operation must run on the __bound thread__ established by 'withAeron'.
This is not stylistic: Aeron reports errors through thread-local state, and an
unbound Haskell thread can migrate between OS threads and read the wrong slot
(see "Aeron.Error"). Do not fork an unbound thread and poll from it.

== Zero-copy

'Fragment' and 'tryClaim' hand you raw pointers into Aeron's mapped log
buffers. Nothing is copied, and nothing is allocated on the hot path. The
lifetime rules are narrow and are documented on each.
-}
module Aeron (
  -- * Client
  Client,
  AeronConfig (..),
  defaultConfig,
  withAeron,

  -- * Publications
  Publication,
  withPublication,
  publicationIsConnected,

  -- ** Sending
  PublicationResult (..),
  pattern NotConnected,
  pattern BackPressured,
  pattern AdminAction,
  pattern Closed,
  pattern MaxPositionExceeded,
  pattern PublicationErr,
  isPublicationError,
  offer,
  offerByteString,
  tryClaim,

  -- * Subscriptions
  Subscription,
  withSubscription,
  subscriptionIsConnected,

  -- ** Receiving
  Fragment (..),
  fragmentByteString,
  Poller,
  withPoller,
  pollFragments,

  -- * Waiting
  awaitConnected,
) where

import Aeron.Error (checkNeg, throwAeron)
import Aeron.FFI.Raw
import Aeron.FFI.Types (
  BufferClaim (..),
  FragmentHandlerC,
  PublicationResult (..),
  isPublicationError,
  pattern AdminAction,
  pattern BackPressured,
  pattern Closed,
  pattern MaxPositionExceeded,
  pattern NotConnected,
  pattern PublicationErr,
 )
import Aeron.FFI.Types qualified as T
import Control.Concurrent (runInBoundThread, threadDelay)
import Control.Exception (bracket, onException)
import Control.Monad (unless, void)
import Data.ByteString (ByteString)
import Data.ByteString qualified as BS
import Data.ByteString.Unsafe qualified as BSU
import Data.Int (Int32)
import Data.Word (Word8)
import Foreign.C.String (withCString)
import Foreign.C.Types (CBool (..), CInt)
import Foreign.Marshal.Alloc (alloca)
import Foreign.Ptr (FunPtr, Ptr, castPtr, freeHaskellFunPtr, nullPtr)
import Foreign.Storable (peek)
import GHC.Clock (getMonotonicTime)

-- Client -------------------------------------------------------------------

newtype Client = Client (Ptr T.Aeron)

data AeronConfig = AeronConfig
  { aeronDir :: Maybe FilePath
  {- ^ The media driver's directory. 'Nothing' uses Aeron's default (or the
  @AERON_DIR@ environment variable).
  -}
  , clientName :: Maybe String
  }
  deriving stock (Eq, Show)

defaultConfig :: AeronConfig
defaultConfig = AeronConfig {aeronDir = Nothing, clientName = Nothing}

{- | Connect to a running media driver, run the body, then shut down.

The body runs on a bound thread; see the module header.
-}
withAeron :: AeronConfig -> (Client -> IO a) -> IO a
withAeron cfg act = runInBoundThread
  $ withContext cfg
  $ \ctx ->
    bracket (startClient ctx) closeClient (act . Client)
 where
  startClient ctx = alloca $ \pClient -> do
    _ <- checkNeg "aeron_init" (c_aeron_init pClient ctx)
    client <- peek pClient
    _ <- checkNeg "aeron_start" (c_aeron_start client)
    pure client

  closeClient client = void (checkNeg "aeron_close" (c_aeron_close client))

-- | The context must outlive the client, so it brackets it.
withContext :: AeronConfig -> (Ptr T.AeronContext -> IO a) -> IO a
withContext AeronConfig {aeronDir, clientName} =
  bracket acquire release
 where
  acquire = do
    ctx <- alloca $ \pCtx -> do
      _ <- checkNeg "aeron_context_init" (c_aeron_context_init pCtx)
      peek pCtx
    mapM_
      (\d -> withCString d $ \c -> checkNeg "aeron_context_set_dir" (c_aeron_context_set_dir ctx c))
      aeronDir
    mapM_
      ( \n -> withCString n $ \c -> checkNeg "aeron_context_set_client_name" (c_aeron_context_set_client_name ctx c)
      )
      clientName
    pure ctx
  release ctx = void (checkNeg "aeron_context_close" (c_aeron_context_close ctx))

-- Publications -------------------------------------------------------------

newtype Publication = Publication (Ptr T.Publication)

-- | Register a publication and wait for the driver to confirm it.
withPublication :: Client -> String -> Int32 -> (Publication -> IO a) -> IO a
withPublication (Client client) uri streamId =
  bracket acquire release
 where
  acquire = do
    async <- withCString uri $ \cUri -> alloca $ \pAsync -> do
      _ <-
        checkNeg "aeron_async_add_publication" (c_aeron_async_add_publication pAsync client cUri streamId)
      peek pAsync
    Publication
      <$> awaitRegistration "aeron_async_add_publication_poll" (`c_aeron_async_add_publication_poll` async)

  release (Publication p) =
    void (checkNeg "aeron_publication_close" (c_aeron_publication_close p nullPtr nullPtr))

publicationIsConnected :: Publication -> IO Bool
publicationIsConnected (Publication p) = toBool <$> c_aeron_publication_is_connected p

{- | Offer a message from a raw buffer. Non-blocking; nothing is copied by the
binding, though Aeron itself copies into the log buffer.

A negative result is a 'PublicationResult' sentinel — note that
'BackPressured' and 'NotConnected' are normal, not errors.
-}
offer :: Publication -> Ptr Word8 -> Int -> IO PublicationResult
offer (Publication p) buf len =
  PublicationResult <$> c_aeron_publication_offer p buf (fromIntegral len) nullPtr nullPtr
{-# INLINE offer #-}

{- | Convenience wrapper over 'offer'. Uses the 'ByteString' in place, so it does
not copy — but building the 'ByteString' in the first place will have.
-}
offerByteString :: Publication -> ByteString -> IO PublicationResult
offerByteString pub bs =
  BSU.unsafeUseAsCStringLen bs $ \(p, len) -> offer pub (castPtr p) len

{- | Claim a region of the log buffer and write into it directly: zero-copy and
allocation-free, the fastest way to publish.

The claim is committed when the writer returns, and aborted if it throws. The
pointer is valid only for the duration of the callback, and only @len@ bytes
may be written.

Returns 'Left' if the claim could not be made (e.g. 'BackPressured'). Claims
are limited to less than the MTU; use 'offer' for larger messages.
-}
tryClaim :: Publication -> Int -> (Ptr Word8 -> IO a) -> IO (Either PublicationResult a)
tryClaim (Publication p) len write =
  alloca $ \pClaim -> do
    r <- c_aeron_publication_try_claim p (fromIntegral len) pClaim
    if r < 0
      then pure (Left (PublicationResult r))
      else do
        claim <- peek pClaim
        a <- write (bcData claim) `onException` c_aeron_buffer_claim_abort pClaim
        _ <- checkNeg "aeron_buffer_claim_commit" (c_aeron_buffer_claim_commit pClaim)
        pure (Right a)

-- Subscriptions ------------------------------------------------------------

newtype Subscription = Subscription (Ptr T.Subscription)

withSubscription :: Client -> String -> Int32 -> (Subscription -> IO a) -> IO a
withSubscription (Client client) uri streamId =
  bracket acquire release
 where
  acquire = do
    async <- withCString uri $ \cUri -> alloca $ \pAsync -> do
      -- The four NULLs are the available/unavailable image handlers and their
      -- clientd. Wired up in M3.
      _ <-
        checkNeg "aeron_async_add_subscription"
          $ c_aeron_async_add_subscription pAsync client cUri streamId nullPtr nullPtr nullPtr nullPtr
      peek pAsync
    Subscription
      <$> awaitRegistration "aeron_async_add_subscription_poll" (`c_aeron_async_add_subscription_poll` async)

  release (Subscription s) =
    void (checkNeg "aeron_subscription_close" (c_aeron_subscription_close s nullPtr nullPtr))

subscriptionIsConnected :: Subscription -> IO Bool
subscriptionIsConnected (Subscription s) = toBool <$> c_aeron_subscription_is_connected s

{- | A message fragment, as a view into Aeron's log buffer.

__Nothing here is copied.__ 'fragmentData' points into the mapped term buffer
and is only valid for the duration of the handler call. To keep the bytes,
copy them out with 'fragmentByteString'.
-}
data Fragment = Fragment
  { fragmentData :: !(Ptr Word8)
  , fragmentLength :: !Int
  , fragmentHeader :: !(Ptr T.AeronHeader)
  }

{- | Copy a fragment's payload out of the log buffer. Allocates — by design, this
is the explicit opt-out of zero-copy.
-}
fragmentByteString :: Fragment -> IO ByteString
fragmentByteString Fragment {fragmentData, fragmentLength} =
  BS.packCStringLen (castPtr fragmentData, fragmentLength)

{- | A subscription bound to a fragment handler.

The C function pointer is created once, here, rather than per poll — building
a 'FunPtr' on every call would allocate on the hot path.
-}
data Poller = Poller
  { pollerSub :: !(Ptr T.Subscription)
  , pollerFun :: !(FunPtr FragmentHandlerC)
  }

-- | Bind a handler to a subscription for the duration of the body.
withPoller :: Subscription -> (Fragment -> IO ()) -> (Poller -> IO a) -> IO a
withPoller (Subscription sub) handler act =
  bracket (mkFragmentHandler trampoline) freeHaskellFunPtr $ \fp ->
    act (Poller {pollerSub = sub, pollerFun = fp})
 where
  trampoline :: FragmentHandlerC
  trampoline _clientd buf len hdr =
    handler (Fragment {fragmentData = buf, fragmentLength = fromIntegral len, fragmentHeader = hdr})

{- | Poll for up to @fragmentLimit@ fragments, returning how many were handled.

The handler is invoked synchronously, once per fragment, before this returns.
-}
pollFragments :: Poller -> Int -> IO Int
pollFragments Poller {pollerSub, pollerFun} fragmentLimit =
  fromIntegral
    <$> checkNeg
      "aeron_subscription_poll"
      (c_aeron_subscription_poll pollerSub pollerFun nullPtr (fromIntegral fragmentLimit))

-- Waiting ------------------------------------------------------------------

{- | Spin until a predicate holds, or throw after @timeoutSeconds@.

Intended for setup (waiting for a publication to connect), not the hot path.
-}
awaitConnected :: Double -> IO Bool -> IO ()
awaitConnected timeoutSeconds check = do
  deadline <- (+ timeoutSeconds) <$> getMonotonicTime
  go deadline
 where
  go deadline = do
    ok <- check
    unless ok $ do
      now <- getMonotonicTime
      if now > deadline
        then throwAeron "awaitConnected: timed out"
        else threadDelay 1000 >> go deadline

{- | Drive an async registration to completion. Returns 1 when done, 0 while
pending, negative on error.
-}
awaitRegistration :: String -> (Ptr (Ptr a) -> IO CInt) -> IO (Ptr a)
awaitRegistration op pollOnce = alloca $ \out -> do
  deadline <- (+ registrationTimeout) <$> getMonotonicTime
  let go = do
        r <- pollOnce out
        case compare r 0 of
          LT -> throwAeron op
          GT -> peek out
          EQ -> do
            now <- getMonotonicTime
            if now > deadline
              then throwAeron (op <> ": timed out")
              else threadDelay 1000 >> go
  go

registrationTimeout :: Double
registrationTimeout = 5.0

toBool :: CBool -> Bool
toBool (CBool b) = b /= 0
