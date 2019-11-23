{-# OPTIONS_GHC -fno-warn-orphans #-}  -- for `Markup Pandoc` instance
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}

-- | Helpers for working with Pandoc documents
module Rib.Markup.Pandoc
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

import Control.Monad.Except
import Data.Aeson
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.Encoding as T
import Named
import Path

import Lucid (Html, toHtmlRaw)
import Text.Pandoc
import Text.Pandoc.Filter.IncludeCode (includeCode)
import Text.Pandoc.Readers
import Text.Pandoc.Walk (query, walkM)

import Rib.Markup

data RibPandocError
  = RibPandocError_PandocError PandocError
  | RibPandocError_UnsupportedExtension String

instance Show RibPandocError where
  show = \case
    RibPandocError_PandocError e -> show e
    RibPandocError_UnsupportedExtension ext -> "Unsupported extension: " <> ext

instance Markup Pandoc where
  type MarkupError Pandoc = RibPandocError

  parseDoc k s = runExcept $ do
    r <- withExcept RibPandocError_UnsupportedExtension $
      detectReader k
    fmap (mkDoc k) $ withExcept RibPandocError_PandocError $
      parsePure r s

  readDoc (Arg k) (Arg f) = runExceptT $ do
    r <- withExceptT RibPandocError_UnsupportedExtension $
      detectReader k
    content <- liftIO $ T.decodeUtf8 <$> BS.readFile (toFilePath f)
    fmap (mkDoc k) $ withExceptT RibPandocError_PandocError $
      parse r content

  renderDoc = render . _document_val

  showMarkupError = T.pack . show

-- | Pure version of `parse`
parsePure
  :: MonadError PandocError m
  => (ReaderOptions -> Text -> PandocPure Pandoc)
  -> Text
  -> m Pandoc
parsePure r =
  either throwError pure . runPure . r settings
  where
    settings = def { readerExtensions = exts }

-- | Parse the source text as a Pandoc document
--
-- Supports the [includeCode](https://github.com/owickstrom/pandoc-include-code) extension.
parse
  :: (MonadIO m, MonadError PandocError m)
  => (ReaderOptions -> Text -> PandocIO Pandoc)
  -- ^ Document format. Example: `Text.Pandoc.Readers.readMarkdown`
  -> Text
  -- ^ Source text to parse
  -> m Pandoc
parse r s = do
  v' <- liftEither =<< liftIO (runIO $ r settings s)
  liftIO $ walkM includeSources v'
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
-- FIXME: This returns all images.
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

-- Internal code
--

-- | Detect the Pandoc reader to use based on file extension
detectReader
  :: (MonadError String m, PandocMonad m1)
  => Path Rel File
  -> m (ReaderOptions -> Text -> m1 Pandoc)
detectReader k = case Map.lookup ext formats of
  Nothing -> throwError ext
  Just r -> pure r
  where
    ext = fileExtension k
    formats = Map.fromList
      [ (".md", readMarkdown)
      , (".rst", readRST)
      , (".org", readOrg)
      , (".tex", readLaTeX)
      ]

mkDoc :: Path Rel File -> Pandoc -> Document Pandoc
mkDoc f v = Document f v $ getMetadata v

getMetadata :: Pandoc -> Maybe Value
getMetadata (Pandoc meta _) = flattenMeta meta

-- | Flatten a Pandoc 'Meta' into a well-structured JSON object.
--
-- Renders Pandoc text objects into plain strings along the way.
flattenMeta :: Meta -> Maybe Value
flattenMeta (Meta meta) = if null meta then Nothing else Just (toJSON $ fmap go meta)
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
