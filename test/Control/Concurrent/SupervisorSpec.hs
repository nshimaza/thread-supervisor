module Control.Concurrent.SupervisorSpec where

import           Control.Concurrent            (ThreadId, killThread,
                                                myThreadId, threadDelay)
import           Control.Concurrent.Async      (async, asyncThreadId, cancel,
                                                wait, withAsync)
import           Control.Concurrent.MVar       (isEmptyMVar, newEmptyMVar,
                                                putMVar, readMVar, takeMVar)
import           Control.Concurrent.STM.TQueue (newTQueueIO, readTQueue,
                                                tryReadTQueue, writeTQueue)
import           Control.Concurrent.STM.TVar   (newTVarIO, readTVarIO,
                                                writeTVar)
import           Control.Exception.Safe        (bracket, throwString)
import           Control.Monad.STM             (atomically)
import           Data.Default                  (def)
import           Data.Foldable                 (for_)
import           Data.Functor                  (($>))
import           Data.List                     (unzip4)
import           Data.Maybe                    (fromJust, isJust, isNothing)
import           Data.Traversable              (for)

import           Test.Hspec

import           Control.Concurrent.Supervisor

data ConstServerMessage = AskFst | AskSnd

simpleCountingServer :: ServerQueue Bool Int -> Int -> IO Int
simpleCountingServer q n = newServer q (initializer n) cleanup handler
  where
    initializer     = pure
    cleanup _       = pure ()
    handler s False = pure (s, Left s)
    handler s True  = pure (s, Right (s + 1))

