module Control.Concurrent.SupervisorSpec where

import           Data.Default                  (def)
import           Data.Foldable                 (for_)
import           Data.Functor                  (($>))
import           Data.List                     (unzip4)
import           Data.Maybe                    (fromJust, isJust, isNothing)
import           Data.Traversable              (for)
import           Data.Typeable                 (typeOf)
import           System.Clock                  (Clock (Monotonic),
                                                TimeSpec (..), getTime,
                                                toNanoSecs)
import           UnliftIO                      (StringException (..), async,
                                                asyncThreadId, atomically,
                                                cancel, fromException,
                                                isEmptyMVar, newEmptyMVar,
                                                newTQueueIO, newTVarIO, poll,
                                                putMVar, readMVar, readTQueue,
                                                readTVarIO, takeMVar,
                                                throwString, wait, withAsync,
                                                writeTQueue, writeTVar)
import           UnliftIO.Concurrent           (ThreadId, killThread,
                                                myThreadId, threadDelay)

import           Test.Hspec

import           Control.Concurrent.Supervisor

instance Eq ExitReason where
    (UncaughtException e) == _  = error "should not compare exception by Eq"
    _ == (UncaughtException e)  = error "should not compare exception by Eq"
    Normal == Normal            = True
    Killed == Killed            = True
    _ == _                      = False

