{-# LANGUAGE DeriveTraversable, ExistentialQuantification, FlexibleContexts, FlexibleInstances, GeneralizedNewtypeDeriving, LambdaCase, MultiParamTypeClasses, OverloadedLists, OverloadedStrings, QuantifiedConstraints, StandaloneDeriving, TypeOperators, UndecidableInstances #-}
module Data.Name
( User
, Namespaced
, Name(..)
, reservedNames
, isSimpleCharacter
, needsQuotation
, Gensym(..)
, (//)
, gensym
, namespace
, Naming(..)
, runNaming
, NamingC(..)
, Incr(..)
, incr
, bind
, instantiate
) where

import           Control.Applicative
import           Control.Effect
import           Control.Effect.Carrier
import           Control.Effect.Reader
import           Control.Effect.State
import           Control.Effect.Sum
import           Control.Monad ((>=>))
import           Control.Monad.Fail
import           Control.Monad.IO.Class
import qualified Data.Char as Char
import           Data.Function (on)
import           Data.HashSet (HashSet)
import qualified Data.HashSet as HashSet
import           Data.Text as Text (Text, any, unpack)
import           Data.Text.Prettyprint.Doc (Pretty (..))
import qualified Data.Text.Prettyprint.Doc as Pretty

-- | User-specified and -relevant names.
type User = Text

-- | The type of namespaced actions, i.e. actions occurring within some outer name.
--
--   This corresponds to the @Agent@ type synonym described in /I Am Not a Number—I Am a Free Variable/.
type Namespaced a = Gensym -> a

data Name
  -- | A locally-bound, machine-generatable name.
  --
  --   This should be used for locals, function parameters, and similar names which can’t escape their defining scope.
  = Gen Gensym
  -- | A name provided by a user.
  --
  --   This should be used for names which the user provided and which other code (other functions, other modules, other packages) could call, e.g. declaration names.
  | User User
  deriving (Eq, Ord, Show)

instance Pretty Name where
  pretty = \case
    Gen p  -> pretty p
    User n -> pretty n

reservedNames :: HashSet String
reservedNames = [ "#true", "#false", "let", "#frame", "if", "then", "else"
                , "lexical", "import", "#unit", "load"]

-- | Returns true if any character would require quotation or if the
-- name conflicts with a Core primitive.
needsQuotation :: User -> Bool
needsQuotation u = HashSet.member (unpack u) reservedNames || Text.any (not . isSimpleCharacter) u

-- | A ‘simple’ character is, loosely defined, a character that is compatible
-- with identifiers in most ASCII-oriented programming languages. This is defined
-- as the alphanumeric set plus @$@ and @_@.
isSimpleCharacter :: Char -> Bool
isSimpleCharacter = \case
  '$'  -> True -- common in JS
  '_'  -> True
  '?'  -> True -- common in Ruby
  c    -> Char.isAlphaNum c

data Gensym
  = Root Text
  | Gensym :/ (Text, Int)
  deriving (Eq, Ord, Show)

instance Pretty Gensym where
  pretty = \case
    Root s      -> pretty s
    p :/ (n, x) -> Pretty.hcat [pretty p, "/", pretty n, "^", pretty x]

(//) :: Gensym -> Text -> Gensym
root // s = root :/ (s, 0)

infixl 6 //


gensym :: (Carrier sig m, Member Naming sig) => Text -> m Gensym
gensym s = send (Gensym s pure)

namespace :: (Carrier sig m, Member Naming sig) => Text -> m a -> m a
namespace s m = send (Namespace s m pure)


data Naming m k
  = Gensym Text (Gensym -> k)
  | forall a . Namespace Text (m a) (a -> k)

deriving instance Functor (Naming m)

instance HFunctor Naming where
  hmap _ (Gensym    s   k) = Gensym    s       k
  hmap f (Namespace s m k) = Namespace s (f m) k

instance Effect Naming where
  handle state handler (Gensym    s   k) = Gensym    s                        (handler . (<$ state) . k)
  handle state handler (Namespace s m k) = Namespace s (handler (m <$ state)) (handler . fmap k)


runNaming :: Functor m => Gensym -> NamingC m a -> m a
runNaming root = runReader root . evalState 0 . runNamingC

newtype NamingC m a = NamingC { runNamingC :: StateC Int (ReaderC Gensym m) a }
  deriving (Alternative, Applicative, Functor, Monad, MonadFail, MonadIO)

instance (Carrier sig m, Effect sig) => Carrier (Naming :+: sig) (NamingC m) where
  eff (L (Gensym    s   k)) = NamingC (StateC (\ i -> (:/ (s, i)) <$> ask >>= runState (succ i) . runNamingC . k))
  eff (L (Namespace s m k)) = NamingC (StateC (\ i -> local (// s) (evalState 0 (runNamingC m)) >>= runState i . runNamingC . k))
  eff (R other)             = NamingC (eff (R (R (handleCoercible other))))


data Incr a
  = Z
  | S a
  deriving (Eq, Foldable, Functor, Ord, Show, Traversable)

instance Applicative Incr where
  pure = S
  Z   <*> _ = Z
  S f <*> a = f <$> a

instance Monad Incr where
  Z   >>= _ = Z
  S a >>= f = f a

match :: (Applicative f, Eq a) => a -> a -> Incr (f a)
match x y | x == y    = Z
          | otherwise = S (pure y)

fromIncr :: a -> Incr a -> a
fromIncr a = incr a id

incr :: b -> (a -> b) -> Incr a -> b
incr z s = \case { Z -> z ; S a -> s a }


newtype Scope f a = Scope { unScope :: f (Incr (f a)) }
  deriving (Foldable, Functor, Traversable)

instance (Eq   a, forall a . Eq   a => Eq   (f a), Monad f) => Eq   (Scope f a) where
  (==) = (==) `on` (unScope >=> sequenceA)

instance (Ord  a, forall a . Eq   a => Eq   (f a)
                , forall a . Ord  a => Ord  (f a), Monad f) => Ord  (Scope f a) where
  compare = compare `on` (unScope >=> sequenceA)

deriving instance (Show a, forall a . Show a => Show (f a)) => Show (Scope f a)

instance Applicative f => Applicative (Scope f) where
  pure = Scope . pure . S . pure
  Scope f <*> Scope a = Scope (liftA2 (liftA2 (<*>)) f a)

instance Monad f => Monad (Scope f) where
  Scope e >>= f = Scope (e >>= incr (pure Z) (>>= unScope . f))


-- | Bind occurrences of a variable in a term, producing a term in which the variable is bound.
bind :: (Applicative f, Eq a) => a -> f a -> f (Incr (f a))
bind name = fmap (match name)

-- | Substitute a term for the free variable in a given term, producing a closed term.
instantiate :: Monad f => f a -> f (Incr (f a)) -> f a
instantiate t b = b >>= fromIncr t
