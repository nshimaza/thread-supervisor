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

import           System.Clock                  (Clock (Monotonic), getTime, toNanoSecs)

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
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
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
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
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
            let mons    = map (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) svs
                process = newProcessSpec mons Temporary $ readMVar blocker $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            cancel a
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Killed, asyncThreadId a)

    describe "SimpleOneForOneSupervisor" $ do
        it "it starts a dynamic child" $ do
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

        it "does not restart finished dynamic child regardless restart type" $ do
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

        it "does not exit itself by massive child crash" $ do
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
                    maybeAsync <- newChild def sv $ newProcessSpec [] Permanent $ readMVar blocker $> ()
                    isJust maybeAsync `shouldBe` True

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                for_ procs $ newChild def sv
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume          = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
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
            let normalCound = length . filter ((==) Normal . fst) $ reports
                killedCound = length . filter ((==) Killed . fst) $ reports
            normalCound `shouldNotBe` 0
            killedCound `shouldNotBe` 0
            normalCound + killedCound `shouldBe` volume

    describe "One-for-one Supervisor with static childlen" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]

        it "automatically restarts finished children with permanent restart type" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 3) def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` map Just [1,2,3]
                rs4 <- for childQs $ \ch -> call def ch True
                rs4 `shouldBe` map Just [2,3,4]

        it "restarts neither normally finished transient nor temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [True, True]

        it "restarts crashed transient child but does not restart crashed temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) UncaughtException . fst)
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [False, True]

        it "restarts killed transient child but does not restart killed temporary child" $ do
            blocker <- newEmptyMVar
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                length rs1 `shouldBe` 2
                for_ rs1 killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Killed . fst)
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [False, True]

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume          = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newTQueueIO
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne (RestartIntensity 1000) def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> cast ch False
                threadDelay 10000
            reports <- for childMons $ atomically . readTQueue
            length reports `shouldBe` volume
            let normalCound = length . filter ((==) Normal . fst) $ reports
                killedCound = length . filter ((==) Killed . fst) $ reports
            normalCound `shouldNotBe` 0
            killedCound `shouldNotBe` 0
            normalCound + killedCound `shouldBe` volume

    describe "One-for-all Supervisor with static childlen" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]

        it "automatically restarts all static children when one of permanent children finished" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` map Just [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` map Just [2,3,4]
                cast (head childQs) False
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [Normal, Killed, Killed]
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` map Just [1,2,3]
                rs4 <- for childQs $ \ch -> call def ch True
                rs4 `shouldBe` map Just [2,3,4]

        it "does not restart children on normal exit of transient or temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                rs1 `shouldBe` [(), ()]
                putMVar (head triggers) ()
                (reason1, _) <- takeMVar $ head childMons
                reason1 `shouldBe` Normal
                threadDelay 1000
                rs2 <- for markers $  \m -> isEmptyMVar m
                rs2 `shouldBe` [True, True]
                putMVar (triggers !! 1) ()
                (reason2, _) <- takeMVar $ childMons !! 1
                reason2 `shouldBe` Normal
                threadDelay 1000
                rs3 <- for markers $  \m -> isEmptyMVar m
                rs3 `shouldBe` [True, True]

        it "restarts all static children when one of transient child crashed or killed" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ (myThreadId >>= putMVar marker) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll (RestartIntensity 2) def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                length rs1 `shouldBe` 2
                putMVar (head triggers) ()
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [UncaughtException, Killed]
                threadDelay 1000
                rs2 <- for markers $ \m -> takeMVar m
                length rs2 `shouldBe` 2
                killThread $ head rs2
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [Killed, Killed]
                threadDelay 1000
                rs3 <- for markers $ \m -> takeMVar m
                length rs3 `shouldBe` 2

        it "does not restarts any children even if a temporary child crashed" $ do
            blocker <- newEmptyMVar
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                length rs1 `shouldBe` 2
                putMVar (triggers !! 1) ()
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldBe` UncaughtException
                threadDelay 1000
                rs2 <- for markers $  \m -> isEmptyMVar m
                rs2 `shouldBe` [True, True]

        it "does not restarts any children even if a temporary child killed" $ do
            blocker <- newEmptyMVar
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] restart $ (myThreadId >>= putMVar marker) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs1 <- for markers $ \m -> takeMVar m
                length rs1 `shouldBe` 2
                killThread $ rs1 !! 1
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldBe` Killed
                threadDelay 1000
                rs2 <- for markers $  \m -> isEmptyMVar m
                rs2 `shouldBe` [True, True]

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume          = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newTQueueIO
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` map Just [1..volume]
                async $ threadDelay 1 *> cast (head childQs) False
                threadDelay 10000
            reports <- for childMons $ atomically . readTQueue
            length reports `shouldBe` volume
            (fst . head) reports `shouldBe` Normal
            tail reports `shouldSatisfy` and . map ((==) Killed . fst)
