{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Rib.App
  ( App(..)
  , dev
  , run
  , runWith
  , ribOutputDir
  , ribInputDir
  ) where

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Monad (forever, void, when)
import Data.Bool (bool)

import Development.Shake
import Development.Shake.Forward (shakeForward)
import System.Console.CmdArgs
import System.FSNotify (watchTree, withManager)

import qualified Rib.Server as Server

data App
  = Watch
  | Serve { port :: Int, watch :: Bool }
  | Generate { force :: Bool }
  deriving (Data,Typeable,Show,Eq)

-- | The path where static files will be generated.
--
-- Rib's server uses this directory when serving files.
ribOutputDir :: FilePath
ribOutputDir = "b"

-- | Directory from which content will be read.
--
-- This should ideally not be "." as the watchTree below can interfere with
-- Shake's file scaning.
ribInputDir :: FilePath
ribInputDir = "a"

-- | CLI entry point for running the Rib app
run :: Action () -> IO ()
run buildAction = runWith buildAction =<< cmdArgs ribCli
  where
    ribCli = modes
      [ Watch
          &= help "Watch for changes and generate"
      , Serve
          { port = 8080 &= help "Port to bind to"
          , watch = False &= help "Watch in addition to serving generated files"
          } &= help "Serve the generated site"
      , Generate
          { force = False &= help "Force generation of all files"
          } &= help "Generate the site"
            &= auto  -- Generate is the default command.
      ]

-- | CLI entry point for development server for use with GHCID
dev :: Int -> Action () -> IO ()
dev p a = runWith a $ Serve p True

-- | Like `run` but uses the given `App` mode instead of reading it from CLI
-- arguments.
runWith :: Action () -> App -> IO ()
runWith buildAction = \case
  Watch -> withManager $ \mgr -> do
    -- Begin with a *full* generation as the HTML layout may have been changed.
    runWith buildAction $ Generate True
    -- And then every time a file changes under the current directory
    void $ watchTree mgr ribInputDir (const True) $ const $
      runWith buildAction $ Generate False
    -- Wait forever, effectively.
    forever $ threadDelay maxBound

  Serve p w -> concurrently_
    (when w $ runWith buildAction Watch)
    (Server.serve p ribOutputDir)

  Generate forceGen ->
    let opts = shakeOptions
          { shakeVerbosity = Chatty
          , shakeRebuild = bool [] [(RebuildNow, "**")] forceGen
          }
    in shakeForward opts buildAction
