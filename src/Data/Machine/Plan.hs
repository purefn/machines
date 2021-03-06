{-# LANGUAGE CPP #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE UndecidableInstances #-}
#ifndef MIN_VERSION_mtl
#define MIN_VERSION_mtl(x,y,z) 0
#endif
-----------------------------------------------------------------------------
-- |
-- Module      :  Data.Machine.Plan
-- Copyright   :  (C) 2012-2013 Edward Kmett, Rúnar Bjarnason
-- License     :  BSD-style (see the file LICENSE)
--
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  provisional
-- Portability :  MPTCs
--
----------------------------------------------------------------------------
module Data.Machine.Plan
  (
  -- * Plans
    Plan(..)
  , yield
  , await
  , awaits
  , request
  ) where

import Control.Applicative
import Control.Category
import Control.Monad (ap, MonadPlus(..))
import Control.Monad.Trans.Class
import Control.Monad.IO.Class
import Control.Monad.State.Class
import Control.Monad.Reader.Class
import Data.Functor.Bind
import Data.Functor.Plus
import Data.Machine.Await
import Prelude hiding ((.),id)

-------------------------------------------------------------------------------
-- Plans
-------------------------------------------------------------------------------

-- | You can 'construct' a 'Plan', turning it into a
-- 'Data.Machine.Type.Machine'.
--
newtype Plan o m a = Plan
  { runPlan :: forall r.
      (a -> r) ->                               -- Done a
      (o -> r -> r) ->                          -- Yield o (Plan o m a)
      (forall z. (z -> r) -> m z -> r -> r) ->  -- forall z. Await (z -> Plan o m a) (m z) (Plan o m a)
      r ->                                      -- Fail
      r
  }

-- | A @'Plan' o m a@ is a specification for a pure 'Machine', that can perform actions in @m@, which
-- writes values of type @o@, and has intermediate results of type @a@.
--
-- It is perhaps easier to think of 'Plan' in its un-cps'ed form, which would
-- look like:

instance Functor (Plan o m) where
  fmap f (Plan m) = Plan $ \k -> m (k . f)
  {-# INLINE fmap #-}

instance Apply (Plan o m) where
  (<.>) = ap
  {-# INLINE (<.>) #-}

instance Applicative (Plan o m) where
  pure a = Plan $ \kp _ _ _ -> kp a
  {-# INLINE pure #-}
  (<*>) = ap
  {-# INLINE (<*>) #-}

instance Alt (Plan o m) where
  (<!>) = (<|>)
  {-# INLINE (<!>) #-}

instance Plus (Plan o m) where
  zero = empty
  {-# INLINE zero #-}

instance Alternative (Plan o m) where
  empty = Plan $ \_ _ _ kf -> kf
  {-# INLINE empty #-}
  Plan m <|> Plan n = Plan $ \kp ke kr kf -> m kp ke (\ks kir _ -> kr ks kir (n kp ke kr kf)) (n kp ke kr kf)
  {-# INLINE (<|>) #-}

instance Bind (Plan o m) where
  (>>-) = (>>=)
  {-# INLINE (>>-) #-}

instance Monad (Plan o m) where
  return a = Plan $ \kp _ _ _ -> kp a
  {-# INLINE return #-}
  Plan m >>= f = Plan $ \kp ke kr kf -> m (\a -> runPlan (f a) kp ke kr kf) ke kr kf
  fail _ = Plan $ \_ _ _ kf -> kf
  {-# INLINE (>>=) #-}

instance MonadPlus (Plan o m) where
  mzero = empty
  {-# INLINE mzero #-}
  mplus = (<|>)
  {-# INLINE mplus #-}

instance MonadTrans (Plan o) where
  lift m = Plan $ \kp _ ka kf -> ka kp m kf
  {-# INLINE lift #-}

instance MonadIO m => MonadIO (Plan o m) where
  liftIO m = Plan $ \kp _ ka kf -> ka kp (liftIO m) kf
  {-# INLINE liftIO #-}

instance MonadState s m => MonadState s (Plan o m) where
  get = lift get
  {-# INLINE get #-}
  put = lift . put
  {-# INLINE put #-}
#if MIN_VERSION_mtl(2,1,0)
  state = lift . state
  {-# INLINE state #-}
#endif

instance MonadReader e m => MonadReader e (Plan o m) where
  ask = lift ask
  {-# INLINE ask #-}
#if MIN_VERSION_mtl(2,1,0)
  reader = lift . reader
  {-# INLINE reader #-}
#endif
  local f (Plan m) = Plan $ \kp ke kr -> m kp ke $ \ar -> kr ar . local f
  {-# INLINE local #-}

-- | Output a result.
yield :: o -> Plan o m ()
yield o = Plan $ \kp ke _ _ -> ke o (kp ())
{-# INLINE yield #-}

instance Await i m => Await i (Plan o m) where
  await = awaits await
  {-# INLINE await #-}

--- | Wait for a particular input.
---
--- @
--- 'awaits' 'L' :: 'Await' i f => 'Plan' o (f :+: g) i
--- 'awaits' 'R' :: 'Await' j g => 'Plan' o (f :+: g) j
--- 'awaits' 'This' :: 'Await' i f => 'Plan' o (Y f g) i
--- 'awaits' 'That' :: 'Await' j g => 'Plan' o (Y f g) j
--- @
awaits :: Await i f => (f i -> g j) -> Plan o g j
awaits f = request (f await)
{-# INLINE awaits #-}

request :: g j -> Plan o g j
request m = Plan $ \kp _ ka kf -> ka kp m kf
