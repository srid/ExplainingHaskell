{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}

module Rib.Types
  ( Page(..)
  , Post(..)
  , PostCategory(..)
  , PostFilePath(..)
  , getPostAttribute
  , getPostAttributeJson
  ) where

import Data.Aeson (FromJSON, ToJSON, decode)
import qualified Data.Map as Map
import Data.Text (Text)
import GHC.Generics (Generic)

import Development.Shake.Classes (Binary, Hashable, NFData)
import Text.Pandoc (Inline (Str), Meta (unMeta), MetaValue (MetaInlines), Pandoc (Pandoc))
import Text.Pandoc.UTF8 (fromStringLazy)

-- | Represents a HTML page that will be generated
data Page
  = Page_Index [Post]
  | Page_Post Post
  deriving (Generic, Show, FromJSON, ToJSON)

-- | A JSON serializable representation of a post's metadata
data Post = Post
  { _post_doc :: Pandoc
  , _post_url :: Text
  }
  deriving (Generic, Eq, Ord, Show, FromJSON, ToJSON)

data PostCategory
  = Programming
  | Other
  deriving (Generic, Show, Eq, Ord, FromJSON, ToJSON)

-- A simple wrapper data-type which implements 'ShakeValue';
-- Used as a Shake Cache key to build a cache of post objects.
newtype PostFilePath = PostFilePath FilePath
  deriving (Show, Eq, Hashable, Binary, NFData, Generic)

-- Get the YAML metadata for the given key in a post
--
-- This has to always return `[Inline]` unless we upgrade pandoc. See
-- https://github.com/jgm/pandoc/issues/2139#issuecomment-310522113
getPostAttribute :: String -> Post -> Maybe [Inline]
getPostAttribute k (Post (Pandoc meta _) _) =
  case Map.lookup k (unMeta meta) of
    -- When a Just value this will always be `MetaInlines`; see note in function
    -- comment above.
    Just (MetaInlines inlines) -> Just inlines
    _ -> Nothing

-- Like getPostAttribute but expects the value to be JSON encoding of a type.
getPostAttributeJson :: FromJSON a => String -> Post -> Maybe a
getPostAttributeJson k p = do
  v <- getPostAttributeRaw k p
  decode $ fromStringLazy v

getPostAttributeRaw :: String -> Post -> Maybe String
getPostAttributeRaw k p = do
  getPostAttribute k p >>= \case
    [Str v] -> Just v
    _ -> Nothing
