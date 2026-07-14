{- | The batched poll path: descriptor structs and the @unsafe@ poll imports.

See @cbits/aeron_shim.h@. The point of this layer is that no Haskell runs during
the poll, which is what makes an @unsafe@ import legal — not merely faster.
-}
module Aeron.FFI.Batch (
  -- * Descriptors
  AhFragment (..),
  AhBatch (..),

  -- * Polling
  c_ah_poll_batch,
  c_ah_poll_batch_assembled,
  p_ah_collect_fragment,
) where

import Aeron.FFI.Types (AeronHeader, FragmentAssembler, FragmentHandlerC, Subscription)
import Data.Word (Word8)
import Foreign.C.Types (CInt (..), CSize (..))
import Foreign.Ptr (FunPtr, Ptr)
import Foreign.Storable (Storable (..))

#include "aeron_shim.h"

-- | One fragment, as a view into Aeron's log buffer. Valid only until the next
-- poll on the same subscription.
data AhFragment = AhFragment
  { ahData :: !(Ptr Word8)
  , ahLength :: !CSize
  , ahHeader :: !(Ptr AeronHeader)
  }
  deriving stock (Eq, Show)

instance Storable AhFragment where
  sizeOf _ = #{size ah_fragment_t}
  alignment _ = #{alignment ah_fragment_t}
  peek p =
    AhFragment
      <$> #{peek ah_fragment_t, data} p
      <*> #{peek ah_fragment_t, length} p
      <*> #{peek ah_fragment_t, header} p
  poke p (AhFragment d len hdr) = do
    #{poke ah_fragment_t, data} p d
    #{poke ah_fragment_t, length} p len
    #{poke ah_fragment_t, header} p hdr

-- | The collection target. 'ahFragments' is a caller-owned array of
-- 'ahCapacity' 'AhFragment's; 'ahCount' is written by the poll.
data AhBatch = AhBatch
  { ahFragments :: !(Ptr AhFragment)
  , ahCapacity :: !CSize
  , ahCount :: !CSize
  }
  deriving stock (Eq, Show)

instance Storable AhBatch where
  sizeOf _ = #{size ah_batch_t}
  alignment _ = #{alignment ah_batch_t}
  peek p =
    AhBatch
      <$> #{peek ah_batch_t, fragments} p
      <*> #{peek ah_batch_t, capacity} p
      <*> #{peek ah_batch_t, count} p
  poke p (AhBatch frags cap cnt) = do
    #{poke ah_batch_t, fragments} p frags
    #{poke ah_batch_t, capacity} p cap
    #{poke ah_batch_t, count} p cnt

-- | Poll and collect. @unsafe@ is legal here precisely because the handler is
-- C, not Haskell: nothing can re-enter the RTS during the call.
foreign import ccall unsafe "aeron_shim.h ah_poll_batch"
  c_ah_poll_batch :: Ptr Subscription -> Ptr AhBatch -> CSize -> IO CInt

-- | As above, but through an assembler, so the batch receives whole messages.
foreign import ccall unsafe "aeron_shim.h ah_poll_batch_assembled"
  c_ah_poll_batch_assembled ::
    Ptr Subscription -> Ptr FragmentAssembler -> Ptr AhBatch -> CSize -> IO CInt

-- | The address of the C collector, to be installed as an assembler's delegate.
foreign import ccall unsafe "&ah_collect_fragment"
  p_ah_collect_fragment :: FunPtr FragmentHandlerC
