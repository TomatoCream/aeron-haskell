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
  ConductorMode (..),
  defaultConfig,
  withAeron,

  -- ** Driving the conductor
  -- $invoker
  doWork,
  idleStrategy,

  -- * Publications
  Publication,
  withPublication,
  publicationIsConnected,
  publicationConstants,
  PublicationConstants (..),

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
  SubscriptionOpts (..),
  defaultSubscriptionOpts,
  withSubscription,
  withSubscriptionOpts,
  subscriptionIsConnected,
  subscriptionImageCount,
  subscriptionConstants,
  SubscriptionConstants (..),

  -- * Images
  Image,
  imageConstants,
  ImageConstants (..),

  -- ** Receiving
  Fragment (..),
  fragmentByteString,
  Poller,
  withPoller,
  withAssemblingPoller,
  pollFragments,

  -- * Waiting
  awaitConnected,
) where

import Aeron.Error (checkNeg, throwAeron)
import Aeron.FFI.Raw
import Aeron.FFI.Types (
  BufferClaim (..),
  ErrorHandlerC,
  FragmentHandlerC,
  ImageConstants (..),
  ImageHandlerC,
  PublicationConstants (..),
  PublicationResult (..),
  SubscriptionConstants (..),
  imageConstantsSize,
  isPublicationError,
  peekImageConstants,
  peekPublicationConstants,
  peekSubscriptionConstants,
  publicationConstantsSize,
  subscriptionConstantsSize,
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
import Foreign.C.String (peekCString, withCString)
import Foreign.C.Types (CBool (..), CInt)
import Foreign.Marshal.Alloc (alloca, allocaBytes)
import Foreign.Ptr (FunPtr, Ptr, castPtr, freeHaskellFunPtr, nullFunPtr, nullPtr)
import Foreign.Storable (peek)
import GHC.Clock (getMonotonicTime)

-- Client -------------------------------------------------------------------

-- | Who runs the client conductor's duty cycle.
data ConductorMode
  = -- | Aeron spawns and owns a conductor thread. Simple, and the default.
    ConductorThread
  | {- | You own the duty cycle and must call 'doWork' regularly.

    This is the mode to want under a latency budget: no Aeron-owned thread
    wakes up on a core you have pinned, and the callbacks fire on your thread
    rather than on a C-spawned one. It costs you the obligation to pump.
    -}
    AgentInvoker
  deriving stock (Eq, Show)

data Client = Client
  { clientPtr :: !(Ptr T.Aeron)
  , clientMode :: !ConductorMode
  }

data AeronConfig = AeronConfig
  { aeronDir :: Maybe FilePath
  {- ^ The media driver's directory. 'Nothing' uses Aeron's default (or the
  @AERON_DIR@ environment variable).
  -}
  , clientName :: Maybe String
  , conductorMode :: ConductorMode
  , onError :: Maybe (Int -> String -> IO ())
  {- ^ Called for errors the conductor raises out-of-band, which would otherwise
  go to Aeron's default handler (which aborts the process).
  -}
  }

defaultConfig :: AeronConfig
defaultConfig =
  AeronConfig
    { aeronDir = Nothing
    , clientName = Nothing
    , conductorMode = ConductorThread
    , onError = Nothing
    }

{- | Connect to a running media driver, run the body, then shut down.

The body runs on a bound thread; see the module header.
-}
withAeron :: AeronConfig -> (Client -> IO a) -> IO a
withAeron cfg act = runInBoundThread
  $ withErrorHandler (onError cfg)
  $ \errFp ->
    withContext cfg errFp $ \ctx ->
      bracket (startClient ctx) closeClient $ \p ->
        act (Client {clientPtr = p, clientMode = conductorMode cfg})
 where
  startClient ctx = alloca $ \pClient -> do
    _ <- checkNeg "aeron_init" (c_aeron_init pClient ctx)
    client <- peek pClient
    _ <- checkNeg "aeron_start" (c_aeron_start client)
    pure client

  closeClient client = void (checkNeg "aeron_close" (c_aeron_close client))

{- | The 'FunPtr' must outlive the client that may call it, so it brackets both
the context and the client.
-}
withErrorHandler :: Maybe (Int -> String -> IO ()) -> (FunPtr ErrorHandlerC -> IO a) -> IO a
withErrorHandler Nothing act = act nullFunPtr
withErrorHandler (Just h) act =
  bracket (mkErrorHandler trampoline) freeHaskellFunPtr act
 where
  trampoline :: ErrorHandlerC
  trampoline _clientd code msg = peekCString msg >>= h (fromIntegral code)

-- | The context must outlive the client, so it brackets it.
withContext :: AeronConfig -> FunPtr ErrorHandlerC -> (Ptr T.AeronContext -> IO a) -> IO a
withContext AeronConfig {aeronDir, clientName, conductorMode} errFp =
  bracket acquire release
 where
  acquire = do
    ctx <- alloca $ \pCtx -> do
      _ <- checkNeg "aeron_context_init" (c_aeron_context_init pCtx)
      peek pCtx
    mapM_ (setStr ctx "aeron_context_set_dir" c_aeron_context_set_dir) aeronDir
    mapM_ (setStr ctx "aeron_context_set_client_name" c_aeron_context_set_client_name) clientName
    unless (errFp == nullFunPtr)
      $ void
      $ checkNeg "aeron_context_set_error_handler" (c_aeron_context_set_error_handler ctx errFp nullPtr)
    case conductorMode of
      ConductorThread -> pure ()
      AgentInvoker ->
        void
          $ checkNeg
            "aeron_context_set_use_conductor_agent_invoker"
            (c_aeron_context_set_use_conductor_agent_invoker ctx (CBool 1))
    pure ctx

  setStr ctx op f v = withCString v $ \c -> void (checkNeg op (f ctx c))

  release ctx = void (checkNeg "aeron_context_close" (c_aeron_context_close ctx))

{- $invoker
In 'AgentInvoker' mode nothing progresses — not even registering a
publication — unless someone runs the conductor. Call 'doWork' in your duty
cycle, and 'idleStrategy' with its result when you have nothing else to do.

The waiting helpers here ('withPublication', 'awaitConnected', …) pump the
conductor themselves, so setup works in either mode without special handling.
-}

{- | Run one conductor duty cycle. Returns the work count.

A no-op in 'ConductorThread' mode, where Aeron's own thread is doing this.
-}
doWork :: Client -> IO Int
doWork Client {clientPtr, clientMode} = case clientMode of
  ConductorThread -> pure 0
  AgentInvoker -> fromIntegral <$> checkNeg "aeron_main_do_work" (c_aeron_main_do_work clientPtr)

-- | Idle according to the client's configured strategy, given a work count.
idleStrategy :: Client -> Int -> IO ()
idleStrategy Client {clientPtr} n = c_aeron_main_idle_strategy clientPtr (fromIntegral n)

-- Publications -------------------------------------------------------------

newtype Publication = Publication (Ptr T.Publication)

-- | Register a publication and wait for the driver to confirm it.
withPublication :: Client -> String -> Int32 -> (Publication -> IO a) -> IO a
withPublication client uri streamId =
  bracket acquire release
 where
  acquire = do
    async <- withCString uri $ \cUri -> alloca $ \pAsync -> do
      _ <-
        checkNeg "aeron_async_add_publication"
          $ c_aeron_async_add_publication pAsync (clientPtr client) cUri streamId
      peek pAsync
    Publication
      <$> awaitRegistration
        client
        "aeron_async_add_publication_poll"
        (`c_aeron_async_add_publication_poll` async)

  release (Publication p) =
    void (checkNeg "aeron_publication_close" (c_aeron_publication_close p nullPtr nullPtr))

publicationIsConnected :: Publication -> IO Bool
publicationIsConnected (Publication p) = toBool <$> c_aeron_publication_is_connected p

{- | Fixed properties of the publication. 'pcMaxPayloadLength' is the ceiling on
a 'tryClaim'; 'pcMaxMessageLength' is the ceiling on an 'offer'.
-}
publicationConstants :: Publication -> IO PublicationConstants
publicationConstants (Publication p) =
  allocaBytes publicationConstantsSize $ \buf -> do
    _ <- checkNeg "aeron_publication_constants" (c_aeron_publication_constants p buf)
    peekPublicationConstants buf

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
are limited to 'pcMaxPayloadLength'; use 'offer' for larger messages.
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

-- | One publisher's stream within a subscription.
newtype Image = Image (Ptr T.Image)

imageConstants :: Image -> IO ImageConstants
imageConstants (Image i) =
  allocaBytes imageConstantsSize $ \buf -> do
    _ <- checkNeg "aeron_image_constants" (c_aeron_image_constants i buf)
    peekImageConstants buf

{- | Notifications for publishers joining and leaving.

These fire from the conductor: on a C-spawned thread in 'ConductorThread' mode,
or on whichever thread calls 'doWork' under 'AgentInvoker'. Keep them short, and
do not call back into Aeron from them.

The 'Image' is only valid for the duration of the callback.
-}
data SubscriptionOpts = SubscriptionOpts
  { onImageAvailable :: Maybe (Image -> IO ())
  , onImageUnavailable :: Maybe (Image -> IO ())
  }

defaultSubscriptionOpts :: SubscriptionOpts
defaultSubscriptionOpts =
  SubscriptionOpts {onImageAvailable = Nothing, onImageUnavailable = Nothing}

withSubscription :: Client -> String -> Int32 -> (Subscription -> IO a) -> IO a
withSubscription client = withSubscriptionOpts client defaultSubscriptionOpts

withSubscriptionOpts ::
  Client -> SubscriptionOpts -> String -> Int32 -> (Subscription -> IO a) -> IO a
withSubscriptionOpts client opts uri streamId act =
  -- The handler FunPtrs must outlive the subscription that may invoke them.
  withImageHandler (onImageAvailable opts) $ \availFp ->
    withImageHandler (onImageUnavailable opts) $ \unavailFp ->
      bracket (acquire availFp unavailFp) release act
 where
  acquire availFp unavailFp = do
    async <- withCString uri $ \cUri -> alloca $ \pAsync -> do
      _ <-
        checkNeg "aeron_async_add_subscription"
          $ c_aeron_async_add_subscription
            pAsync
            (clientPtr client)
            cUri
            streamId
            availFp
            nullPtr
            unavailFp
            nullPtr
      peek pAsync
    Subscription
      <$> awaitRegistration
        client
        "aeron_async_add_subscription_poll"
        (`c_aeron_async_add_subscription_poll` async)

  release (Subscription s) =
    void (checkNeg "aeron_subscription_close" (c_aeron_subscription_close s nullPtr nullPtr))

withImageHandler :: Maybe (Image -> IO ()) -> (FunPtr ImageHandlerC -> IO a) -> IO a
withImageHandler Nothing act = act nullFunPtr
withImageHandler (Just h) act =
  bracket (mkImageHandler trampoline) freeHaskellFunPtr act
 where
  trampoline :: ImageHandlerC
  trampoline _clientd _sub img = h (Image img)

subscriptionIsConnected :: Subscription -> IO Bool
subscriptionIsConnected (Subscription s) = toBool <$> c_aeron_subscription_is_connected s

-- | How many publishers are currently feeding this subscription.
subscriptionImageCount :: Subscription -> IO Int
subscriptionImageCount (Subscription s) =
  fromIntegral <$> checkNeg "aeron_subscription_image_count" (c_aeron_subscription_image_count s)

subscriptionConstants :: Subscription -> IO SubscriptionConstants
subscriptionConstants (Subscription s) =
  allocaBytes subscriptionConstantsSize $ \buf -> do
    _ <- checkNeg "aeron_subscription_constants" (c_aeron_subscription_constants s buf)
    peekSubscriptionConstants buf

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

The C function pointer is built once, here, rather than per poll — creating a
'FunPtr' on every call would allocate on the hot path.
-}
data Poller = Poller
  { pollerSub :: !(Ptr T.Subscription)
  , pollerFun :: !(FunPtr FragmentHandlerC)
  , pollerClientd :: !(Ptr ())
  }

