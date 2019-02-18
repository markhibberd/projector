{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE FlexibleContexts #-}
module Projector.Core.Type (
  -- * Types
  -- ** Interface
    Type (..)
  , pattern TLit
  , pattern TVar
  , pattern TArrow
  , pattern TList
  , pattern TForall
  , pattern TApp
  , mapGroundType
  , free
  , freeInType
  -- *** Type functor
  , TypeF (..)
  -- ** Declared types
  , Decl (..)
  , Ground (..)
  , TypeName (..)
  , Constructor (..)
  , FieldName (..)
  , TypeDecls (..)
  , declareType
  , lookupType
  , lookupConstructor
  , subtractTypes
  ) where


import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import           Data.Set (Set)
import qualified Data.Set as S

import           Projector.Core.Prelude


-- | Types.
newtype Type l = Type (TypeF l (Type l))
  deriving (Eq, Ord, Show)

pattern TLit :: l -> Type l
pattern TLit l = Type (TLitF l)

pattern TVar :: TypeName -> Type l
pattern TVar x = Type (TVarF x)

pattern TArrow :: Type l -> Type l -> Type l
pattern TArrow a b = Type (TArrowF a b)

pattern TList :: Type l -> Type l
pattern TList a = Type (TListF a)

pattern TForall :: [TypeName] -> Type l -> Type l
pattern TForall a b = Type (TForallF a b)

pattern TApp :: Type l -> Type l -> Type l
pattern TApp a b = Type (TAppF a b)

-- | Type functor.
data TypeF l a
  = TLitF l
  | TVarF TypeName
  | TArrowF a a
  | TListF a
  | TForallF [TypeName] a
  | TAppF a a
  deriving (Functor, Foldable, Traversable)

deriving instance (Eq l, Eq a) => Eq (TypeF l a)
deriving instance (Ord l, Ord a) => Ord (TypeF l a)
deriving instance (Show l, Show a) => Show (TypeF l a)

-- | Swap out the ground type.
mapGroundType :: Ground l => Ground m => (l -> m) -> Type l -> Type m
mapGroundType tmap (Type ty) =
  Type $ case ty of
    TLitF l ->
      TLitF (tmap l)

    TVarF tn ->
      TVarF tn

    TArrowF a b ->
      TArrowF (mapGroundType tmap a) (mapGroundType tmap b)

    TListF a ->
      TListF (mapGroundType tmap a)

    TForallF as bs ->
      TForallF as (mapGroundType tmap bs)

    TAppF a b ->
      TAppF (mapGroundType tmap a) (mapGroundType tmap b)

-- | Declared types.
data Decl l
  = DVariant [TypeName] [(Constructor, [Type l])]
  | DRecord [TypeName] [(FieldName, Type l)]
  deriving (Eq, Ord, Show)

free :: Decl l -> Set TypeName
free decl =
  case decl of
    DVariant bindings cs ->
      fold . with cs $ \(_, ts) ->
        S.fromList . mconcat . with ts $
          freeInType (S.fromList bindings)
    DRecord bindings fs ->
      S.fromList . mconcat . with fs $ \(_, t) ->
        freeInType (S.fromList bindings) t

freeInType :: Set TypeName -> Type l -> [TypeName]
freeInType bindings (Type t) =
  case t of
    TLitF _ ->
      []
    TVarF tn ->
      if S.member tn bindings then
        []
      else
        [tn]
    TArrowF a b ->
      freeInType bindings a <> freeInType bindings b
    TListF a ->
      freeInType bindings a
    TForallF as bs ->
      freeInType (bindings <> S.fromList as) bs
    TAppF a b ->
      freeInType bindings a <> freeInType bindings b

-- | The class of user-supplied primitive types.
class (Eq l, Ord l, Show l, Eq (Value l), Ord (Value l), Show (Value l)) => Ground l where
  data Value l
  typeOf :: Value l -> l
  ppGroundType :: l -> Text
  ppGroundValue :: Value l -> Text

-- | A type's name.
newtype TypeName = TypeName { unTypeName :: Text }
  deriving (Eq, Ord, Show)

-- | A constructor's name.
newtype Constructor  = Constructor { unConstructor :: Text }
  deriving (Eq, Ord, Show)

-- | A record field's name.
newtype FieldName = FieldName { unFieldName :: Text }
  deriving (Eq, Ord, Show)

-- | Type contexts.
newtype TypeDecls l = TypeDecls { unTypeDecls :: Map TypeName (Decl l) }
  deriving (Eq, Ord, Show)

instance Monoid (TypeDecls l) where
  mempty = TypeDecls mempty
  mappend x = TypeDecls . (mappend `on` unTypeDecls) x

declareType :: TypeName -> Decl l -> TypeDecls l -> TypeDecls l
declareType n t =
  TypeDecls . M.insert n t . unTypeDecls

lookupType :: TypeName -> TypeDecls l -> Maybe (Decl l)
lookupType n =
  M.lookup n . unTypeDecls

subtractTypes :: TypeDecls l -> TypeDecls l -> TypeDecls l
subtractTypes (TypeDecls m) (TypeDecls n) =
  TypeDecls (M.difference m n)

-- FIX recomputing this all the time really sucks
--     if this becomes a bottleneck, compute it during declareType
lookupConstructor :: Constructor -> TypeDecls l -> Maybe (TypeName, [TypeName], [Type l])
lookupConstructor con (TypeDecls m) =
  M.lookup con . M.fromList . mconcat . with (M.toList m) $ \(tn, dec) ->
    case dec of
      DVariant ps cts ->
        with cts $ \(c, ts) ->
          (c, (tn, ps, ts))
      DRecord ps fts ->
        [(Constructor (unTypeName tn), (tn, ps, fmap snd fts))]
