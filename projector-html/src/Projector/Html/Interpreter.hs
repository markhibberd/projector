{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Projector.Html.Interpreter (
    Html (..)
  , Attribute (..)
  ---
  , InterpretError (..)
  , interpret
  , eval
  ) where


import           Data.Map (Map)

import           Projector.Core.Prelude

import qualified Projector.Core.Eval as Eval
import qualified Projector.Core.Rewrite as Rewrite
import           Projector.Core.Syntax
import           Projector.Core.Type
import qualified Projector.Html.Backend.Rewrite as Rewrite
import           Projector.Html.Core
import qualified Projector.Html.Core.Library as Lib
import qualified Projector.Html.Core.Prim as Prim
import           Projector.Html.Data.Annotation
import           Projector.Html.Data.Prim

import qualified Umami.Monad.FixT as U


data Html =
    Plain !Text
  | Raw !Text
  | Comment !Text
  | Element !Text ![Attribute] !Html
  | VoidElement !Text ![Attribute]
  | Nested ![Html]
  deriving (Eq, Show)

instance Monoid Html where
  mempty =
    Nested mempty
  mappend h1 h2 =
    let
      nested hs =
        case hs of
          h : [] ->
            h
          _ ->
            Nested hs
    in
      case (h1, h2) of
        (Nested n1, Nested n2) ->
          nested (n1 <> n2)
        (Nested n1, _) ->
          nested (n1 <> [h2])
        (_, Nested n2) ->
          nested (h1 : n2)
        _ ->
          Nested [h1, h2]

data Attribute =
  Attribute !Text !Text
  deriving (Eq, Show)

data InterpretError a =
  InterpretInvalidExpression (HtmlExpr a)
  deriving (Eq, Show)

-- -----------------------------------------------------------------------------

interpret ::
     HtmlDecls
  -> Map Name (HtmlExpr (HtmlType, SrcAnnotation))
  -> HtmlExpr (HtmlType, SrcAnnotation)
  -> Either (InterpretError (HtmlType, SrcAnnotation)) Html
interpret decls bnds =
  let confuns = constructorFunctionExprs decls in
  interpret' . eval (confuns <> bnds)

eval ::
     Map Name (HtmlExpr (HtmlType, SrcAnnotation))
  -> HtmlExpr (HtmlType, SrcAnnotation)
  -> HtmlExpr (HtmlType, SrcAnnotation)
eval bnds =
  nf . Eval.substitute bnds'
  where
    bnds' = fmap snd Lib.exprs <> fmap snd Prim.exprs <> bnds
    nf = fst . Eval.runEval (Eval.EvalState 0) . U.fixpoint
      (Eval.nf'' (Eval.fixpoint' (rewrite >=> Eval.beta >=> Eval.eta)))
    rewrite = flip Rewrite.applyRules Rewrite.globalRules

interpret' :: HtmlExpr a -> Either (InterpretError a) Html
interpret' e =
  case e of
    ECon _ c _ es ->
      case (c, es) of
        (Constructor "Plain", [t]) ->
           Plain <$> value t
        (Constructor "Raw", [t]) ->
           Raw <$> value t
        (Constructor "Comment", [t]) ->
           Comment <$> value t
        (Constructor "Element", [ECon _ (Constructor "Tag") _ [t], EList _ attrs, body]) -> do
           Element
             <$> value t
             <*> mapM attr attrs
             <*> interpret' body
        (Constructor "VoidElement", [ECon _ (Constructor "Tag") _ [t], EList _ attrs]) -> do
           VoidElement
             <$> value t
             <*> mapM attr attrs
        (Constructor "Nested", [EList _ nodes]) ->
          fmap mconcat . mapM interpret' $ nodes
        _ ->
          Left $ InterpretInvalidExpression e
    EApp _ _ _ ->
      Left $ InterpretInvalidExpression e
    ELam _ _ _ _ ->
      Left $ InterpretInvalidExpression e
    ECase _ _ _ ->
      Left $ InterpretInvalidExpression e
    ERec _ _ _ ->
      Left $ InterpretInvalidExpression e
    EPrj _ _ _ ->
      Left $ InterpretInvalidExpression e
    EList _ _ ->
      Left $ InterpretInvalidExpression e
    EMap _ _ _ ->
      Left $ InterpretInvalidExpression e
    ELit _ _ ->
      Left $ InterpretInvalidExpression e
    EVar _ _ ->
      Left $ InterpretInvalidExpression e
    EForeign _ _ _ ->
      Left $ InterpretInvalidExpression e
    EHole _ ->
      Left $ InterpretInvalidExpression e

-- | Guaranteed to return text, not html
value :: HtmlExpr a -> Either (InterpretError a) Text
value e =
  case e of
    ELit _ (VString v) ->
      pure v
    _ ->
      Left $ InterpretInvalidExpression e

attr :: HtmlExpr a -> Either (InterpretError a) Attribute
attr e =
  case e of
    ECon _ (Constructor "Attribute") _ [ECon _ (Constructor "AttributeKey") _ [ELit _ (VString k)], ECon _ (Constructor "AttributeValue") _ [v]] ->
      Attribute k <$> value v
    _ ->
      Left $ InterpretInvalidExpression e
