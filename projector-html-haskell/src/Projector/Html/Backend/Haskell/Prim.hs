{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeFamilies #-}
module Projector.Html.Backend.Haskell.Prim (
    HaskellPrimT (..)
  , Value (..)
  , toHaskellExpr
  , toHaskellModule
  , toHaskellTypeDecls
  , HaskellType
  , HaskellExpr
  , HaskellModule
  , HaskellDecl
  , HaskellDecls
  ) where


import qualified Data.Text as T

import           Projector.Core.Prelude

import           Projector.Core
import           Projector.Html.Data.Module
import           Projector.Html.Data.Prim


type HaskellType = Type HaskellPrimT
type HaskellExpr = Expr HaskellPrimT
type HaskellDecl = Decl HaskellPrimT
type HaskellDecls = TypeDecls HaskellPrimT
type HaskellModule = Module HaskellType HaskellPrimT

data HaskellPrimT
  = HTextT
  deriving (Eq, Ord, Enum, Bounded, Read, Show)

instance Ground HaskellPrimT where
  data Value HaskellPrimT
    = HTextV Text
    deriving (Eq, Ord, Read, Show)

  typeOf v = case v of
    HTextV _ -> HTextT

  ppGroundType t = case t of
    HTextT -> "Projector.Html.Runtime.Text"

  ppGroundValue v = case v of
    HTextV s ->
      T.pack (show s)


toHaskellExpr :: Expr PrimT a -> Expr HaskellPrimT a
toHaskellExpr =
  mapGround tmap vmap

toHaskellModule :: Module HtmlType PrimT a -> Module HaskellType HaskellPrimT a
toHaskellModule (Module typs imps exps) =
  Module
    (toHaskellTypeDecls typs)
    imps
    (with exps (\(ModuleExpr t e) -> ModuleExpr (toHaskellType t) (toHaskellExpr e)))

toHaskellType :: HtmlType -> HaskellType
toHaskellType =
  swapLibTypes . mapGroundType tmap
{-# INLINE toHaskellType #-}

toHaskellTypeDecls :: HtmlDecls -> HaskellDecls
toHaskellTypeDecls (TypeDecls decls) =
  TypeDecls . with decls $ \decl ->
    case decl of
      DVariant ps cts ->
        DVariant ps (with cts (fmap (fmap toHaskellType)))
      DRecord ps fts ->
        DRecord ps (with fts (fmap toHaskellType))

-- if we encounter library types we also have to tweak them
swapLibTypes :: HaskellType -> HaskellType
swapLibTypes ty =
  case ty of
    TList t2 ->
      TList (swapLibTypes t2)
    TArrow t2 t3 ->
      TArrow (swapLibTypes t2) (swapLibTypes t3)
    TApp t2 t3 ->
      TApp (swapLibTypes t2) (swapLibTypes t3)
    TVar (TypeName "Html") ->
      TVar (TypeName "Projector.Html.Runtime.Html")
    TVar (TypeName "Attribute") ->
      TVar (TypeName "Projector.Html.Runtime.Attribute")
    TVar (TypeName "AttributeKey") ->
      TVar (TypeName "Projector.Html.Runtime.AttributeKey")
    TVar (TypeName "AttributeValue") ->
      TVar (TypeName "Projector.Html.Runtime.AttributeValue")
    TVar (TypeName "Tag") ->
      TVar (TypeName "Projector.Html.Runtime.Tag")
    TVar (TypeName "Bool") ->
      TVar (TypeName "Projector.Html.Runtime.Bool")
    TVar (TypeName "Maybe") ->
      TVar (TypeName "Projector.Html.Runtime.Maybe")
    TVar (TypeName "Either") ->
      TVar (TypeName "Projector.Html.Runtime.Either")
    _ ->
      ty
{-# INLINE swapLibTypes #-}

tmap :: PrimT -> HaskellPrimT
tmap prim =
  case prim of
    TString -> HTextT
{-# INLINE tmap #-}

vmap :: Value PrimT -> Value HaskellPrimT
vmap val =
  case val of
    VString t -> HTextV t
{-# INLINE vmap #-}
