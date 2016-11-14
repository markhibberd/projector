{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
module Projector.Core.Termination (
    TerminationError (..)
  , positivityCheck
  ) where


import           Data.Map.Strict as M

import           P

import           Projector.Core.Type


data TerminationError l
  = PositivityCheckFailed (Type l) (Type l)
  deriving (Eq, Ord, Show)

data Polarity = Pos | Neg

pflip :: Polarity -> Polarity
pflip p =
  case p of
    Pos -> Neg
    Neg -> Pos

-- | Ensure datatypes are only used recursively in positive position.
--
-- TODO use apE / listE family to accum errors
positivityCheck :: Ground l => TypeContext l -> Either (TerminationError l) ()
positivityCheck tc =
  let ctx = M.toList (unTypeContext tc)
  in traverse_ (uncurry (positivityCheck' Pos tc)) ctx

positivityCheck' ::
     Ground l
  => Polarity
  -> TypeContext l
  -> TypeName
  -> Type l
  -> Either (TerminationError l) ()
positivityCheck' pol tc tn ty =
  positivityCheck'' pol tc tn ty ty

positivityCheck'' ::
     Ground l
  => Polarity
  -> TypeContext l
  -> TypeName
  -> Type l
  -> Type l
  -> Either (TerminationError l) ()
positivityCheck'' pol tc tn ty have =
  let cont =
        case have of
          TArrow l r -> do
            positivityCheck'' (pflip pol) tc tn ty l
            positivityCheck'' pol tc tn ty r

          TVariant _ cts ->
            traverse_ (traverse_ (traverse_ (positivityCheck'' pol tc tn ty))) cts

          TLit _ ->
            pure ()

          TVar _ ->
            pure ()

  in case pol of
       Neg ->
         if | have == TVar tn -> Left (PositivityCheckFailed have ty)
            | have == ty -> Left (PositivityCheckFailed have ty)
            | otherwise -> cont
       Pos ->
         cont