spec :: Spec
spec = do
    describe "State machine behavior" $ do
        it "returns result when event handler returns Left" $ do
            q <- newTQueueIO
            let statem = newStateMachine q () $ \_ _ -> pure $ Left "Hello"
            sendMessage q ()
            r <- statem
            r `shouldBe` "Hello"

        it "consumes message in the queue until exit" $ do
            q <- newTQueueIO
            let until5 _ 5 = pure $ Left "Done"
                until5 _ _ = pure $ Right ()
                statem     = newStateMachine q () until5
            for_ [1..7] $ sendMessage q
            r <- statem
            r `shouldBe` "Done"
            msg <- atomically $ readTQueue q
            msg `shouldBe` 6

        it "passes next state with Right" $ do
            q <- newTQueueIO
            let handler True  _ = pure $ Right False
                handler False _ = pure $ Left "Finished"
                statem          = newStateMachine q True handler
            for_ [(), ()] $ sendMessage q
            r <- statem
            r `shouldBe` "Finished"

        it "runs state machine by consuming messages until handler returns Left" $ do
            q <- newTQueueIO
            let handler n 10 = pure $ Left (n + 10)
                handler n x  = pure $ Right (n + x)
                statem       = newStateMachine q 0 handler
            for_ [1..100] $ sendMessage q
            r <- statem
            r `shouldBe` 55

    describe "Server" $ do
        it "has call method which return value synchronously" $ do
            srvQ <- newTQueueIO
            let initializer         = pure (1, 2)
                cleanup _           = pure ()
                handler s AskFst = pure (fst s, Right s)
                handler s AskSnd = pure (snd s, Right s)
                srv                     = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ AskFst
                r1 `shouldBe` Just 1
                r2 <- call def srvQ AskSnd
                r2 `shouldBe` Just 2

        it "keeps its own state and cast changes the state" $ do
            srvQ <- newTQueueIO
            let initializer = pure 0
                cleanup _   = pure ()
                handler s _ = pure (s, Right (s + 1))
                srv         = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ ()
                r1 `shouldBe` Just 0
                cast srvQ ()
                r2 <- call def srvQ ()
                r2 `shouldBe` Just 2

        it "keeps its own state and call can change the state" $ do
            srvQ <- newTQueueIO
            withAsync (simpleCountingServer srvQ 0) $ \_ -> do
                r1 <- call def srvQ True
                r1 `shouldBe` Just 0
                r2 <- call def srvQ True
                r2 `shouldBe` Just 1

        it "timeouts call method when server is not responding" $ do
            srvQ <- newTQueueIO
            blocker <- newEmptyMVar
            let initializer = pure ()
                cleanup _   = pure ()
                handler _ _ = takeMVar blocker $> ((), Right ())
                srv             = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call (CallTimeout 10000) srvQ ()
                (r1 :: Maybe ()) `shouldBe` Nothing
    describe "Process" $ do
        it "reports exit code Normal on normal exit" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                proc                = newProcessSpec [monitor] Temporary $ readMVar trigger $> ()
            a <- newProcess pmap proc
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
                proc                = newProcessSpec [monitor] Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap proc
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
                proc                = newProcessSpec [monitor] Temporary $ readMVar blocker $> ()
            a <- newProcess pmap proc
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            cancel a
            report <- atomically $ readTQueue sv
            report `shouldBe` (Killed, asyncThreadId a)

        it "can notify its normal exit to multiple monitors" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
                proc    = newProcessSpec mons Temporary $ readMVar trigger $> ()
            a <- newProcess pmap proc
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
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
                proc    = newProcessSpec mons Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap proc
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
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
                proc    = newProcessSpec mons Temporary $ readMVar blocker $> ()
            a <- newProcess pmap proc
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            cancel a
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Killed, asyncThreadId a)

    describe "SimpleOneForOneSupervisor" $ do
        it "it spown a child based on given ProcessSpec" $ do
            trigger <- newEmptyMVar
            mark <- newEmptyMVar
            blocker <- newEmptyMVar
            var <- newTVarIO (0 :: Int)
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                maybeChildAsync <- newChild def sv $ newProcessSpec [] Temporary $ do
                    readMVar trigger
                    atomically $ writeTVar var 1
                    putMVar mark ()
                    readMVar blocker
                    pure ()
                isJust maybeChildAsync `shouldBe` True
                currentVal0 <- readTVarIO var
                currentVal0 `shouldBe` 0
                putMVar trigger ()
                readMVar mark
                currentVal1 <- readTVarIO var
                currentVal1 `shouldBe` 1

        it "does not restart finished process regardless restart type" $ do
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> for_ [Permanent, Transient, Temporary] $ \restart -> do
                mark <- newEmptyMVar
                trigger <- newEmptyMVar
                Just a <- newChild def sv $ newProcessSpec [] restart $ do
                    putMVar mark ()
                    readMVar trigger
                    pure ()
                takeMVar mark
                putMVar trigger ()
                wait a
                threadDelay 1000
                r <- isEmptyMVar mark
                r `shouldBe` True

        it "does not restart itself by multiple child crash" $ do
            pmap <- newProcessMap
            sv <- newTQueueIO
            svMon <- newEmptyMVar
            let monitor reason tid  = putMVar svMon (reason, tid)
            bracket
                (newProcess pmap $ newProcessSpec [monitor] Temporary $ newSimpleOneForOneSupervisor sv)
                cancel
                $ \_ -> do
                    blocker <- newEmptyMVar
                    for_ [1..10] $ \_ -> do
                        Just a <- newChild def sv $ newProcessSpec [] Permanent $ readMVar blocker $> ()
                        cancel a
                    threadDelay 1000
                    r <- isEmptyMVar svMon
                    r `shouldBe` True

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, proc)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                for_ procs $ newChild def sv
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..10]
            reports <- for childMons takeMVar
            let isDown (Killed, _) = True
                isDown _           = False
            reports `shouldSatisfy` and . map isDown

        it "can be killed when children is finishing at the same time" $ do
            let volume          = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, proc)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                for_ procs $ newChild def sv
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> cast ch False
                threadDelay 10000
            reports <- for childMons takeMVar
            length reports `shouldBe` volume
            let isNormal (Normal, _) = True
                isNormal _           = False
                isKilled (Killed, _) = True
                isKilled _           = False
            reports `shouldSatisfy` (/=) 0 . length . filter isNormal
            reports `shouldSatisfy` (/=) 0 . length . filter isKilled
            (length . filter isNormal) reports + (length . filter isKilled) reports `shouldBe` volume

    describe "Supervisor with one-for-one strategy" $ do
        it "automatically start children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, proc)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]

        it "automatically restart finished children with permanent restart type" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, proc)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 3) def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                let isDownNormal (Normal, _) = True
                    isDownNormal _           = False
                reports `shouldSatisfy` and . map isDownNormal
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` map Just [1,2,3]
                rs4 <- for childQs $ \ch -> call def ch True
                rs4 `shouldBe` map Just [2,3,4]

        it "restart neither normally finished transient nor temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger $> ()
                pure (marker, trigger, childMon, proc)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                let isDownNormal (Normal, _) = True
                    isDownNormal _           = False
                reports `shouldSatisfy` and . map isDownNormal
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [True, True]

        it "restart crashed transient child but does not restart crashed temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, proc)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                let isDownUncaughtException (UncaughtException, _) = True
                    isDownUncaughtException _                      = False
                reports `shouldSatisfy` and . map isDownUncaughtException
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [False, True]

        it "restart killed transient child but does not restart killed temporary child" $ do
            blocker <- newEmptyMVar
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    proc                = newProcessSpec [monitor] restart $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, proc)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                length rs1 `shouldBe` 2
                for_ rs1 killThread
                reports <- for childMons takeMVar
                let isDownKilled (Killed, _) = True
                    isDownKilled _           = False
                reports `shouldSatisfy` and . map isDownKilled
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [False, True]
