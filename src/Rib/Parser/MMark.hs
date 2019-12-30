{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}

module Rib.Parser.MMark
  ( -- * Parsing
    parsePure,
    parseIO,

    -- * Rendering
    render,

    -- * Extracting information
    getFirstImg,
    projectYaml,

    -- * Re-exports
    MMark,
  )
where

import Control.Foldl (Fold (..))
import Lucid (Html)
import Path
import Text.MMark (MMark, projectYaml)
import qualified Text.MMark as MMark
import qualified Text.MMark.Extension as Ext
import qualified Text.MMark.Extension.Common as Ext
import qualified Text.Megaparsec as M
import Text.URI (URI)

-- | Render a MMark document as HTML
render :: MMark -> Html ()
render = MMark.render

parsePure :: FilePath -> Text -> Either Text MMark
parsePure k s = case MMark.parse k s of
  Left e -> Left $ toText $ M.errorBundlePretty e
  Right doc -> Right $ MMark.useExtensions exts $ useTocExt doc

parseIO :: MonadIO m => Path Rel File -> Text -> m (Either Text MMark)
parseIO k s = pure $ parsePure (toFilePath k) s

-- | Get the first image in the document if one exists
getFirstImg :: MMark -> Maybe URI
getFirstImg = flip MMark.runScanner $ Fold f Nothing id
  where
    f acc blk = acc <|> listToMaybe (mapMaybe getImgUri (inlinesContainingImg blk))
    getImgUri = \case
      Ext.Image _ uri _ -> Just uri
      _ -> Nothing
    inlinesContainingImg :: Ext.Bni -> [Ext.Inline]
    inlinesContainingImg = \case
      Ext.Naked xs -> toList xs
      Ext.Paragraph xs -> toList xs
      _ -> []

exts :: [MMark.Extension]
exts =
  [ Ext.fontAwesome,
    Ext.footnotes,
    Ext.kbd,
    Ext.linkTarget,
    Ext.mathJax (Just '$'),
    Ext.obfuscateEmail "protected-email",
    Ext.punctuationPrettifier,
    Ext.ghcSyntaxHighlighter,
    Ext.skylighting
  ]

useTocExt :: MMark -> MMark
useTocExt doc = MMark.useExtension (Ext.toc "toc" toc) doc
  where
    toc = MMark.runScanner doc $ Ext.tocScanner (\x -> x > 1 && x < 5)
