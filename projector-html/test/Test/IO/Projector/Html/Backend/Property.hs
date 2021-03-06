{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TupleSections #-}
module Test.IO.Projector.Html.Backend.Property where

import           Control.Monad.IO.Class (MonadIO (..))

import qualified Data.List as L
import qualified Data.Text as T
import qualified Data.Text.IO as T

import           Hedgehog

import           Projector.Core.Prelude

import           Projector.Core
import           Projector.Html.Data.Annotation
import           Projector.Html.Data.Module
import qualified Projector.Html.Data.Prim as Prim
import qualified Projector.Html.Core.Library as Lib

import           System.Directory (createDirectoryIfMissing, makeAbsolute)
import           System.Exit (ExitCode(..))
import           System.FilePath.Posix ((</>), takeDirectory)
import           System.IO (FilePath, IO)
import           System.IO.Temp (withTempDirectory)


processProp :: ([Char] -> PropertyT IO ()) -> (ExitCode, [Char], [Char]) -> PropertyT IO ()
processProp f (code, out, err) =
  case code of
    ExitSuccess ->
      f out
    ExitFailure i ->
      let errm = L.unlines [
              "Process exited with failing status: " <> T.unpack (renderIntegral i)
            , err
            ]
      in annotate errm >> failure


fileProp :: FilePath -> Text -> (FilePath -> IO a) -> (a -> PropertyT IO ()) -> PropertyT IO ()
fileProp mname modl f g = do
  a <- liftIO $ withTempDirectory "./dist/" "gen-XXXXXX" $ \tmpDir -> do
    let path = tmpDir </> mname
        dir = takeDirectory path
    createDirectoryIfMissing True dir
    T.writeFile path modl
    path' <- makeAbsolute path
    f path'
  g a


helloWorld :: (Name, ModuleExpr (Maybe Prim.HtmlType) Prim.PrimT (Annotation a))
helloWorld =
  ( Name "helloWorld"
  , ModuleExpr
      (Just Lib.tHtml)
      (fmap (const EmptyAnnotation) $ ECon () (Constructor "Nested") Lib.nHtml [
        EList () [
            ECon () (Constructor "Plain") Lib.nHtml [ELit () (Prim.VString "Hello, ")]
          , EApp () (EVar () Lib.nHtmlText) (ELit () (Prim.VString "world!"))
          , ECon () (Constructor "Element") Lib.nHtml [
                ECon () (Constructor "Tag") Lib.nTag [ELit () (Prim.VString "div")]
              , EList () [
                    ECon () (Constructor "Attribute") Lib.nAttribute [
                      ECon () (Constructor "AttributeKey") Lib.nAttributeKey [ELit () (Prim.VString "class")]
                    , EApp () (EVar () Lib.nHtmlAttrValue) (ELit () (Prim.VString "table"))
                    ]
                  ]
              , ECon () (Constructor "Nested") Lib.nHtml [EList () []]
              ]
          , EVar () Lib.nHtmlBlank
          ]
        ]
  ))
