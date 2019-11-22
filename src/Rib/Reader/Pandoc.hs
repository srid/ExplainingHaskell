{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
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
  -- * Extracting information
  , getH1
  , getFirstImg
  -- * Re-exports
  , Pandoc
  )
where

import Control.Arrow ((&&&))
import Control.Monad
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import qualified Data.ByteString as BS

import Lucid (Html, toHtmlRaw)
import Text.Pandoc
import Text.Pandoc.Filter.IncludeCode (includeCode)
import Text.Pandoc.Readers
import Text.Pandoc.Walk (query, walkM)

import Rib.Reader

instance Markup Pandoc where
  readDoc f = uncurry (Article f) . (id &&& getMetadata) . parsePure readMarkdown  -- TODO: don't hardcode readMarkdown
  readDocIO k f = do
    content <- T.decodeUtf8 <$> BS.readFile f
    doc <- parse readMarkdown content
    pure $ Article k doc (getMetadata doc)
  renderDoc = render . _article_doc

-- TODO: Should this return Nothing when metadata is empty?
getMetadata :: Pandoc -> Maybe Value
getMetadata (Pandoc meta _) = Just $ flattenMeta meta

-- | Flatten a Pandoc 'Meta' into a well-structured JSON object.
--
-- Renders Pandoc text objects into plain strings along the way.
flattenMeta :: Meta -> Value
flattenMeta (Meta meta) = toJSON $ fmap go meta
  where
    go :: MetaValue -> Value
    go (MetaMap m) = toJSON $ fmap go m
    go (MetaList m) = toJSONList $ fmap go m
    go (MetaBool m) = toJSON m
    go (MetaString m) = toJSON m
    go (MetaInlines m) = toJSON (runPure' . writer $ Pandoc mempty [Plain m])
    go (MetaBlocks m) = toJSON (runPure' . writer $ Pandoc mempty m)
    runPure' :: PandocPure a -> a
    runPure' = either (error . show) id . runPure
    writer = writePlain def

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
  -- ^ Article format. Example: `Text.Pandoc.Readers.readMarkdown`
  -> Text
  -- ^ Source text to parse
  -> IO Pandoc
parse r =
  either (error . show) (walkM includeSources) <=< runIO . r settings
  where
    settings = def { readerExtensions = exts }
    includeSources = includeCode $ Just $ Format "html5"

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
