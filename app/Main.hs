{- | Minimal IPC demo. Requires a running media driver (@aeronmd@); set
@AERON_DIR@ if it is not using the default directory.
-}
module Main (main) where

import Aeron
import Control.Monad (unless)
import System.Environment (lookupEnv)

main :: IO ()
main = do
  dir <- lookupEnv "AERON_DIR"
  withAeron defaultConfig {aeronDir = dir} $ \client ->
    withPublication client "aeron:ipc" 1001 $ \pub ->
      withSubscription client "aeron:ipc" 1001 $ \sub -> do
        awaitConnected client 5 (publicationIsConnected pub)

        result <- offerByteString pub "hello from haskell"
        unless (isPublicationError result)
          $ putStrLn ("offered, stream position now " <> show result)

        withPoller sub printFragment $ \poller -> do
          n <- pollUntilSome poller
          putStrLn ("polled " <> show n <> " fragment(s)")
 where
  printFragment frag = do
    bs <- fragmentByteString frag
    putStrLn ("received: " <> show bs)

  pollUntilSome poller = do
    n <- pollFragments poller 10
    if n > 0 then pure n else pollUntilSome poller
