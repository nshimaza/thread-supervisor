module Control.Concurrent.SupervisorInternalSpec where

import           Data.Default                          (def)
import           System.Clock                          (TimeSpec (..),
                                                        fromNanoSecs)

import           Test.Hspec

import           Control.Concurrent.SupervisorInternal

spec :: Spec
spec = do
    describe "Restart intensity handling" $ do
        it "returns True if 1 crash in 0 maximumRestartIntensity" $ do
            let crash       = TimeSpec 0 0
                hist        = newRestartHist 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash hist
            result `shouldBe` True

        it "returns True if 1 crash in 0 maximumRestartIntensity regardless with period" $ do
            let crash       = TimeSpec 0 0
                hist        = newRestartHist 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash hist
            result `shouldBe` True

        it "returns False if 1 crash in 1 maximumRestartIntensity" $ do
            let crash       = TimeSpec 0 0
                hist        = newRestartHist 1
                (result, _) = isRestartIntense (TimeSpec 5 0) crash hist
            result `shouldBe` False

        it "returns True if 2 crash in 1 maximumRestartIntensity within given period" $ do
            let crash1      = TimeSpec 0 0
                (_, hist)   = isRestartIntense (TimeSpec 5 0) crash1 $ newRestartHist 1
                crash2      = TimeSpec 2 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash2 hist
            result `shouldBe` True

        it "returns False if 2 crash in 1 maximumRestartIntensity but longer interval than given period" $ do
            let crash1      = TimeSpec 0 0
                (_, hist)   = isRestartIntense (TimeSpec 5 0) crash1 $ newRestartHist 1
                crash2      = TimeSpec 10 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash2 hist
            result `shouldBe` False

        it "returns False if 1 crash in 2 maximumRestartIntensity" $ do
            let crash       = TimeSpec 0 0
                hist        = newRestartHist 2
                (result, _) = isRestartIntense (TimeSpec 5 0) crash hist
            result `shouldBe` False

        it "returns False if 2 crash in 2 maximumRestartIntensity" $ do
            let crash1      = TimeSpec 0 0
                (_, hist)   = isRestartIntense (TimeSpec 5 0) crash1 $ newRestartHist 2
                crash2      = TimeSpec 2 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash2 hist
            result `shouldBe` False

        it "returns True if 3 crash in 2 maximumRestartIntensity within given period" $ do
            let crash1      = TimeSpec 0 0
                (_, hist1)  = isRestartIntense (TimeSpec 5 0) crash1 $ newRestartHist 2
                crash2      = TimeSpec 2 0
                (_, hist2)  = isRestartIntense (TimeSpec 5 0) crash2 hist1
                crash3      = TimeSpec 3 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash3 hist2
            result `shouldBe` True

        it "returns False if 3 crash in 2 maximumRestartIntensity but longer interval than given period" $ do
            let crash1      = TimeSpec 0 0
                (_, hist1)  = isRestartIntense (TimeSpec 5 0) crash1 $ newRestartHist 2
                crash2      = TimeSpec 3 0
                (_, hist2)  = isRestartIntense (TimeSpec 5 0) crash2 hist1
                crash3      = TimeSpec 6 0
                (result, _) = isRestartIntense (TimeSpec 5 0) crash3 hist2
            result `shouldBe` False