{- | Bind a handler to a subscription for the duration of the body.

The handler sees raw fragments. A message larger than the MTU arrives as
several of them; use 'withAssemblingPoller' if you need whole messages.
-}
withPoller :: Subscription -> (Fragment -> IO ()) -> (Poller -> IO a) -> IO a
withPoller (Subscription sub) handler act =
  bracket (mkFragmentHandler (fragmentTrampoline handler)) freeHaskellFunPtr $ \fp ->
    act (Poller {pollerSub = sub, pollerFun = fp, pollerClientd = nullPtr})

{- | Like 'withPoller', but reassembles messages that were fragmented across
several frames, so the handler always sees a whole message.

The reassembled payload lives in the assembler's own buffer rather than the log
buffer, but the lifetime rule is unchanged: it is only valid for the duration of
the call.
-}
withAssemblingPoller :: Subscription -> (Fragment -> IO ()) -> (Poller -> IO a) -> IO a
withAssemblingPoller (Subscription sub) handler act =
  bracket (mkFragmentHandler (fragmentTrampoline handler)) freeHaskellFunPtr $ \delegate ->
    bracket (createAssembler delegate) deleteAssembler $ \asm ->
      -- Aeron's own handler does the assembling and calls our delegate, which it
      -- finds via the assembler passed as clientd.
      act
        ( Poller
            { pollerSub = sub
            , pollerFun = p_aeron_fragment_assembler_handler
            , pollerClientd = castPtr asm
            }
        )
 where
  createAssembler delegate = alloca $ \pAsm -> do
    _ <-
      checkNeg "aeron_fragment_assembler_create"
        $ c_aeron_fragment_assembler_create pAsm delegate nullPtr
    peek pAsm

  deleteAssembler asm =
    void (checkNeg "aeron_fragment_assembler_delete" (c_aeron_fragment_assembler_delete asm))

