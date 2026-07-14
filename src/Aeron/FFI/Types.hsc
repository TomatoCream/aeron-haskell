-- | Raw FFI types: opaque handles, result sentinels, and struct layouts.
--
-- This module mirrors @aeronc.h@ and performs no marshalling or resource
-- management. The idiomatic layer ("Aeron") sits above it.
module Aeron.FFI.Types (
  -- * Opaque handles
  -- $opaque
  AeronContext,
  Aeron,
  Publication,
  Subscription,
  Image,
  AeronHeader,
  AsyncAddPublication,
  AsyncAddSubscription,
  FragmentAssembler,

  -- * Publication result codes
  PublicationResult (..),
  pattern NotConnected,
  pattern BackPressured,
  pattern AdminAction,
  pattern Closed,
  pattern MaxPositionExceeded,
  pattern PublicationErr,
  isPublicationError,

  -- * Structs
  BufferClaim (..),
  PublicationConstants (..),
  publicationConstantsSize,
  peekPublicationConstants,
  SubscriptionConstants (..),
  subscriptionConstantsSize,
  peekSubscriptionConstants,
  ImageConstants (..),
  imageConstantsSize,
  peekImageConstants,

  -- * Callback types
  FragmentHandlerC,
  ErrorHandlerC,
  ImageHandlerC,
) where

import Data.Int (Int32, Int64)
import Data.Word (Word8)
import Foreign.C.String (CString, peekCString)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (Ptr)
import Foreign.Storable (Storable (..))

#include <aeron/aeronc.h>

-- $opaque
-- These types are never dereferenced from Haskell. They exist only so that a
-- @Ptr Aeron@ cannot silently unify with a @Ptr Publication@.

data AeronContext
data Aeron
data Publication
data Subscription
data Image
data AeronHeader
data AsyncAddPublication
data AsyncAddSubscription
data FragmentAssembler

-- | The @int64_t@ returned by @aeron_publication_offer@ and @try_claim@: a
-- non-negative value is the new stream position, a negative value is one of the
-- sentinels below.
--
-- Note that 'BackPressured' and 'NotConnected' are ordinary back-pressure
-- signals, not failures — a caller is expected to retry or drop.
newtype PublicationResult = PublicationResult Int64
  deriving newtype (Eq, Ord, Show)

