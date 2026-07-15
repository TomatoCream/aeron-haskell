{- | Benchmarks for the poll path, which is what M4 changes.

Four measurements, chosen because each isolates a different cost:

* __empty poll__ — one @aeron_subscription_poll@ against an idle subscription.
  No fragments, so this is purely the foreign-call overhead. This is the number
  that a @safe@ → @unsafe@ import should move.

* __drain__ — cost per fragment when draining a pre-filled stream on one thread.
  This is the number that removing the per-fragment C → Haskell trampoline should
  move.

* __throughput__ — sustained end-to-end messages/sec, publisher and subscriber on
  separate threads. Includes real cross-thread transport and back-pressure, which
  @drain@ deliberately excludes.

* __round trip__ — end-to-end IPC ping-pong latency between two clients on two
  bound threads. The number anyone actually cares about, and the one where the
  above either show up or don't.

Samples are written into a preallocated buffer rather than a list, so the
measurement loop itself does not allocate and drag the GC into the numbers.
-}
module Main (main) where

import Aeron
import Control.Concurrent (forkOS, threadDelay)
import Control.Exception (bracket, finally, throwIO)
import Control.Monad (unless, void, when)
import Data.ByteString qualified as BS
import Data.IORef (IORef, newIORef, readIORef, writeIORef)
import Data.List (sort)
import Data.Word (Word64)
import Foreign.Marshal.Array (mallocArray, peekArray)
import Foreign.Ptr (Ptr)
import Foreign.Storable (pokeElemOff)
import GHC.Clock (getMonotonicTimeNSec)
import System.Directory (doesFileExist, getTemporaryDirectory, removeDirectoryRecursive)
import System.Environment (getEnvironment)
import System.IO (BufferMode (..), IOMode (..), hSetBuffering, openFile, stdout)
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
import Text.Printf (printf)

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  withMediaDriver $ \dir -> do
    putStrLn "backend: batched C shim, unsafe poll (M4)\n"
    benchEmptyPoll dir
    benchDrain dir
    benchThroughput dir
    benchRoundTrip dir

-- Benchmarks ---------------------------------------------------------------

emptyPollIters :: Int
emptyPollIters = 200_000

-- | Foreign-call overhead, with no fragments in play at all.
benchEmptyPoll :: FilePath -> IO ()
benchEmptyPoll dir =
  withClient dir $ \client ->
    withSubscription client "aeron:ipc" 2001 $ \sub ->
      withPoller sub (\_ -> pure ()) $ \poller -> do
        -- Warm up: first calls pay for page faults and branch predictors.
        replicateM_' 10_000 (pollFragments poller 10)

        t0 <- getMonotonicTimeNSec
        replicateM_' emptyPollIters (pollFragments poller 10)
        t1 <- getMonotonicTimeNSec

        let total = fromIntegral (t1 - t0) :: Double
        printf
          "empty poll : %.1f ns/call  (%d calls)\n"
          (total / fromIntegral emptyPollIters)
          emptyPollIters

drainMsgs :: Int
drainMsgs = 100_000

-- | Per-fragment cost: fill the stream, then time draining it.
benchDrain :: FilePath -> IO ()
benchDrain dir =
  withClient dir $ \client ->
    withPublication client "aeron:ipc" 2002 $ \pub ->
      withSubscription client "aeron:ipc" 2002 $ \sub -> do
        awaitConnected client 5 (publicationIsConnected pub)
        counter <- newIORef (0 :: Int)
        withPoller sub (\_ -> modifyCount counter) $ \poller -> do
          let msg = BS.replicate 64 0x41

          -- Publish and drain concurrently on one thread: the term buffer is
          -- far smaller than drainMsgs, so we must keep draining as we fill.
          writeIORef counter 0
          t0 <- getMonotonicTimeNSec
          feedAndDrain pub poller msg drainMsgs
          drainRemaining poller counter drainMsgs
          t1 <- getMonotonicTimeNSec

          got <- readIORef counter
          unless (got == drainMsgs)
            $ throwIO (userError ("drained " <> show got <> " of " <> show drainMsgs))

          let total = fromIntegral (t1 - t0) :: Double
          printf
            "drain      : %.1f ns/fragment  (%d fragments, %.2f M frag/s)\n"
            (total / fromIntegral drainMsgs)
            drainMsgs
            (fromIntegral drainMsgs * 1000 / total :: Double)

throughputMsgs :: Int
throughputMsgs = 2_000_000

throughputMsgSize :: Int
throughputMsgSize = 32

