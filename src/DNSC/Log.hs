module DNSC.Log (
  Level (..),
  new,
  ) where

import Control.Monad (when)
import System.IO (hSetBuffering, stdout, BufferMode (LineBuffering))

import DNSC.Concurrent (forkProcessQ)


data Level
  = DEBUG
  | INFO
  | NOTICE
  | WARN
  deriving (Eq, Ord, Show, Read)

new :: Level -> IO (Level -> [String] -> IO (), IO ())
new level = do
  hSetBuffering stdout LineBuffering

  (enqueue, quit) <- forkProcessQ $ putStr . unlines
  let logLines lv = when (level <= lv) . enqueue

  return (logLines, quit)
