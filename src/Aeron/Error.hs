{- | Translating Aeron's C error protocol into Haskell exceptions.

== The thread-locality hazard

@aeron_errcode()@ and @aeron_errmsg()@ read __thread-local__ state set by the
failing call. That is a trap in GHC: a Haskell thread is not pinned to an OS
thread, so between the failing call and the error retrieval the thread can be
rescheduled onto a different capability — and then we would read some other
thread's error slot, or none at all. The failure mode is an intermittent,
misleading error message, which is about the worst kind of bug to chase.

The containment is 'Control.Concurrent.runInBoundThread': a bound Haskell
thread is only ever run by its own dedicated OS thread, so every FFI call it
makes — and every error retrieval that follows — hits the same thread-local
slot. "Aeron" runs all client operations inside a bound thread for exactly
this reason.

The eventual fix is a C shim that performs the call and captures errcode and
message in one go, removing the constraint entirely.
-}
module Aeron.Error (
  AeronException (..),
  lastError,
  throwAeron,
  checkNeg,
  checkNull,
) where

import Aeron.FFI.Raw (c_aeron_errcode, c_aeron_errmsg)
import Control.Exception (Exception, throwIO)
import Foreign.C.String (peekCString)
import Foreign.C.Types (CInt)
import Foreign.Ptr (Ptr, nullPtr)

-- | An error reported by the Aeron C client.
data AeronException = AeronException
  { aeOperation :: String
  -- ^ The binding-level operation that failed, e.g. @"aeron_init"@.
  , aeErrCode :: Int
  , aeErrMsg :: String
  }
  deriving stock (Eq, Show)

instance Exception AeronException

{- | Read the calling thread's current Aeron error.

Only meaningful immediately after a failing call, on the same OS thread.
-}
lastError :: String -> IO AeronException
lastError op = do
  code <- c_aeron_errcode
  msg <- peekCString =<< c_aeron_errmsg
  pure (AeronException {aeOperation = op, aeErrCode = fromIntegral code, aeErrMsg = msg})

throwAeron :: String -> IO a
throwAeron op = throwIO =<< lastError op

-- | Aeron's convention: a negative @int@ return means failure.
checkNeg :: String -> IO CInt -> IO CInt
checkNeg op act = do
  r <- act
  if r < 0 then throwAeron op else pure r

-- | For the handful of calls that signal failure with a NULL out-pointer.
checkNull :: String -> IO (Ptr a) -> IO (Ptr a)
checkNull op act = do
  p <- act
  if p == nullPtr then throwAeron op else pure p
