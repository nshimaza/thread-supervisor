module Data.DelayedQueue
    ( DelayedQueue
    , newEmptyDelayedQueue
    , push
    , pop
    ) where

import           Data.Sequence (Seq, ViewL ((:<)), empty, viewl, (|>))

data DelayedQueue a = DelayedQueue Int (Seq a) deriving (Eq, Show)

newEmptyDelayedQueue :: Int -> DelayedQueue a
newEmptyDelayedQueue n = DelayedQueue n empty

push :: a -> DelayedQueue a -> DelayedQueue a
push a (DelayedQueue delay sq) = DelayedQueue delay $ sq |> a

pop :: DelayedQueue a -> Maybe (a, DelayedQueue a)
pop (DelayedQueue delay sq) | length sq > delay = case viewl sq of (x :< xs) -> Just (x, DelayedQueue delay xs)
                            | otherwise         = Nothing
