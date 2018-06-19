module Control.Concurrent.SupervisorInternalSpec where

import           Data.Default                          (def)
import           Data.Foldable                         (for_)
import           Data.Functor                          (($>))
import           Data.Maybe                            (fromJust, isJust,
                                                        isNothing)
import           Data.Traversable                      (for)
import           System.Clock                          (TimeSpec (..),
                                                        fromNanoSecs)
import           UnliftIO                              (StringException (..),
                                                        asyncThreadId,
                                                        atomically, cancel,
                                                        fromException,
                                                        newEmptyMVar,
                                                        newTQueueIO, putMVar,
                                                        readMVar, readTQueue,
                                                        throwString,
                                                        tryReadTQueue,
                                                        writeTQueue)

import           Test.Hspec

import           Control.Concurrent.SupervisorInternal

instance Eq ExitReason where
    (UncaughtException e) == _  = error "should not compare exception by Eq"
    _ == (UncaughtException e)  = error "should not compare exception by Eq"
    Normal == Normal            = True
    Killed == Killed            = True
    _ == _                      = False

reasonToString :: ExitReason -> String
reasonToString  (UncaughtException e) = toStr $ fromException e
  where toStr (Just (StringException str _)) = str

spec :: Spec
spec =
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
            (reason, tid) <- atomically $ readTQueue sv
            tid `shouldBe` asyncThreadId a
            reasonToString reason `shouldBe` "oops"

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
                (reason, tid) <- atomically $ readTQueue sv
                tid `shouldBe` asyncThreadId a
                reasonToString reason `shouldBe` "oops"

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
