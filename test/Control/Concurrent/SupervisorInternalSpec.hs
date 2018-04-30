module Control.Concurrent.SupervisorInternalSpec where

import           Data.Default                          (def)
import           Data.Foldable                         (for_)
import           Data.Functor                          (($>))
import           Data.Maybe                            (fromJust, isJust,
                                                        isNothing)
import           Data.Traversable                      (for)
import           System.Clock                          (TimeSpec (..),
                                                        fromNanoSecs)
import           UnliftIO                              (asyncThreadId,
                                                        atomically, cancel,
                                                        newEmptyMVar,
                                                        newTQueueIO, putMVar,
                                                        readMVar, readTQueue,
                                                        throwString,
                                                        tryReadTQueue,
                                                        writeTQueue)

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

    describe "Process" $ do
        it "reports exit code Normal on normal exit" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar trigger $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            report <- atomically $ readTQueue sv
            report `shouldBe` (Normal, asyncThreadId a)

        it "reports exit code UncaughtException on synchronous exception which wasn't caught" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            report <- atomically $ readTQueue sv
            report `shouldBe` (UncaughtException, asyncThreadId a)

        it "reports exit code Killed when it received asynchronous exception" $ do
            blocker <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar blocker $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            cancel a
            report <- atomically $ readTQueue sv
            report `shouldBe` (Killed, asyncThreadId a)

        it "can notify its normal exit to multiple monitors" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar trigger $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Normal, asyncThreadId a)

        it "can notify its exit by uncaught exception to multiple monitors" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (UncaughtException, asyncThreadId a)

        it "can notify its exit by asynchronous exception to multiple monitors" $ do
            blocker <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar blocker $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            cancel a
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Killed, asyncThreadId a)
