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
      , runTest "constants report the stream" (testConstants dir)
      , runTest "assembler reassembles a message larger than the MTU" (testFragmentAssembly dir)
      , runTest "image callbacks fire on publisher join" (testImageCallbacks dir)
      , runTest "round-trip under AgentInvoker" (testAgentInvoker dir)
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
        awaitConnected client 5 (publicationIsConnected pub)
        received <- newIORef []
        withPoller sub (collect received) $ \poller -> do
          let msgs = ["hello", "aeron", "from haskell"]
          mapM_ (offerRetrying client pub) msgs
          got <- drainUntil client poller received (length msgs)
          assertEq "payloads" msgs got

{- | The zero-copy path: claim a region of the log buffer and poke bytes straight
into it, with no intermediate ByteString.
-}
testTryClaim :: FilePath -> IO ()
testTryClaim dir =
  withClient dir $ \client ->
    withPublication client channel 1002 $ \pub ->
      withSubscription client channel 1002 $ \sub -> do
        awaitConnected client 5 (publicationIsConnected pub)
        received <- newIORef []
        withPoller sub (collect received) $ \poller -> do
          let payload = [0xde, 0xad, 0xbe, 0xef] :: [Word8]
          claimRetrying client pub (length payload) $ \p ->
            mapM_ (uncurry (pokeByteOff p)) (zip [0 ..] payload)
          got <- drainUntil client poller received 1
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

{- | Constants come straight off the C struct, so a wrong offset in the hsc2hs
layout would show up here as garbage.
-}
testConstants :: FilePath -> IO ()
testConstants dir =
  withClient dir $ \client ->
    withPublication client channel 1004 $ \pub ->
      withSubscription client channel 1004 $ \sub -> do
        pc <- publicationConstants pub
        sc <- subscriptionConstants sub
        assertEq "publication streamId" 1004 (pcStreamId pc)
        assertEq "subscription streamId" 1004 (scStreamId sc)
        assertEq "publication channel" channel (pcChannel pc)
        assertEq "subscription channel" channel (scChannel sc)
        -- A sane MTU-derived payload ceiling, rather than a specific number.
        unless (pcMaxPayloadLength pc > 0 && pcMaxPayloadLength pc < pcMaxMessageLength pc)
          $ throwIO (userError ("implausible payload/message lengths: " <> show pc))

{- | A message bigger than the MTU is split across frames. A plain poller sees
the pieces; the assembling poller must see exactly one whole message.
-}
testFragmentAssembly :: FilePath -> IO ()
testFragmentAssembly dir =
  withClient dir $ \client ->
    withPublication client channel 1005 $ \pub ->
      withSubscription client channel 1005 $ \sub -> do
        awaitConnected client 5 (publicationIsConnected pub)
        pc <- publicationConstants pub

        -- Comfortably over one MTU, comfortably under the message ceiling.
        let size = pcMaxPayloadLength pc * 3 + 17
            msg = BS.replicate size 0x5a
        unless (size < pcMaxMessageLength pc)
          $ throwIO (userError "test message exceeds max message length")

        received <- newIORef []
        withAssemblingPoller sub (collect received) $ \poller -> do
          offerRetrying client pub msg
          got <- drainUntil client poller received 1
          assertEq "reassembled length" [size] (map BS.length got)
          assertEq "reassembled bytes" [msg] got

{- | The available-image callback is dispatched by the conductor, which in this
mode is a C-spawned thread calling back into Haskell.
-}
testImageCallbacks :: FilePath -> IO ()
testImageCallbacks dir =
  withClient dir $ \client -> do
    joined <- newIORef []
    let opts =
          defaultSubscriptionOpts
            { onImageAvailable = Just $ \img -> do
                ic <- imageConstants img
                modifyIORef' joined (icSessionId ic :)
            }
    withSubscriptionOpts client opts channel 1006 $ \sub ->
      withPublication client channel 1006 $ \pub -> do
        awaitConnected client 5 (publicationIsConnected pub)
        -- The callback is asynchronous, so wait for the image to be visible.
        awaitConnected client 5 ((> 0) <$> subscriptionImageCount sub)

        pc <- publicationConstants pub
        sessions <- readIORef joined
        assertEq "image count" 1 (length sessions)
        assertEq "callback saw the publisher's session" [pcSessionId pc] sessions

-- | The same round-trip with Aeron's conductor thread switched off entirely.
testAgentInvoker :: FilePath -> IO ()
testAgentInvoker dir =
  withAeron defaultConfig {aeronDir = Just dir, conductorMode = AgentInvoker} $ \client ->
    withPublication client channel 1007 $ \pub ->
      withSubscription client channel 1007 $ \sub -> do
        awaitConnected client 5 (publicationIsConnected pub)
        received <- newIORef []
        withPoller sub (collect received) $ \poller -> do
          offerRetrying client pub "invoked"
          got <- drainUntil client poller received 1
          assertEq "payload" ["invoked"] got

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
offerRetrying :: Client -> Publication -> BS.ByteString -> IO ()
offerRetrying client pub bs = go (200 :: Int)
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
  -- Pumping matters under AgentInvoker, where nothing else runs the conductor.
  again n = doWork client >> threadDelayMs 5 >> go (n - 1)

claimRetrying :: Client -> Publication -> Int -> (Ptr Word8 -> IO ()) -> IO ()
claimRetrying client pub len write = go (200 :: Int)
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
  again n = doWork client >> threadDelayMs 5 >> go (n - 1)

-- | Poll until @want@ fragments have arrived, or time out.
drainUntil :: Client -> Poller -> IORef [BS.ByteString] -> Int -> IO [BS.ByteString]
drainUntil client poller ref want = do
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
              else doWork client >> threadDelayMs 1 >> go
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
