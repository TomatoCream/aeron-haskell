{- | Integration tests: a real media driver, a real IPC round-trip.

These are deliberately not unit tests. Each one runs against a spawned
@aeronmd@, because the only thing worth proving about an FFI binding is that
it behaves against the actual library.
-}
module Main (main) where

import Aeron
import Control.Concurrent (threadDelay)
import Control.Exception (SomeException, bracket, catch, finally, throwIO)
import Control.Monad (unless, void)
import Data.ByteString qualified as BS
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeByteOff)
import GHC.Clock (getMonotonicTime)
import System.Directory (doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getEnvironment)
import System.Exit (exitFailure)
import System.FilePath ((</>))
import System.IO (IOMode (..), openFile)
import System.Process (
  ProcessHandle,
  StdStream (..),
  createProcess,
  env,
  getProcessExitCode,
  proc,
  std_err,
  std_out,
  terminateProcess,
  waitForProcess,
 )

main :: IO ()
main = withMediaDriver $ \dir -> do
  results <-
    sequence
      [ runTest "offer/poll round-trip" (testOfferPoll dir)
      , runTest "tryClaim zero-copy write" (testTryClaim dir)
      , runTest "idle poll returns zero fragments" (testIdlePoll dir)
      ]
  unless (and results) exitFailure

runTest :: String -> IO () -> IO Bool
runTest name act =
  (act >> putStrLn ("PASS " <> name) >> pure True)
    `catch` \(e :: SomeException) -> do
      putStrLn ("FAIL " <> name <> ": " <> show e)
      pure False

-- Tests --------------------------------------------------------------------

channel :: String
channel = "aeron:ipc"

-- | Publish three messages, poll them back, check the bytes survive the trip.
testOfferPoll :: FilePath -> IO ()
testOfferPoll dir =
  withClient dir $ \client ->
    withPublication client channel 1001 $ \pub ->
      withSubscription client channel 1001 $ \sub -> do
        awaitConnected 5 (publicationIsConnected pub)
        received <- newIORef []
        withPoller sub (collect received) $ \poller -> do
          let msgs = ["hello", "aeron", "from haskell"]
          mapM_ (offerRetrying pub) msgs
          got <- drainUntil poller received (length msgs)
          assertEq "payloads" msgs got

{- | The zero-copy path: claim a region of the log buffer and poke bytes straight
into it, with no intermediate ByteString.
-}
testTryClaim :: FilePath -> IO ()
testTryClaim dir =
  withClient dir $ \client ->
    withPublication client channel 1002 $ \pub ->
      withSubscription client channel 1002 $ \sub -> do
        awaitConnected 5 (publicationIsConnected pub)
        received <- newIORef []
        withPoller sub (collect received) $ \poller -> do
          let payload = [0xde, 0xad, 0xbe, 0xef] :: [Word8]
          claimRetrying pub (length payload) $ \p ->
            mapM_ (uncurry (pokeByteOff p)) (zip [0 ..] payload)
          got <- drainUntil poller received 1
          assertEq "claimed payload" [BS.pack payload] got

{- | An idle subscription must yield zero fragments, rather than blocking or
reporting an error.
-}
testIdlePoll :: FilePath -> IO ()
testIdlePoll dir =
  withClient dir $ \client ->
    withSubscription client channel 1003 $ \sub -> do
      received <- newIORef []
      withPoller sub (collect received) $ \poller -> do
        n <- pollFragments poller 10
        assertEq "fragment count" 0 n

-- Helpers ------------------------------------------------------------------

withClient :: FilePath -> (Client -> IO a) -> IO a
withClient dir = withAeron defaultConfig {aeronDir = Just dir}

collect :: IORef [BS.ByteString] -> Fragment -> IO ()
collect ref frag = do
  bs <- fragmentByteString frag
  modifyIORef' ref (bs :)