pattern NotConnected, BackPressured, AdminAction :: PublicationResult
pattern Closed, MaxPositionExceeded, PublicationErr :: PublicationResult
pattern NotConnected = PublicationResult (#{const AERON_PUBLICATION_NOT_CONNECTED})
pattern BackPressured = PublicationResult (#{const AERON_PUBLICATION_BACK_PRESSURED})
pattern AdminAction = PublicationResult (#{const AERON_PUBLICATION_ADMIN_ACTION})
pattern Closed = PublicationResult (#{const AERON_PUBLICATION_CLOSED})
pattern MaxPositionExceeded = PublicationResult (#{const AERON_PUBLICATION_MAX_POSITION_EXCEEDED})
pattern PublicationErr = PublicationResult (#{const AERON_PUBLICATION_ERROR})

-- | Did the offer fail, as opposed to succeeding or being back-pressured?
isPublicationError :: PublicationResult -> Bool
isPublicationError (PublicationResult n) = n < 0

-- | @aeron_buffer_claim_t@: a claimed region of the term buffer.
--
-- 'bcData' points directly into the mapped log buffer, so writing through it is
-- zero-copy. The claim must be committed or aborted.
data BufferClaim = BufferClaim
  { bcFrameHeader :: !(Ptr Word8)
  , bcData :: !(Ptr Word8)
  , bcLength :: !CSize
  }
  deriving stock (Eq, Show)

instance Storable BufferClaim where
  sizeOf _ = #{size aeron_buffer_claim_t}
  alignment _ = #{alignment aeron_buffer_claim_t}
  peek p =
    BufferClaim
      <$> #{peek aeron_buffer_claim_t, frame_header} p
      <*> #{peek aeron_buffer_claim_t, data} p
      <*> #{peek aeron_buffer_claim_t, length} p
  poke p (BufferClaim fh d len) = do
    #{poke aeron_buffer_claim_t, frame_header} p fh
    #{poke aeron_buffer_claim_t, data} p d
    #{poke aeron_buffer_claim_t, length} p len

-- Constants ----------------------------------------------------------------

-- $constants
-- These structs are read-only snapshots. They are deliberately not 'Storable':
-- reading one converts the C @channel@ string into a Haskell 'String', and there
-- is no sensible inverse, so a 'poke' would have to be partial.

-- | @aeron_publication_constants_t@.
data PublicationConstants = PublicationConstants
  { pcChannel :: !String
  , pcOriginalRegistrationId :: !Int64
  , pcRegistrationId :: !Int64
  , pcMaxPossiblePosition :: !Int64
  , pcPositionBitsToShift :: !Int
  , pcTermBufferLength :: !Int
  , pcMaxMessageLength :: !Int
  -- ^ Larger messages are fragmented across multiple frames.
  , pcMaxPayloadLength :: !Int
  -- ^ MTU minus the frame header: the largest a 'BufferClaim' may be.
  , pcStreamId :: !Int32
  , pcSessionId :: !Int32
  , pcInitialTermId :: !Int32
  , pcPublicationLimitCounterId :: !Int32
  , pcChannelStatusIndicatorId :: !Int32
  }
  deriving stock (Eq, Show)

publicationConstantsSize :: Int
publicationConstantsSize = #{size aeron_publication_constants_t}

peekPublicationConstants :: Ptr a -> IO PublicationConstants
peekPublicationConstants p = do
  channel <- peekCString =<< (#{peek aeron_publication_constants_t, channel} p :: IO CString)
  PublicationConstants channel
    <$> #{peek aeron_publication_constants_t, original_registration_id} p
    <*> #{peek aeron_publication_constants_t, registration_id} p
    <*> #{peek aeron_publication_constants_t, max_possible_position} p
    <*> peekSize (#{peek aeron_publication_constants_t, position_bits_to_shift} p)
    <*> peekSize (#{peek aeron_publication_constants_t, term_buffer_length} p)
    <*> peekSize (#{peek aeron_publication_constants_t, max_message_length} p)
    <*> peekSize (#{peek aeron_publication_constants_t, max_payload_length} p)
    <*> #{peek aeron_publication_constants_t, stream_id} p
    <*> #{peek aeron_publication_constants_t, session_id} p
    <*> #{peek aeron_publication_constants_t, initial_term_id} p
    <*> #{peek aeron_publication_constants_t, publication_limit_counter_id} p
    <*> #{peek aeron_publication_constants_t, channel_status_indicator_id} p

-- | @aeron_subscription_constants_t@. The two image-handler function pointers it
-- also carries are not exposed: they are only useful back in C.
data SubscriptionConstants = SubscriptionConstants
  { scChannel :: !String
  , scRegistrationId :: !Int64
  , scStreamId :: !Int32
  , scChannelStatusIndicatorId :: !Int32
  }
  deriving stock (Eq, Show)

subscriptionConstantsSize :: Int
subscriptionConstantsSize = #{size aeron_subscription_constants_t}

peekSubscriptionConstants :: Ptr a -> IO SubscriptionConstants
peekSubscriptionConstants p = do
  channel <- peekCString =<< (#{peek aeron_subscription_constants_t, channel} p :: IO CString)
  SubscriptionConstants channel
    <$> #{peek aeron_subscription_constants_t, registration_id} p
    <*> #{peek aeron_subscription_constants_t, stream_id} p
    <*> #{peek aeron_subscription_constants_t, channel_status_indicator_id} p

-- | @aeron_image_constants_t@: identifies one publisher's stream within a
-- subscription.
data ImageConstants = ImageConstants
  { icSourceIdentity :: !String
  , icCorrelationId :: !Int64
  , icJoinPosition :: !Int64
  , icTermBufferLength :: !Int
  , icMtuLength :: !Int
  , icSessionId :: !Int32
  , icInitialTermId :: !Int32
  }
  deriving stock (Eq, Show)

imageConstantsSize :: Int
imageConstantsSize = #{size aeron_image_constants_t}

peekImageConstants :: Ptr a -> IO ImageConstants
peekImageConstants p = do
  ident <- peekCString =<< (#{peek aeron_image_constants_t, source_identity} p :: IO CString)
  ImageConstants ident
    <$> #{peek aeron_image_constants_t, correlation_id} p
    <*> #{peek aeron_image_constants_t, join_position} p
    <*> peekSize (#{peek aeron_image_constants_t, term_buffer_length} p)
    <*> peekSize (#{peek aeron_image_constants_t, mtu_length} p)
    <*> #{peek aeron_image_constants_t, session_id} p
    <*> #{peek aeron_image_constants_t, initial_term_id} p

-- | @size_t@ fields land in Haskell as 'Int', which is what every caller wants.
peekSize :: IO CSize -> IO Int
peekSize = fmap fromIntegral

-- Callbacks ----------------------------------------------------------------

-- | @aeron_fragment_handler_t@: @(clientd, buffer, length, header)@.
type FragmentHandlerC = Ptr () -> Ptr Word8 -> CSize -> Ptr AeronHeader -> IO ()

-- | @aeron_error_handler_t@: @(clientd, errcode, message)@.
type ErrorHandlerC = Ptr () -> CInt -> CString -> IO ()

-- | @aeron_on_available_image_t@ / @aeron_on_unavailable_image_t@.
type ImageHandlerC = Ptr () -> Ptr Subscription -> Ptr Image -> IO ()
