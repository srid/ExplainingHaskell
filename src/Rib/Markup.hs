{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Rib.Markup
  ( -- * Type class
    IsMarkup (..),
    Markup (..),
  )
where

import Data.Aeson (Value)
import Lucid (Html)
import Named
import Path
import Text.MMark (MMark)
import Text.Pandoc (Pandoc)

-- A light-weight markup document structure
data Markup doc where
  Markup_Pandoc :: Markup Pandoc
  Markup_MMark :: Markup MMark

-- | Class for denoting Markup representations.
--
-- See `Rib.Markup.Pandoc` and `Rib.Markup.MMark` for two available instances.
class IsMarkup repr where

  -- | Parse the given markup text
  parseDoc ::
    -- | File path, used to identify the document only.
    Path Rel File ->
    -- | Markup text to parse
    Text ->
    Either Text repr

  -- | Like `parseDoc` but take the actual filepath instead of text.
  readDoc ::
    forall m b.
    MonadIO m =>
    -- | File path, used to identify the document only.
    "relpath" :! Path Rel File ->
    -- | Actual path to the file to parse.
    "path" :! Path b File ->
    m (Either Text repr)

  extractMeta ::
    repr ->
    Maybe (Either Text Value)

  -- | Render the document as Lucid HTML
  renderDoc ::
    repr ->
    Either Text (Html ())