{- | Sustained end-to-end throughput: a publisher thread offers flat out while a
separate subscriber thread drains, timed from the first offer to the last
message arriving. This is the number a data feed cares about — unlike 'benchDrain'
(single thread, pre-filled) it includes real cross-thread transport and the
back-pressure the publisher feels when the subscriber falls behind.

Publisher and subscriber are separate clients on separate bound threads, since
that is how a throughput workload is actually deployed.
-}
benchThroughput :: FilePath -> IO ()
benchThroughput dir = do
  subReady <- newIORef False
  subDone <- newIORef False
  endTime <- newIORef (0 :: Word64)
  received <- newIORef (0 :: Int)

  _ <- forkOS (subscriber dir subReady subDone received endTime)
  waitFor subReady

  withClient dir $ \client ->
    withPublication client "aeron:ipc" 2005 $ \pub -> do
      awaitConnected client 10 (publicationIsConnected pub)
      let msg = BS.replicate throughputMsgSize 0x54

      t0 <- getMonotonicTimeNSec
      loopN throughputMsgs (const (offerBlocking pub msg))
      -- The subscriber records the end time once it has them all, then flags
      -- done, so reading endTime after `done` cannot race the write.
      waitFor subDone
      t1 <- readIORef endTime

      got <- readIORef received
      unless (got == throughputMsgs)
        $ throwIO (userError ("received " <> show got <> " of " <> show throughputMsgs))

      let elapsed = fromIntegral (t1 - t0) :: Double
          secs = elapsed / 1e9
          bytes = fromIntegral (throughputMsgs * throughputMsgSize) :: Double
      printf
        "throughput : %.2f M msg/s  %.0f MB/s  (%d x %dB in %.2f s)\n"
        (fromIntegral throughputMsgs / secs / 1e6)
        (bytes / secs / 1e6)
        throughputMsgs
        throughputMsgSize
        secs

-- | The draining half of the throughput run, on its own client and bound thread.
subscriber :: FilePath -> IORef Bool -> IORef Bool -> IORef Int -> IORef Word64 -> IO ()
subscriber dir ready done received endTime =
  withClient dir $ \client ->
    withSubscription client "aeron:ipc" 2005 $ \sub ->
      -- A generous batch: fewer poll calls per message when the stream is hot.
      withPollerCapacity 4096 sub (const (modifyCount received)) $ \poller -> do
        writeIORef ready True
        let loop = do
              _ <- pollFragments poller 256
              n <- readIORef received
              if n >= throughputMsgs
                then getMonotonicTimeNSec >>= writeIORef endTime >> writeIORef done True
                else loop
        loop

rttIters :: Int
rttIters = 50_000

{- | End-to-end ping-pong across two clients, each on its own bound thread.

The responder echoes a fixed reply rather than the request's bytes, so nothing
allocates in its loop and we measure transport, not marshalling.
-}
benchRoundTrip :: FilePath -> IO ()
benchRoundTrip dir = do
  ready <- newIORef False
  stop <- newIORef False
  samples <- mallocArray rttIters :: IO (Ptr Word64)

  _ <- forkOS (responder dir ready stop)
  waitFor ready

  withClient dir $ \client ->
    withPublication client "aeron:ipc" 2003 $ \ping ->
      withSubscription client "aeron:ipc" 2004 $ \pong -> do
        awaitConnected client 10 (publicationIsConnected ping)
        awaitConnected client 10 (subscriptionIsConnected pong)

        gotPong <- newIORef False
        withPoller pong (\_ -> writeIORef gotPong True) $ \poller -> do
          let request = BS.replicate 32 0x50
              roundTrip = do
                writeIORef gotPong False
                offerBlocking ping request
                spinUntilPong poller gotPong

          replicateM_' 5_000 roundTrip

          loopN rttIters $ \i -> do
            t0 <- getMonotonicTimeNSec
            roundTrip
            t1 <- getMonotonicTimeNSec
            pokeElemOff samples i (t1 - t0)

          writeIORef stop True
          xs <- sort . map fromIntegral <$> peekArray rttIters samples
          report "round trip" (xs :: [Double])

-- | The far side of the ping-pong, on its own client and its own bound thread.
responder :: FilePath -> IORef Bool -> IORef Bool -> IO ()
responder dir ready stop =
  withClient dir $ \client ->
    withSubscription client "aeron:ipc" 2003 $ \ping ->
      withPublication client "aeron:ipc" 2004 $ \pong -> do
        gotPing <- newIORef False
        withPoller ping (\_ -> writeIORef gotPing True) $ \poller -> do
          -- Signal as soon as the resources exist, NOT once `pong` is connected:
          -- pong can only connect after the main thread subscribes to 2004, and
          -- the main thread waits on this flag before doing so. Waiting here
          -- would deadlock. offerBlocking already spins through NotConnected.
          writeIORef ready True
          let reply = BS.replicate 32 0x51
              loop = do
                n <- pollFragments poller 1
                when (n > 0) $ do
                  writeIORef gotPing False
                  offerBlocking pong reply
                done <- readIORef stop
                unless done loop
          loop

