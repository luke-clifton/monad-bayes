{-|
Module      : Control.Monad.Bayes.Population
Description : Representation of distributions using multiple samples
Copyright   : (c) Adam Scibior, 2016
License     : MIT
Maintainer  : ams240@cam.ac.uk
Stability   : experimental
Portability : GHC

-}

module Control.Monad.Bayes.Population (
    Population,
    runPopulation,
    explicitPopulation,
    fromWeightedList,
    spawn,
    resample,
    proper,
    evidence,
    collapse,
    mapPopulation,
    normalize,
    normalizeProper,
    popAvg,
    flatten,
    hoist
                 ) where

import Prelude hiding (sum, all)

import Control.Arrow (second)
import Control.Monad.Trans
import Control.Monad.Trans.List

import qualified Data.List
import qualified Data.Vector as V

import Numeric.Log
import Control.Monad.Bayes.Class
import Control.Monad.Bayes.Weighted hiding (flatten, hoist)

logNormalize :: V.Vector (Log Double) -> V.Vector (Log Double)
logNormalize v = V.map (/ z) v where
  z = sum v

newtype Population m a = Population (Weighted (ListT m) a)
  deriving(Functor,Applicative,Monad,MonadIO,MonadSample,MonadCond,MonadInfer)

instance MonadTrans Population where
  lift = Population . lift . lift

-- | Explicit representation of the weighted sample with weights in log domain.
runPopulation :: Functor m => Population m a -> m [(a, Log Double)]
runPopulation (Population m) = runListT $ runWeighted m

-- | Explicit representation of the weighted sample.
explicitPopulation :: Functor m => Population m a -> m [(a, Double)]
explicitPopulation = fmap (map (second (exp . ln))) . runPopulation

-- | Initialise 'Population' with a concrete weighted sample.
fromWeightedList :: Monad m => m [(a,Log Double)] -> Population m a
fromWeightedList = Population . withWeight . ListT

-- | Increase the sample size by a given factor.
-- The weights are adjusted such that their sum is preserved.
-- It is therefore safe to use `spawn` in arbitrary places in the program
-- without introducing bias.
spawn :: Monad m => Int -> Population m ()
spawn n = fromWeightedList $ pure $ replicate n ((), 1 / fromIntegral n)

-- | Resample the population using the underlying monad and a simple resampling scheme.
-- The total weight is preserved.
resample :: (MonadSample m)
         => Population m a -> Population m a
resample m = fromWeightedList $ do
  pop <- runPopulation m
  let (xs, ps) = unzip pop
  let n = length xs
  let z = sum ps
  if z > 0 then do
    ancestors <- sequenceA $ replicate n $ logCategorical $ logNormalize $ V.fromList ps
    let offsprings = map (xs !!) ancestors
    return $ map (, z / fromIntegral n) offsprings
  else
    -- if all weights are zero do not resample
    return pop

-- | A properly weighted single sample, that is one picked at random according
-- to the weights, with the sum of all weights.
proper :: (MonadSample m)
       => Population m a -> m (a,Log Double)
proper m = do
  pop <- runPopulation m
  let (xs, ps) = unzip pop
  let z = sum ps
  index <- if z > 0 then
      logCategorical $ logNormalize $ V.fromList ps
    else
      let n = length xs in
        categorical $ V.replicate n (1 / fromIntegral n)
  let x = xs !! index
  return (x,z)

-- | Model evidence estimator, also known as pseudo-marginal likelihood.
evidence :: (Monad m) => Population m a -> m (Log Double)
evidence = fmap (sum . map snd) . runPopulation

-- | Picks one point from the population and uses model evidence as a 'factor'
-- in the transformed monad.
-- This way a single sample can be selected from a population without
-- introducing bias.
collapse :: (MonadInfer m)
         => Population m a -> m a
collapse e = do
  (x,p) <- proper e
  factor p
  return x

-- | Applies a random transformation to a population.
mapPopulation :: (Monad m) => ([(a, Log Double)] -> m [(a, Log Double)]) ->
  Population m a -> Population m a
mapPopulation f m = fromWeightedList $ runPopulation m >>= f

-- | Normalizes the weights in the population so that their sum is 1.
-- This transformation introduces bias.
normalize :: (Monad m) => Population m a -> Population m a
normalize = mapPopulation norm where
    norm xs = pure $ map (second (/ z)) xs where
      z = sum $ map snd xs

-- | Normalizes the weights in the population so that their sum is 1.
-- The sum of weights is pushed as a factor to the transformed monad,
-- so bo bias is introduced.
normalizeProper :: (MonadCond m) => Population m a -> Population m a
normalizeProper = mapPopulation norm where
    norm xs = factor z >> pure (map (second (/ z)) xs) where
      z = sum $ map snd xs

-- | Population average of a function, computed using unnormalized weights.
popAvg :: (Monad m) => (a -> Double) -> Population m a -> m Double
popAvg f p = do
  xs <- explicitPopulation p
  let ys = map (\(x,w) -> f x * w) xs
  let t = Data.List.sum ys
  return t

-- | Combine a population of populations into a single population.
flatten :: Monad m => Population (Population m) a -> Population m a
flatten m = Population $ withWeight $ ListT t where
  t = f <$> (runPopulation . runPopulation) m
  f d = do
    (x,p) <- d
    (y,q) <- x
    return (y, p*q)

-- | Applies a transformation to the inner monad.
hoist :: (Monad m, Monad n)
      => (forall x. m x -> n x) -> Population m a -> Population n a
hoist f = fromWeightedList . f . runPopulation
