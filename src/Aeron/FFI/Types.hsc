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
  AeronHeader,
  AsyncAddPublication,
  AsyncAddSubscription,

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

  -- * Callback types
  FragmentHandlerC,
) where

import Data.Int (Int64)
import Data.Word (Word8)
import Foreign.C.Types (CSize (..))
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
data AeronHeader
data AsyncAddPublication
data AsyncAddSubscription

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

-- | @aeron_fragment_handler_t@: @(clientd, buffer, length, header)@.
type FragmentHandlerC = Ptr () -> Ptr Word8 -> CSize -> Ptr AeronHeader -> IO ()
