{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- TODo: What if I make this literate haskell thus blog post?
module Main where

import Prelude hiding (div, init, last, (**))

import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (concurrently_)
import Control.Lens (at, (?~))
import Control.Monad (forM_, forever, guard, void, when)
import Control.Monad.IO.Class (liftIO)
import Data.Aeson (FromJSON, ToJSON)
import qualified Data.Aeson as Aeson
import Data.Aeson.Lens (_Object)
import Data.Bool (bool)
import qualified Data.ByteString.Char8 as BS8
import Data.List (isSuffixOf, partition)
import qualified Data.Map as Map
import Data.Maybe (fromMaybe)
import qualified Data.Text as T
import qualified Data.Text.Lazy as TL
import GHC.Generics (Generic)
import System.Environment (withArgs)

import Network.Wai.Application.Static (defaultFileServerSettings, ssLookupFile, staticApp)
import qualified Network.Wai.Handler.Warp as Warp
import Safe (initMay, lastMay)
import System.Console.CmdArgs (Data, Typeable, auto, cmdArgs, help, modes, (&=))
import System.FSNotify (watchTree, withManager)
import WaiAppStatic.Types (LookupResult (..), Pieces, StaticSettings, fromPiece, unsafeToPiece)

import Development.Shake (Action, Rebuild (..), Verbosity (Chatty), copyFileChanged, getDirectoryFiles, need,
                          readFile', shakeArgs, shakeOptions, shakeRebuild, shakeVerbosity, want, writeFile',
                          (%>), (|%>), (~>))
import Development.Shake.Classes (Binary, Hashable, NFData)
import Development.Shake.FilePath (dropDirectory1, dropExtension, (-<.>), (</>))
import Slick (convert, jsonCache', markdownToHTML)

-- | HTML & CSS imports
import Clay (Css, article, block, body, center, code, color, darkviolet, display, div, fontFamily, footer, h1,
             h2, h3, h4, h5, h6, img, marginLeft, marginRight, monospace, pct, pre, render, sansSerif,
             textAlign, width, ( # ), (**), (?))
import qualified Clay as Clay
import Reflex.Dom.Core hiding (Link, Space, def, display)
import Text.Pandoc


data App
  = Watch
  | Serve { port :: Int, watch :: Bool }
  | Generate { force :: Bool }
  deriving (Data,Typeable,Show,Eq)

cli :: App
cli = modes
  [ Watch
      &= help "Watch for changes and generate"
  , Serve
      { port = 8080 &= help "Port to bind to"
      , watch = False &= help "Watch in addition to serving generated files"
      } &= help "Serve the generated site"
  , Generate
      { force = False &= help "Force generation of all files"
      } &= help "Generate the site"
        &= auto  -- | Generate is the default command.
  ]

-- | WAI Settings suited for serving statically generated websites.
staticSiteServerSettings :: FilePath -> StaticSettings
staticSiteServerSettings root = settings { ssLookupFile = lookupFileForgivingHtmlExt }
  where
    settings = defaultFileServerSettings root

    -- | Like upstream's `ssLookupFile` but ignores the ".html" suffix in the
    -- URL when looking up the corresponding file in the filesystem.
    --
    -- This allows "clean urls" so to speak.
    lookupFileForgivingHtmlExt :: Pieces -> IO LookupResult
    lookupFileForgivingHtmlExt pieces = ssLookupFile settings pieces >>= \case
      LRNotFound -> ssLookupFile settings (addHtmlExt pieces)
      x -> pure x

    -- | Add the ".html" suffix to the URL unless it already exists
    addHtmlExt :: Pieces -> Pieces
    addHtmlExt xs = fromMaybe xs $ do
      init <- fmap fromPiece <$> initMay xs
      last <- fromPiece <$> lastMay xs
      guard $ not $ ".html" `isSuffixOf` T.unpack last
      pure $ fmap unsafeToPiece $ init <> [last <> ".html"]

destDir :: FilePath
destDir = "generated"

contentDir :: FilePath
contentDir = "site"

main :: IO ()
main = runApp =<< cmdArgs cli

runApp :: App -> IO ()
runApp = \case
  Watch -> withManager $ \mgr -> do
    -- Begin with a *full* generation as the HTML layout may have been changed.
    runApp $ Generate True
    -- And then every time a file changes under the content directory.
    void $ watchTree mgr contentDir (const True) $ const $ runApp $ Generate False
    -- Wait forever, effectively.
    (_,bs) <- renderStatic $ do
      el "p" $ text "hello world"
    BS8.putStrLn bs
    forever $ threadDelay maxBound

  Serve p w -> concurrently_
    (when w $ runApp Watch)
    (putStrLn ("Serving at " <> show p) >> Warp.run p (staticApp $ staticSiteServerSettings destDir))

  Generate forceGen -> withArgs [] $ do
    -- ^ The withArgs above is to ensure that our own app arguments is not
    -- confusing Shake.
    let opts = shakeOptions
          { shakeVerbosity = Chatty
          , shakeRebuild = bool [] [(RebuildNow, "**")] forceGen
          }
    shakeArgs opts $ do
      -- TODO: Understand how this works. The caching from Slick.
      getPostCached <- jsonCache' getPost

      want ["site"]

      -- Require all the things we need to build the whole site
      "site" ~>
        need ["static", "posts", destDir </> "index.html"]

      let staticFilePatterns = ["css//*", "js//*", "images//*"]
          -- ^ Which files are considered to be static files.
          postFilePatterns = ["*.md"]
          -- ^ Which files are considered to be post files

      -- Require all static assets
      "static" ~> do
        need . fmap (destDir </>) =<< getDirectoryFiles contentDir staticFilePatterns

      -- Rule for handling static assets, just copy them from source to dest
      (destDir </>) <$> staticFilePatterns |%> \out ->
        copyFileChanged (destToSrc out) out

      -- Find and require every post to be built
      "posts" ~> do
        need . fmap ((destDir </>) . (-<.> "html")) =<< getDirectoryFiles contentDir postFilePatterns

      -- build the main table of contents
      (destDir </> "index.html") %> \out -> do
        posts <- traverse (getPostCached . PostFilePath . (contentDir </>)) =<< getDirectoryFiles contentDir postFilePatterns
        html <- liftIO $ renderHTML $ pageHTML $ Page_Index posts
        writeFile' out $ BS8.unpack html

      -- rule for actually building posts
      (destDir </> "*.html") %> \out -> do
        post <- getPost$ PostFilePath $ destToSrc out -<.> "md"
        html <- liftIO $ renderHTML $ pageHTML $ Page_Post post
        writeFile' out $ BS8.unpack html

  where
    -- | Read and parse a Markdown post
    getPost :: PostFilePath -> Action Post
    getPost (PostFilePath postPath) = do
      -- | Given a post source-file's file path as a cache key, load the Post object
      -- for it. This is used with 'jsonCache' to provide post caching.
      let srcPath = destToSrc postPath -<.> "md"
      m <- T.pack <$> readFile' srcPath
      postData <- markdownToHTML m
      let pm = either (error . show) id $ runPure $ readMarkdown markdownOptions m
      let postURL = T.pack $ srcToURL postPath
          withURL = _Object . at "url" ?~ Aeson.String postURL
          withMdContent = _Object . at "pandocDoc" ?~ Aeson.toJSON pm
          withSrc = _Object . at "srcPath" ?~ Aeson.String (T.pack srcPath)
      convert $ withSrc $ withURL $ withMdContent postData

-- | Represents a HTML page that will be generated
data Page
  = Page_Index [Post]
  | Page_Post Post
  deriving (Generic, Show, FromJSON, ToJSON)

-- TODO: Tell Shake to regenerate when this function changes. How??
pageHTML :: DomBuilder t m => Page -> m ()
pageHTML page = do
  let pageTitle = case page of
        Page_Index _ -> "Srid's notes"
        Page_Post post -> T.pack $ title post
  el "head" $ do
    elMeta "description" "Sridhar's notes"
    elMeta "author" "Sridhar Ratnakumar"
    elMeta "viewport" "width=device-width, initial-scale=1"
    el "title" $ text pageTitle
    elAttr "style" ("type" =: "text/css") $ text $ TL.toStrict $ render siteStyle
    elAttr "link" ("rel" =: "stylesheet" <> "href" =: semUiCdn) blank
  el "body" $ do
    elAttr "div" ("class" =: "ui text container" <> "id" =: "thesite") $ do
      el "br" blank
      divClass "ui raised segment" $ do
        elAttr "a" ("class" =: "ui violet ribbon label" <> "href" =: "/") $ text "Srid's notes"

        elClass "h1" "ui huge header" $ text pageTitle
        case page of
          Page_Index posts -> do
            let (progPosts, otherPosts) = partition ((== Just Programming) . category) posts
            elClass "h2" "ui header" $ text "Haskell & Nix notes"
            postList progPosts
            elClass "h2" "ui header" $ text "Other notes"
            postList otherPosts
          Page_Post post -> do
            elClass "article" "post" $
              -- TODO: code syntax highlighting
              pandocHTML $ pandocDoc post

        elAttr "a" ("class" =: "ui green right ribbon label" <> "href" =: "https://www.srid.ca") $ text "Sridhar Ratnakumar"
    el "br" blank
    el "br" blank
    elLinkGoogleFont "Open+Sans"
    elLinkGoogleFont "Comfortaa"
    elLinkGoogleFont "Roboto+Mono"
  where
    semUiCdn = "https://cdn.jsdelivr.net/npm/semantic-ui@2.4.2/dist/semantic.min.css"
    elLinkGoogleFont name =
      elAttr "link" ("href" =: fontUrl <> "rel" =: "stylesheet" <> "type" =: "text/css") blank
      where
        fontUrl = "https://fonts.googleapis.com/css?family=" <> name
    elMeta k v = elAttr "meta" ("name" =: k <> "content" =: v) blank
    postList ps = divClass "ui relaxed divided list" $ forM_ ps $ \p -> do
      divClass "item" $ do
        elAttr "a" ("class" =: "header" <> "href" =: T.pack (url p)) $ text $ T.pack $ title p
        el "small" $ text $ T.pack $ description p


pandocHTML :: DomBuilder t m => Pandoc -> m ()
pandocHTML (Pandoc _meta blocks) = renderBlocks blocks
  where
    renderBlocks = mapM_ renderBlock
    renderBlock = \case
      Plain inlines -> renderInlines inlines
      Para xs -> el "p" $ renderInlines xs
      LineBlock xss -> forM_ xss $ \xs -> do
        renderInlines xs
        text "\n"
      CodeBlock attr x -> elPandocAttr "code" attr $ el "pre" $ text $ T.pack x
      v@(RawBlock _ _) -> notImplemented v
      BlockQuote xs -> el "blockquote" $ renderBlocks xs
      OrderedList lattr xss -> el "ol" $ do
        notImplemented lattr
        forM_ xss $ \xs -> el "li" $ renderBlocks xs
      BulletList xss -> el "ul" $ forM_ xss $ \xs -> el "li" $ renderBlocks xs
      DefinitionList defs -> el "dl" $ forM_ defs $ \(term, descList) -> do
        el "dt" $ renderInlines term
        forM_ descList $ \desc ->
          el "dd" $ renderBlocks desc
      Header level attr xs -> elPandocAttr (headerElement level) attr $ do
        renderInlines xs
      HorizontalRule -> el "hr" blank
      v@(Table _ _ _ _ _) -> notImplemented v
      Div attr xs -> elPandocAttr "div" attr $
        renderBlocks xs
      Null -> blank
    elPandocAttr name = elAttr name . renderAttr
    renderAttr (identifier, classes, attrs) =
         "id" =: T.pack identifier
      <> "class" =: T.pack (unwords classes)
      <> Map.fromList ((\(x,y) -> (T.pack x, T.pack y)) <$> attrs)
    headerElement level = case level of
      1 -> "h1"
      2 -> "h2"
      3 -> "h3"
      4 -> "h4"
      5 -> "h5"
      6 -> "h6"
      _ -> error "bad header level"
    renderInlines = mapM_ renderInline
    renderInline = \case
      Str x -> text $ T.pack x
      Emph xs -> el "em" $ renderInlines xs
      Strong xs -> el "strong" $ renderInlines xs
      Strikeout xs -> el "strike" $ renderInlines xs
      Superscript xs -> el "sup" $ renderInlines xs
      Subscript xs -> el "sub" $ renderInlines xs
      SmallCaps xs -> el "small" $ renderInlines xs
      v@(Quoted _qt _xs) -> notImplemented v
      v@(Cite _ _) -> notImplemented v
      Code attr x -> elPandocAttr "code" attr $
        text $ T.pack x
      Space -> text " " -- TODO: Reevaluate this.
      SoftBreak -> text " "
      LineBreak -> notImplemented LineBreak
      v@(Math _ _) -> notImplemented v
      v@(RawInline _ _) -> notImplemented v
      Link attr xs (lUrl, lTitle) -> do
        let attr' = renderAttr attr <> ("href" =: T.pack lUrl <> "title" =: T.pack lTitle)
        elAttr "a" attr' $ renderInlines xs
      Image attr xs (iUrl, iTitle) -> do
        let attr' = renderAttr attr <> ("src" =: T.pack iUrl <> "title" =: T.pack iTitle)
        elAttr "img" attr' $ renderInlines xs
      Note xs -> el "aside" $ renderBlocks xs
      Span attr xs -> elPandocAttr "span" attr $
        renderInlines xs
    notImplemented :: (DomBuilder t m, Show a) => a -> m ()
    notImplemented x = do
      el "strong" $ text "NOTIMPL"
      el "tt" $ text $ T.pack $ show x

renderHTML :: StaticWidget x a -> IO BS8.ByteString
renderHTML = fmap snd . renderStatic

siteStyle :: Css
siteStyle = body ? do
  div # "#thesite" ? do
    fontFamily ["Open Sans"] [sansSerif]
    forM_ [h1, h2, h3, h4, h5, h6, ".header"] $ \header -> header ?
      fontFamily ["Comfortaa"] [sansSerif]
    forM_ [pre, code, "tt"] $ \s -> s ?
      fontFamily ["Roboto Mono"] [monospace]
    h1 ? textAlign center
    (article ** h2) ? color darkviolet
    (article ** img) ? do
      display block
      marginLeft Clay.auto
      marginRight Clay.auto
      width $ pct 50
    footer ? textAlign center


-- | Reasonable options for reading a markdown file
markdownOptions :: ReaderOptions
markdownOptions = def { readerExtensions = exts }
 where
  exts = mconcat
    [ extensionsFromList
      [ Ext_yaml_metadata_block
      , Ext_fenced_code_attributes
      , Ext_auto_identifiers
      ]
    , githubMarkdownExtensions
    ]

-- | Represents the template dependencies of the index page
-- TODO: Represent category of posts generically. dependent-map?
data IndexInfo = IndexInfo
  { programming_posts :: [Post]
  , other_posts :: [Post]
  } deriving (Generic, Show)

instance FromJSON IndexInfo
instance ToJSON IndexInfo

data PostCategory
  = Programming
  | Other
  deriving (Generic, Show, Eq, Ord)

instance FromJSON PostCategory
instance ToJSON PostCategory

-- | A JSON serializable representation of a post's metadata
-- TODO: Use Text instead of String
data Post = Post
  { title :: String
  , description :: String
  , category :: Maybe PostCategory
  , content :: String
  , pandocDoc :: Pandoc
  , url :: String
  } deriving (Generic, Eq, Ord, Show)

instance FromJSON Post
instance ToJSON Post


-- A simple wrapper data-type which implements 'ShakeValue';
-- Used as a Shake Cache key to build a cache of post objects.
newtype PostFilePath = PostFilePath FilePath
  deriving (Show, Eq, Hashable, Binary, NFData, Generic)

-- | convert 'build' filepaths into source file filepaths
destToSrc :: FilePath -> FilePath
destToSrc p = "site" </> dropDirectory1 p

-- | convert a source file path into a URL
srcToURL :: FilePath -> String
srcToURL = ("/" ++) . dropDirectory1 . dropExtension
