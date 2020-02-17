{-# LANGUAGE Strict #-}

{-|
Module      : Data.DelayedQueue
Copyright   : (c) Naoto Shimazaki 2018-2020
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

Queue with delay before elements become available to dequeue.

'DelayedQueue' is a FIFO but it does NOT make element available to pop
immediately after the element was pushed.  DelayedQueue looks like empty until
its delay-buffer is filled up by pushed elements.  When a value is pushed to a
DelayedQueue where delay-buffer of the queue is already full-filled, the oldest
element becomes available to dequeue.

Entire elements within DelayedQueue are always inlined in enqueued order.  Only
older elements overflowed from delay-buffer are available to dequeue.  If
delay-buffer is not yet filled, no element is available to dequeue.  Once
delay-buffer is filled, delay-buffer always keeps given number of newest
elements.
-}

module Data.DelayedQueue
    ( DelayedQueue
    , newEmptyDelayedQueue
    , push
    , pop
    ) where

import           Data.Sequence (Seq, ViewL ((:<), EmptyL), empty, viewl, (|>))

-- | Queue with delay before elements become available to dequeue.
data DelayedQueue a = DelayedQueue Int (Seq a) deriving (Eq, Show)

-- | Create a new 'DelayedQueue' with given delay.
newEmptyDelayedQueue
    :: Int              -- ^ Delay of the queue in number of element.
    -> DelayedQueue a   -- ^ Created queue.
newEmptyDelayedQueue n = DelayedQueue n empty

-- | Enqueue a value to a 'DelayedQueue'.
push
    :: a                -- ^ value to be queued.
    -> DelayedQueue a   -- ^ queue where the value to be queued.
    -> DelayedQueue a   -- ^ new queue where the value is pushed.
push a (DelayedQueue delay sq) = DelayedQueue delay $ sq |> a

-- | Dequeue a value from a 'DelayedQueue'.
pop
    :: DelayedQueue a               -- ^ 'DelayedQueue' from which a value to be pulled.
    -> Maybe (a, DelayedQueue a)    -- ^ Nothing if there is no available element.
                                    --   Returns pulled value and 'DelayedQueue' with the value removed wrapped in Just.
pop (DelayedQueue delay sq) | length sq > delay = case viewl sq of
                                                    (x :< xs)   -> Just (x, DelayedQueue delay xs)
                                                    EmptyL      -> Nothing
                            | otherwise         = Nothing
