{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Helpers for working with Pandoc documents
module Rib.Reader.Pandoc
  ( module Text.Pandoc.Readers
  -- * Parsing
  , parse
  , parsePure
  -- * Converting to HTML
  , render
  , renderInlines
  , render'
  , renderInlines'
  -- * Metadata
  , getMeta
  , setMeta
  , parseMeta
  -- * Extracting information
  , getH1
  , getFirstImg
  -- * Re-exports
  , Pandoc
  )
where

import Control.Monad
import Data.ByteString.Lazy (ByteString)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T

import Lucid (Html, toHtmlRaw)
import Text.Pandoc
import Text.Pandoc.Filter.IncludeCode (includeCode)
import Text.Pandoc.Readers
import Text.Pandoc.Readers.Markdown (yamlToMeta)
import Text.Pandoc.Shared (stringify)
import Text.Pandoc.Walk (query, walkM)


class IsMetaValue a where
  parseMetaValue :: MetaValue -> a

instance IsMetaValue [Inline] where
  parseMetaValue = \case
    MetaInlines inlines -> inlines
    _ -> error "Not a MetaInline"

instance IsMetaValue (Html ()) where
  parseMetaValue = renderInlines . parseMetaValue @[Inline]

instance IsMetaValue Text where
  parseMetaValue = T.pack . stringify . parseMetaValue @[Inline]

instance {-# Overlappable #-} IsMetaValue a => IsMetaValue [a] where
  parseMetaValue = \case
    MetaList vals -> parseMetaValue <$> vals
    _ -> error "Not a MetaList"

-- NOTE: This requires UndecidableInstances, but is there a better way?
instance {-# Overlappable #-} Read a => IsMetaValue a where
  parseMetaValue = read . T.unpack . parseMetaValue @Text


-- | Get the metadata value for the given key in a Pandoc document.
--
-- It is recommended to call this function with type application specifying the
-- type of `a`.
--
-- `MetaValue` is parsed in accordance with the `IsMetaValue` class constraint.
-- Available instances:
--
-- - `Html`: parse value as a Pandoc document and convert to Lucid Html
-- - `Text`: parse a raw value (Inline with one Str value)
-- - @[a]@: parse a list of values
-- - @Read a => a@: parse a raw value and then read it.
getMeta :: IsMetaValue a => String -> Pandoc -> Maybe a
getMeta k (Pandoc meta _) = parseMetaValue <$> lookupMeta k meta

-- | Add, or set, a metadata data key to the given Haskell value
setMeta :: Show a => String -> a -> Pandoc -> Pandoc
setMeta k v (Pandoc (Meta meta) bs) = Pandoc (Meta meta') bs
  where
    meta' = Map.insert k v' meta
    v' = MetaInlines [Str $ show v]

-- | Pure version of `parse`
parsePure :: (ReaderOptions -> Text -> PandocPure Pandoc) -> Text -> Pandoc
parsePure r =
  either (error . show) id . runPure . r settings
  where
    settings = def { readerExtensions = exts }

-- | Parse the source text as a Pandoc document
--
-- Supports the [includeCode](https://github.com/owickstrom/pandoc-include-code) extension.
parse
  :: (ReaderOptions -> Text -> PandocIO Pandoc)
  -- ^ Document format. Example: `Text.Pandoc.Readers.readMarkdown`
  -> Text
  -- ^ Source text to parse
  -> IO Pandoc
parse r =
  either (error . show) (walkM includeSources) <=< runIO . r settings
  where
    settings = def { readerExtensions = exts }
    includeSources = includeCode $ Just $ Format "html5"

-- | Parse the metadata source as a Pandoc Meta value
parseMeta :: ByteString -> IO Meta
parseMeta = either (error . show) pure <=< runIO . yamlToMeta settings
  where
    settings = def { readerExtensions = exts }

-- | Like `render` but returns the raw HTML string, or the rendering error.
render' :: Pandoc -> Either PandocError Text
render' = runPure . writeHtml5String settings
  where
    settings = def { writerExtensions = exts }

-- | Render a Pandoc document as Lucid HTML
render :: Pandoc -> Html ()
render = either (error . show) toHtmlRaw . render'

-- | Like `renderInlines` but returns the raw HTML string, or the rendering error.
renderInlines' :: [Inline] -> Either PandocError Text
renderInlines' = render' . Pandoc mempty . pure . Plain

-- | Render a list of Pandoc `Text.Pandoc.Inline` values as Lucid HTML
--
-- Useful when working with `Text.Pandoc.Meta` values from the document metadata.
renderInlines :: [Inline] -> Html ()
renderInlines = either (error . show) toHtmlRaw . renderInlines'

-- | Get the top-level heading as Lucid HTML
getH1 :: Pandoc -> Maybe (Html ())
getH1 (Pandoc _ bs) = fmap renderInlines $ flip query bs $ \case
  Header 1 _ xs -> Just xs
  _ -> Nothing

-- | Get the first image in the document if one exists
getFirstImg
  :: Pandoc
  -> Maybe Text
  -- ^ Relative URL path to the image
getFirstImg (Pandoc _ bs) = flip query bs $ \case
  Image _ _ (url, _) -> Just $ T.pack url
  _ -> Nothing

exts :: Extensions
exts = mconcat
  [ extensionsFromList
    [ Ext_yaml_metadata_block
    , Ext_fenced_code_attributes
    , Ext_auto_identifiers
    , Ext_smart
    ]
  , githubMarkdownExtensions
  ]