-- Helpers ------------------------------------------------------------------

withClient :: FilePath -> (Client -> IO a) -> IO a
withClient dir = withAeron defaultConfig {aeronDir = Just dir}

modifyCount :: IORef Int -> IO ()
modifyCount ref = readIORef ref >>= \n -> writeIORef ref $! n + 1

{- | Offer, retrying through back-pressure. Back-pressure is a normal result, so
this is a spin, not an error path.
-}
offerBlocking :: Publication -> BS.ByteString -> IO ()
offerBlocking pub bs = go
 where
  go = do
    r <- offerByteString pub bs
    when (isPublicationError r) $ case r of
      BackPressured -> go
      AdminAction -> go
      NotConnected -> go
      _ -> throwIO (userError ("offer failed: " <> show r))

spinUntilPong :: Poller -> IORef Bool -> IO ()
spinUntilPong poller flag = go
 where
  go = do
    ok <- readIORef flag
    unless ok (pollFragments poller 1 >> go)

-- | Publish while draining, since the term buffer cannot hold the whole run.
feedAndDrain :: Publication -> Poller -> BS.ByteString -> Int -> IO ()
feedAndDrain pub poller msg = go
 where
  go 0 = pure ()
  go n = do
    r <- offerByteString pub msg
    if isPublicationError r
      then case r of
        BackPressured -> pollFragments poller 100 >> go n
        AdminAction -> go n
        NotConnected -> go n
        _ -> throwIO (userError ("offer failed: " <> show r))
      else go (n - 1)

drainRemaining :: Poller -> IORef Int -> Int -> IO ()
drainRemaining poller counter want = go
 where
  go = do
    got <- readIORef counter
    unless (got >= want) (pollFragments poller 100 >> go)

report :: String -> [Double] -> IO ()
report name xs =
  printf
    "%-11s: p50 %.0f ns  p99 %.0f ns  p99.9 %.0f ns  (%d samples)\n"
    name
    (pct 50 xs)
    (pct 99 xs)
    (pct 99.9 xs)
    (length xs)

-- | @xs@ must already be sorted.
pct :: Double -> [Double] -> Double
pct p xs = xs !! max 0 (min (n - 1) idx)
 where
  n = length xs
  idx = floor (p / 100 * fromIntegral n)

replicateM_' :: Int -> IO a -> IO ()
replicateM_' n act = loopN n (const (void act))

loopN :: Int -> (Int -> IO ()) -> IO ()
loopN n act = go 0
 where
  go !i = when (i < n) (act i >> go (i + 1))

waitFor :: IORef Bool -> IO ()
waitFor ref = do
  ok <- readIORef ref
  unless ok (threadDelay 1000 >> waitFor ref)

-- Media driver -------------------------------------------------------------

withMediaDriver :: (FilePath -> IO a) -> IO a
withMediaDriver act = do
  tmp <- getTemporaryDirectory
  let dir = tmp </>! "aeron-haskell-bench"
  bracket (startDriver dir) (stopDriver dir) (const (act dir))
 where
  a </>! b = a <> "/" <> b

startDriver :: FilePath -> IO ProcessHandle
startDriver dir = do
  env0 <- getEnvironment
  let overrides =
        [ ("AERON_DIR", dir)
        , ("AERON_DIR_DELETE_ON_START", "true")
        , ("AERON_DIR_DELETE_ON_SHUTDOWN", "true")
        ]
      env' = overrides <> filter ((`notElem` map fst overrides) . fst) env0
  devnull <- openFile "/dev/null" WriteMode
  (_, _, _, ph) <-
    createProcess
      (proc "aeronmd" [])
        { env = Just env'
        , std_out = UseHandle devnull
        , std_err = UseHandle devnull
        }
  awaitCnc ph
  pure ph
 where
  awaitCnc ph = do
    let cnc = dir <> "/cnc.dat"
        go i = do
          exists <- doesFileExist cnc
          unless exists $ do
            early <- getProcessExitCode ph
            case early of
              Just c -> throwIO (userError ("aeronmd exited early: " <> show c))
              Nothing ->
                if i > (200 :: Int)
                  then throwIO (userError "aeronmd never created cnc.dat")
                  else threadDelay 50_000 >> go (i + 1)
    go 0

stopDriver :: FilePath -> ProcessHandle -> IO ()
stopDriver dir ph =
  (terminateProcess ph >> void (waitForProcess ph))
    `finally` removeDirectoryRecursive dir
