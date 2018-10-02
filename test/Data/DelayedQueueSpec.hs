module Data.DelayedQueueSpec where

import           Data.List             (foldl', unfoldr)

import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck

import           Data.DelayedQueue

{-# ANN module "HLint: ignore Reduce duplication" #-}
{-# ANN module "HLint: ignore Avoid lambda" #-}

spec :: Spec
spec =
    describe "DelayedQueue" $ do
        it "Pop from newEmptyDelayedQueue returns Nothing" $ do
            let rs = pop (newEmptyDelayedQueue 0 :: DelayedQueue ())
            rs `shouldBe` Nothing

        it "Push 1 to delay 0 queue pops 1 then Nothing" $ do
            let q0              = push 1 $ newEmptyDelayedQueue 0
                Just (r1, q1)   = pop q0
                r2              = pop q1
            r1 `shouldBe` 1
            r2 `shouldBe` Nothing

        it "Push 1 to delay 1 queue pops Nothing" $ do
            let q0  = push 1 $ newEmptyDelayedQueue 1
                r1  = pop q0
            r1 `shouldBe` Nothing

        it "Push 1 and 2 to delay 1 queue pops 1 then Nothing" $ do
            let q0              = push 2 . push 1 $ newEmptyDelayedQueue 1
                Just (r1, q1)   = pop q0
                r2              = pop q1
            r1 `shouldBe` 1
            r2 `shouldBe` Nothing

        it "Push 1, 2, 3, 4, 5 to delay 3 queue pops 1, 2, Nothing" $ do
            let q0              = push 5 . push 4 . push 3 . push 2 . push 1 $ newEmptyDelayedQueue 3
                Just (r1, q1)   = pop q0
                Just (r2, q2)   = pop q1
                r3              = pop q2
            r1 `shouldBe` 1
            r2 `shouldBe` 2
            r3 `shouldBe` Nothing

        it "Push 1 to 5, pop x3, push 6, pop on delay 3 queue results 1, 2, Nothing, 3" $ do
            let q0              = push 5 . push 4 . push 3 . push 2 . push 1 $ newEmptyDelayedQueue 3
                Just (r1, q1)   = pop q0
                Just (r2, q2)   = pop q1
                r3              = pop q2
                q3              = push 6 q2
                Just (r4, _)    = pop q3
            r1 `shouldBe` 1
            r2 `shouldBe` 2
            r3 `shouldBe` Nothing
            r4 `shouldBe` 3

        prop "Keeps given number of element" $ \(Positive n, Positive d) -> do
            let len = n + d :: Int
                src = foldl' (\tq n -> push n tq) (newEmptyDelayedQueue d) [1 .. len]
                dst = unfoldr (\q -> pop q) src
            len - length dst `shouldBe` d
            [1 .. n] `shouldBe` dst

        prop "Keeps given number of element2" $ \(xs, Positive d) -> do
            let src = foldl' (\tq n -> push n tq) (newEmptyDelayedQueue d) (xs :: [Int])
                dst = unfoldr (\q -> pop q) src
                len = length xs - d
            if len >= 0
            then take len xs `shouldBe` dst
            else dst `shouldBe` []