{- | Back-pressure, admin actions and not-yet-connected are normal results, not
failures. Anything else is a genuine error.
-}
offerRetrying :: Publication -> BS.ByteString -> IO ()
offerRetrying pub bs = go (200 :: Int)
 where
  go 0 = throwIO (userError "offer: gave up retrying")
  go n = do
    r <- offerByteString pub bs
    if not (isPublicationError r)
      then pure ()
      else case r of
        BackPressured -> again n
        AdminAction -> again n
        NotConnected -> again n
        _ -> throwIO (userError ("offer failed: " <> show r))
  again n = threadDelayMs 5 >> go (n - 1)

claimRetrying :: Publication -> Int -> (Ptr Word8 -> IO ()) -> IO ()
claimRetrying pub len write = go (200 :: Int)
 where
  go 0 = throwIO (userError "tryClaim: gave up retrying")
  go n = do
    r <- tryClaim pub len write
    case r of
      Right () -> pure ()
      Left BackPressured -> again n
      Left NotConnected -> again n
      Left AdminAction -> again n
      Left other -> throwIO (userError ("tryClaim failed: " <> show other))
  again n = threadDelayMs 5 >> go (n - 1)

-- | Poll until @want@ fragments have arrived, or time out.
drainUntil :: Poller -> IORef [BS.ByteString] -> Int -> IO [BS.ByteString]
drainUntil poller ref want = do
  deadline <- (+ 5) <$> getMonotonicTime
  let go = do
        _ <- pollFragments poller 10
        got <- readIORef ref
        if length got >= want
          then pure (reverse got)
          else do
            now <- getMonotonicTime
            if now > deadline
              then throwIO (userError ("timed out: wanted " <> show want <> ", got " <> show (length got)))
              else threadDelayMs 1 >> go
  go

assertEq :: (Eq a, Show a) => String -> a -> a -> IO ()
assertEq what expected actual =
  unless (expected == actual)
    $ throwIO (userError (what <> ": expected " <> show expected <> ", got " <> show actual))

threadDelayMs :: Int -> IO ()
threadDelayMs ms = threadDelay (ms * 1000)

-- Media driver -------------------------------------------------------------

{- | Spawn @aeronmd@ against a scratch directory and tear it down afterwards.

The driver has to be a separate process: the Nix package ships
@libaeron_driver.so@ but not its header, so there is no embedded driver to
start in-process.
-}
withMediaDriver :: (FilePath -> IO a) -> IO a
withMediaDriver act = do
  tmp <- getTemporaryDirectory
  let dir = tmp </> "aeron-haskell-test"
  bracket (startDriver dir) (stopDriver dir) (const (act dir))

startDriver :: FilePath -> IO ProcessHandle
startDriver dir = do
  env0 <- getEnvironment
  let overrides =
        [ ("AERON_DIR", dir)
        , ("AERON_DIR_DELETE_ON_START", "true")
        , ("AERON_DIR_DELETE_ON_SHUTDOWN", "true")
        ]
      env' = overrides <> filter ((`notElem` map fst overrides) . fst) env0

  -- The driver is chatty on stdout; keep the test output readable.
  devnull <- openFile "/dev/null" WriteMode
  (_, _, _, ph) <-
    createProcess
      (proc "aeronmd" [])
        { env = Just env'
        , std_out = UseHandle devnull
        , std_err = UseHandle devnull
        }
  awaitCncFile dir ph
  pure ph

-- | The driver is ready once it has published its CnC file.
awaitCncFile :: FilePath -> ProcessHandle -> IO ()
awaitCncFile dir ph = do
  deadline <- (+ 10) <$> getMonotonicTime
  let cnc = dir </> "cnc.dat"
      go = do
        exists <- doesFileExist cnc
        unless exists $ do
          early <- getProcessExitCode ph
          case early of
            Just code -> throwIO (userError ("aeronmd exited early: " <> show code))
            Nothing -> do
              now <- getMonotonicTime
              if now > deadline
                then throwIO (userError "aeronmd never created cnc.dat")
                else threadDelayMs 50 >> go
  go

stopDriver :: FilePath -> ProcessHandle -> IO ()
stopDriver dir ph =
  (terminateProcess ph >> void (waitForProcess ph))
    `finally` (removeDirectoryRecursive dir `catch` \(_ :: SomeException) -> pure ())