fragmentTrampoline :: (Fragment -> IO ()) -> FragmentHandlerC
fragmentTrampoline handler _clientd buf len hdr =
  handler
    Fragment
      { fragmentData = buf
      , fragmentLength = fromIntegral len
      , fragmentHeader = hdr
      }

{- | Poll for up to @fragmentLimit@ fragments, returning how many were handled.

The handler is invoked synchronously, once per fragment, before this returns.
-}
pollFragments :: Poller -> Int -> IO Int
pollFragments Poller {pollerSub, pollerFun, pollerClientd} fragmentLimit =
  fromIntegral
    <$> checkNeg
      "aeron_subscription_poll"
      (c_aeron_subscription_poll pollerSub pollerFun pollerClientd (fromIntegral fragmentLimit))

-- Waiting ------------------------------------------------------------------

{- | Spin until a predicate holds, or throw after @timeoutSeconds@. Pumps the
conductor, so it works under 'AgentInvoker'.

Intended for setup (waiting for a publication to connect), not the hot path.
-}
awaitConnected :: Client -> Double -> IO Bool -> IO ()
awaitConnected client timeoutSeconds check = do
  deadline <- (+ timeoutSeconds) <$> getMonotonicTime
  let go = do
        ok <- check
        unless ok $ do
          _ <- doWork client
          now <- getMonotonicTime
          if now > deadline
            then throwAeron "awaitConnected: timed out"
            else threadDelay 1000 >> go
  go

{- | Drive an async registration to completion: the poll returns 1 when done, 0
while pending, negative on error.
-}
awaitRegistration :: Client -> String -> (Ptr (Ptr a) -> IO CInt) -> IO (Ptr a)
awaitRegistration client op pollOnce = alloca $ \out -> do
  deadline <- (+ registrationTimeout) <$> getMonotonicTime
  let go = do
        r <- pollOnce out
        case compare r 0 of
          LT -> throwAeron op
          GT -> peek out
          EQ -> do
            -- Under AgentInvoker nobody else will advance the registration.
            _ <- doWork client
            now <- getMonotonicTime
            if now > deadline
              then throwAeron (op <> ": timed out")
              else threadDelay 1000 >> go
  go

registrationTimeout :: Double
registrationTimeout = 5.0

toBool :: CBool -> Bool
toBool (CBool b) = b /= 0