reasonToString :: ExitReason -> String
reasonToString  (UncaughtException e) = toStr $ fromException e
  where toStr (Just (StringException str _)) = str

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
            sv <- newTQueueIO
            withAsync (newSimpleOneForOneSupervisor sv) $ \a -> do
                blocker <- newEmptyMVar
                for_ [1..10] $ \_ -> do
                    Just a <- newChild def sv $ newProcessSpec [] Permanent $ readMVar blocker $> ()
                    cancel a
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
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
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
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
                rs `shouldBe` Just <$> [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> cast ch False
                threadDelay 10000
            reports <- for childMons takeMVar
            length reports `shouldBe` volume
            let normalCount = length . filter ((==) Normal . fst) $ reports
                killedCount = length . filter ((==) Killed . fst) $ reports
            normalCount `shouldNotBe` 0
            killedCount `shouldNotBe` 0
            normalCount + killedCount `shouldBe` volume

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
            withAsync (newSupervisor sv OneForOne def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts finished children with permanent restart type" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 3 } procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3,4]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` Just <$> [1,2,3]
                rs4 <- for childQs $ \ch -> call def ch True
                rs4 `shouldBe` Just <$> [2,3,4]

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
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                rs1 <- for markers takeMVar
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
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) "oops" . reasonToString . fst)
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
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                tids <- for markers takeMVar
                for_ tids killThread
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
            withAsync (newSupervisor sv OneForOne def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newTQueueIO
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 1000 } procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` Just <$> [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> cast ch False
                threadDelay 10000
            reports <- for childMons $ atomically . readTQueue
            length reports `shouldBe` volume
            let normalCount = length . filter ((==) Normal . fst) $ reports
                killedCount = length . filter ((==) Killed . fst) $ reports
            normalCount `shouldNotBe` 0
            killedCount `shouldNotBe` 0
            normalCount + killedCount `shouldBe` volume

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3]
                cast (head childQs) False
                report1 <- takeMVar (head childMons)
                fst report1 `shouldBe` Normal
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` Just <$> [1,4]
                cast (head childQs) False
                report2 <- takeMVar (head childMons)
                fst report2 `shouldBe` Normal
                r <- wait a
                r `shouldBe` ()

        it "intensive crash of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (head triggers) ()
                report1 <- takeMVar $ head childMons
                report1 `shouldSatisfy` ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                rs2 <- takeMVar $ head markers
                rs2 `shouldBe` ()
                putMVar (triggers !! 1) ()
                report2 <- takeMVar $ childMons !! 1
                report2 `shouldSatisfy` ((==) "oops" . reasonToString . fst)
                r <- wait a
                r `shouldBe` ()

        it "intensive killing permanent child causes termination of Supervisor itself" $ do
            blocker <- newEmptyMVar
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                tids <- for markers takeMVar
                killThread $ head tids
                report1 <- takeMVar $ head childMons
                fst report1 `shouldBe` Killed
                threadDelay 1000
                rs2 <- isEmptyMVar $ head markers
                rs2 `shouldBe` False
                tid2 <- takeMVar $ head markers
                killThread tid2
                report2 <- takeMVar $ head childMons
                fst report2 `shouldBe` Killed
                r <- wait a
                r `shouldBe` ()

        it "intensive normal exit of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive crash of transient child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (head triggers) ()
                report1 <- takeMVar $ head childMons
                report1 `shouldSatisfy` ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                rs2 <- takeMVar $ head markers
                rs2 `shouldBe` ()
                putMVar (triggers !! 1) ()
                report2 <- takeMVar $ childMons !! 1
                report2 `shouldSatisfy` ((==) "oops" . reasonToString . fst)
                r <- wait a
                r `shouldBe` ()

        it "intensive killing transient child causes termination of Supervisor itself" $ do
            blocker <- newEmptyMVar
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                tids <- for markers takeMVar
                killThread $ head tids
                report1 <- takeMVar $ head childMons
                fst report1 `shouldBe` Killed
                threadDelay 1000
                rs2 <- isEmptyMVar $ head markers
                rs2 `shouldBe` False
                tid2 <- takeMVar $ head markers
                killThread tid2
                report2 <- takeMVar $ head childMons
                fst report2 `shouldBe` Killed
                r <- wait a
                r `shouldBe` ()

        it "intensive normal exit of temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive crash of temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive kiling temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> threadDelay 1000 *> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple crash of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> threadDelay 1000 *> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple killing transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids $ \tid -> threadDelay 1000 *> killThread tid
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

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
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts all static children when one of permanent children finished" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3,4]
                cast (head childQs) False
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [Normal, Killed, Killed]
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` Just <$> [1,2,3]
                rs4 <- for childQs $ \ch -> call def ch True
                rs4 `shouldBe` Just <$> [2,3,4]

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
            withAsync (newSupervisor sv OneForAll def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                rs1 <- for markers takeMVar
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
            withAsync (newSupervisor sv OneForAll def { restartSensitivityIntensity = 2 } procs) $ \a -> do
                rs1 <- for markers takeMVar
                putMVar (head triggers) ()
                reports <- for childMons takeMVar
                fst (reports !! 0) `shouldSatisfy` ((==) "oops" . reasonToString)
                fst (reports !! 1) `shouldBe` Killed
                threadDelay 1000
                tids <- for markers takeMVar
                killThread $ head tids
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [Killed, Killed]
                threadDelay 1000
                rs3 <- for markers takeMVar
                typeOf <$> rs3 `shouldBe` replicate 2 (typeOf $ asyncThreadId a)

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
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (triggers !! 1) ()
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldSatisfy` ((==) "oops" . reasonToString)
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
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
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                tids <- for markers takeMVar
                killThread $ tids !! 1
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldBe` Killed
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
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
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newTQueueIO
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs <- for childQs $ \ch -> call def ch True
                rs `shouldBe` Just <$> [1..volume]
                async $ threadDelay 1 *> cast (head childQs) False
                threadDelay 10000
            reports <- for childMons $ atomically . readTQueue
            (fst . head) reports `shouldBe` Normal
            tail reports `shouldSatisfy` and . map ((==) Killed . fst)

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1,2]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2,3]
                cast (head childQs) False
                reports1 <- for childMons takeMVar
                fst <$> reports1 `shouldBe` [Normal, Killed]
                rs3 <- for childQs $ \ch -> call def ch True
                rs3 `shouldBe` Just <$> [1,2]
                cast (head childQs) False
                reports2 <- for childMons takeMVar
                fst <$> reports2 `shouldBe` [Normal, Killed]
                r <- wait a
                r `shouldBe` ()

        it "intensive crash of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (head triggers) ()
                reports1 <- for childMons takeMVar
                fst (reports1 !! 0) `shouldSatisfy` ((==) "oops" . reasonToString)
                fst (reports1 !! 1) `shouldBe` Killed
                threadDelay 1000
                rs2 <- for markers takeMVar
                rs2 `shouldBe` [(), ()]
                putMVar (triggers !! 1) ()
                reports2 <- for childMons takeMVar
                fst (reports2 !! 0) `shouldBe` Killed
                fst (reports2 !! 1) `shouldSatisfy` ((==) "oops" . reasonToString)
                r <- wait a
                r `shouldBe` ()

        it "intensive killing permanent child causes termination of Supervisor itself" $ do
            blocker <- newEmptyMVar
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                tids <- for markers takeMVar
                killThread $ head tids
                reports1 <- for childMons takeMVar
                fst <$> reports1 `shouldBe` [Killed, Killed]
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
                rs2 `shouldBe` [False, False]
                tid2 <- takeMVar $ head markers
                killThread tid2
                reports2 <- for childMons takeMVar
                fst <$> reports2 `shouldBe` [Killed, Killed]
                r <- wait a
                r `shouldBe` ()

        it "intensive normal exit of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive crash of transient child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (head triggers) ()
                reports1 <- for childMons takeMVar
                fst (reports1 !! 0) `shouldSatisfy` ((==) "oops" . reasonToString)
                fst (reports1 !! 1) `shouldBe` Killed
                threadDelay 1000
                rs2 <- for markers takeMVar
                rs2 `shouldBe` [(), ()]
                putMVar (triggers !! 1) ()
                reports2 <- for childMons takeMVar
                fst (reports2 !! 0) `shouldBe` Killed
                fst (reports2 !! 1) `shouldSatisfy` ((==) "oops" . reasonToString)
                r <- wait a
                r `shouldBe` ()

        it "intensive killing transient child causes termination of Supervisor itself" $ do
            blocker <- newEmptyMVar
            rs <- for [1,2] $ \n -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                tids1 <- for markers takeMVar
                killThread $ head tids1
                reports1 <- for childMons takeMVar
                fst <$> reports1 `shouldBe` [Killed, Killed]
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
                rs2 `shouldBe` [False, False]
                tids2 <- for markers takeMVar
                killThread $ tids2 !! 1
                reports2 <- for childMons takeMVar
                fst <$> reports2 `shouldBe` [Killed, Killed]
                r <- wait a
                r `shouldBe` ()

        it "intensive normal exit of temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> cast ch False
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Normal . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive crash of temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            sv <- newTQueueIO
            withAsync(newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive kiling temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` and . map ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newTQueueIO
                let process             = newProcessSpec [] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, process)
            let (childQs, procs) = unzip rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs $ \ch -> call def ch True
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> threadDelay 1000 *> cast ch False
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                rs1 <- for childQs $ \ch -> call def ch True
                rs1 `shouldBe` Just <$> [1..10]

        it "longer interval multiple crash of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newTVarIO False
                trigger <- newEmptyMVar
                let process             = newProcessSpec [] Transient $ (atomically $ writeTVar marker True) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, process)
            let (markers, triggers, procs) = unzip3 rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                threadDelay 1000
                rs1 <- for markers readTVarIO
                rs1 `shouldBe` replicate 10 True
                rs1 <- for markers $ \m -> atomically $ writeTVar m True
                for_ triggers $ \t -> threadDelay 1000 *> putMVar t ()
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                rs1 <- for markers readTVarIO
                rs1 `shouldBe` replicate 10 True

        it "longer interval multiple killing transient child does not terminate Supervisor" $ do
            myTid <- myThreadId
            rs <- for [1..3] $ \n -> do
                marker <- newTVarIO myTid
                blocker <- newEmptyMVar
                let process             = newProcessSpec [] Transient $ (myThreadId >>= atomically . writeTVar marker) *> takeMVar blocker $> ()
                pure (marker, process)
            let (markers, procs) = unzip rs
            sv <- newTQueueIO
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                threadDelay 10000
                tids <- for markers readTVarIO
                tids `shouldSatisfy` not . elem myTid
                for_ tids killThread
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                tids <- for markers readTVarIO
                tids `shouldSatisfy` not . elem myTid
