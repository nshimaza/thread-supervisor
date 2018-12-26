module Control.Concurrent.SupervisorSpec where

import           Data.Char                     (chr, ord)
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
                                                newTVarIO, poll, putMVar,
                                                readMVar, readTVarIO, takeMVar,
                                                throwString, wait, withAsync,
                                                writeTVar)
import           UnliftIO.Concurrent           (ThreadId, killThread,
                                                myThreadId, threadDelay)

import           Test.Hspec

import           Control.Concurrent.Supervisor

{-# ANN module "HLint: ignore Reduce duplication" #-}
{-# ANN module "HLint: ignore Use head" #-}

instance Eq ExitReason where
    (UncaughtException e) == _  = error "should not compare exception by Eq"
    _ == (UncaughtException e)  = error "should not compare exception by Eq"
    Normal == Normal            = True
    Killed == Killed            = True
    _ == _                      = False

reasonToString :: ExitReason -> String
reasonToString  (UncaughtException e) = toStr $ fromException e
  where toStr (Just (StringException str _)) = str

data ConstServerCmd = AskFst (ServerCallback Int) | AskSnd (ServerCallback Char)

data TickerServerCmd = Tick (ServerCallback Int)

data SimpleCountingServerCmd
    = CountUp (ServerCallback Int)
    | Finish (ServerCallback Int)

simpleCountingServer :: ServerQueue SimpleCountingServerCmd -> Int -> IO Int
simpleCountingServer q n = newServer q (initializer n) cleanup handler
  where
    initializer     = pure
    cleanup _       = pure ()
    handler s (CountUp cont)    = cont s *> pure (Right (s + 1))
    handler s (Finish cont)     = cont s *> pure (Left s)

callCountUp :: ServerQueue SimpleCountingServerCmd -> IO (Maybe Int)
callCountUp q = call def q CountUp

castFinish :: ServerQueue SimpleCountingServerCmd -> IO ()
castFinish q = cast q Finish

spec :: Spec
spec = do
    describe "MessageQueue receive" $ do
        it "receives message in sent order" $ do
            q <- newMessageQueue
            for_ ['a'..'z'] $ sendMessage q
            r <- for [1..26] $ const $ receive q
            r `shouldBe` ['a'..'z']

        it "blocks until message available" $ do
            q <- newMessageQueue
            withAsync (receive q) $ \a -> do
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                sendMessage q "Hello"
                r2 <- wait a
                r2 `shouldBe` "Hello"

    describe "MessageQueue receiveSelect" $ do
        it "allows selective receive" $ do
            q <- newMessageQueue

            for_ ['a'..'z'] $ sendMessage q
            r1 <- receiveSelect (== 'a') q
            r1 `shouldBe` 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ sendMessage q
            r3 <- receiveSelect (== 'h') q
            r3 `shouldBe` 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` ['a'..'g'] <> ['i'..'z']

            for_ ['a'..'z'] $ sendMessage q
            r5 <- receiveSelect (== 'z') q
            r5 `shouldBe` 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ sendMessage q
                r7 <- receiveSelect (== chr i) q
                ord r7 `shouldBe` i
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` ['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z']

        it "returns the first element satisfying supplied predicate" $ do
            q <- newMessageQueue
            for_ "abcdefabcdef" $ sendMessage q
            r1 <- receiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "blocks until interesting message arrived" $ do
            q <- newMessageQueue
            for_ ['a'..'y'] $ sendMessage q
            withAsync (receiveSelect (== 'z') q) $ \a -> do
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                sendMessage q 'z'
                r2 <- wait a
                r2 `shouldBe` 'z'

    describe "MessageQueue tryReceiveSelect" $ do
        it "returns Nothing if no message available" $ do
            q <- newMessageQueue
            r <- tryReceiveSelect (const True) q
            r `shouldBe` (Nothing :: Maybe Int)

        it "allows selective receive" $ do
            q <- newMessageQueue

            for_ ['a'..'z'] $ sendMessage q
            r1 <- tryReceiveSelect (== 'a') q
            r1 `shouldBe` Just 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ sendMessage q
            r3 <- tryReceiveSelect (== 'h') q
            r3 `shouldBe` Just 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` (['a'..'g'] <> ['i'..'z'])

            for_ ['a'..'z'] $ sendMessage q
            r5 <- tryReceiveSelect (== 'z') q
            r5 `shouldBe` Just 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ sendMessage q
                r7 <- tryReceiveSelect (== chr i) q
                r7 `shouldBe` Just (chr i)
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` (['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z'])

        it "returns the first element satisfying supplied predicate" $ do
            q <- newMessageQueue
            for_ "abcdefabcdef" $ sendMessage q
            r1 <- tryReceiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` Just 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "return Nothing when there is no interesting message in the queue" $ do
            q <- newMessageQueue
            for_ ['a'..'y'] $ sendMessage q
            r <- tryReceiveSelect (== 'z') q
            r `shouldBe` Nothing

    describe "State machine behavior" $ do
        it "returns result when event handler returns Left" $ do
            q <- newMessageQueue
            let statem = newStateMachine q () $ \_ _ -> pure $ Left "Hello"
            sendMessage q ()
            r <- statem
            r `shouldBe` "Hello"

        it "consumes message in the queue until exit" $ do
            q <- newMessageQueue
            let until5 _ 5 = pure $ Left "Done"
                until5 _ _ = pure $ Right ()
                statem     = newStateMachine q () until5
            for_ [1..7] $ sendMessage q
            r <- statem
            r `shouldBe` "Done"
            msg <- receive q
            msg `shouldBe` 6

        it "passes next state with Right" $ do
            q <- newMessageQueue
            let handler True  _ = pure $ Right False
                handler False _ = pure $ Left "Finished"
                statem          = newStateMachine q True handler
            for_ [(), ()] $ sendMessage q
            r <- statem
            r `shouldBe` "Finished"

        it "runs state machine by consuming messages until handler returns Left" $ do
            q <- newMessageQueue
            let handler n 10 = pure $ Left (n + 10)
                handler n x  = pure $ Right (n + x)
                statem       = newStateMachine q 0 handler
            for_ [1..100] $ sendMessage q
            r <- statem
            r `shouldBe` 55

    describe "Server" $ do
        it "has call method which return value synchronously" $ do
            srvQ <- newMessageQueue
            let initializer         = pure (1, 'a')
                cleanup _           = pure ()
                handler s (AskFst cont) = cont (fst s) $> Right s
                handler s (AskSnd cont) = cont (snd s) $> Right s
                srv                     = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ AskFst
                r1 `shouldBe` Just 1
                r2 <- call def srvQ AskSnd
                r2 `shouldBe` Just 'a'

        it "keeps its own state and cast changes the state" $ do
            srvQ <- newMessageQueue
            let initializer = pure 0
                cleanup _   = pure ()
                handler s (Tick cont)   = cont s $> Right (s + 1)
                srv                     = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ Tick
                r1 `shouldBe` Just 0
                cast srvQ Tick
                r2 <- call def srvQ Tick
                r2 `shouldBe` Just 2

        it "keeps its own state and call can change the state" $ do
            srvQ <- newMessageQueue
            withAsync (simpleCountingServer srvQ 0) $ \_ -> do
                r1 <- callCountUp srvQ
                r1 `shouldBe` Just 0
                r2 <- callCountUp srvQ
                r2 `shouldBe` Just 1

        it "timeouts call method when server is not responding" $ do
            srvQ <- newMessageQueue
            blocker <- newEmptyMVar
            let initializer = pure ()
                cleanup _   = pure ()
                handler _ _ = takeMVar blocker $> Right ()
                srv             = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call (CallTimeout 10000) srvQ AskFst
                (r1 :: Maybe Int) `shouldBe` Nothing

    describe "SimpleOneForOneSupervisor" $ do
        it "it starts a dynamic child" $ do
            trigger <- newEmptyMVar
            mark <- newEmptyMVar
            blocker <- newEmptyMVar
            var <- newTVarIO (0 :: Int)
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                for_ procs $ newChild def sv
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSimpleOneForOneSupervisor sv) $ \_ -> do
                for_ procs $ newChild def sv
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> castFinish ch
                threadDelay 10000
            reports <- for childMons takeMVar
            length reports `shouldBe` volume
            let normalCount = length . filter ((==) Normal . fst) $ reports
                killedCount = length . filter ((==) Killed . fst) $ reports
            normalCount `shouldNotBe` 0
            killedCount `shouldNotBe` 0
            normalCount + killedCount `shouldBe` volume

    describe "IntenseRestartDetector" $ do
        it "returns True if 1 crash in 0 maximum restart intensity" $ do
            let crash       = TimeSpec 0 0
                detector    = newIntenseRestartDetector $ RestartSensitivity 0 (TimeSpec 5 0)
                (result, _) = detectIntenseRestart detector crash
            result `shouldBe` True

        it "returns True if 1 crash in 0 maximum restart intensity regardless with period" $ do
            let crash       = TimeSpec 0 0
                detector    = newIntenseRestartDetector $ RestartSensitivity 0 (TimeSpec 0 0)
                (result, _) = detectIntenseRestart detector crash
            result `shouldBe` True

        it "returns False if 1 crash in 1 maximum restart intensity" $ do
            let crash       = TimeSpec 0 0
                detector    = newIntenseRestartDetector $ RestartSensitivity 1 (TimeSpec 5 0)
                (result, _) = detectIntenseRestart detector crash
            result `shouldBe` False

        it "returns True if 2 crash in 1 maximum restart intensity within given period" $ do
            let crash1          = TimeSpec 0 0
                detector1       = newIntenseRestartDetector $ RestartSensitivity 1 (TimeSpec 5 0)
                (_, detector2)  = detectIntenseRestart detector1 crash1
                crash2          = TimeSpec 2 0
                (result, _)     = detectIntenseRestart detector2 crash2
            result `shouldBe` True

        it "returns False if 2 crash in 1 maximum restart intensity but longer interval than given period" $ do
            let crash1          = TimeSpec 0 0
                detector1       = newIntenseRestartDetector $ RestartSensitivity 1 (TimeSpec 5 0)
                (_, detector2)  = detectIntenseRestart detector1 crash1
                crash2          = TimeSpec 10 0
                (result, _)     = detectIntenseRestart detector2 crash2
            result `shouldBe` False

        it "returns False if 1 crash in 2 maximum restart intensity" $ do
            let crash       = TimeSpec 0 0
                detector    = newIntenseRestartDetector $ RestartSensitivity 2 (TimeSpec 5 0)
                (result, _) = detectIntenseRestart detector crash
            result `shouldBe` False

        it "returns False if 2 crash in 2 maximum restart intensity" $ do
            let crash1          = TimeSpec 0 0
                detector1       = newIntenseRestartDetector $ RestartSensitivity 2 (TimeSpec 5 0)
                (_, detector2)  = detectIntenseRestart detector1 crash1
                crash2          = TimeSpec 2 0
                (result, _)     = detectIntenseRestart detector2 crash2
            result `shouldBe` False

        it "returns True if 3 crash in 2 maximum restart intensity within given period" $ do
            let crash1          = TimeSpec 0 0
                detector1       = newIntenseRestartDetector $ RestartSensitivity 2 (TimeSpec 5 0)
                (_, detector2)  = detectIntenseRestart detector1 crash1
                crash2          = TimeSpec 2 0
                (_, detector3)  = detectIntenseRestart detector2 crash2
                crash3          = TimeSpec 3 0
                (result, _)     = detectIntenseRestart detector3 crash3
            result `shouldBe` True

        it "returns False if 3 crash in 2 maximum restart intensity but longer interval than given period" $ do
            let crash1          = TimeSpec 0 0
                detector1       = newIntenseRestartDetector $ RestartSensitivity 2 (TimeSpec 5 0)
                (_, detector2)  = detectIntenseRestart detector1 crash1
                crash2          = TimeSpec 2 0
                (_, detector3)  = detectIntenseRestart detector2 crash2
                crash3          = TimeSpec 6 0
                (result, _)     = detectIntenseRestart detector3 crash3
            result `shouldBe` False

    describe "One-for-one Supervisor with static childlen" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts finished children with permanent restart type" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 3 } procs) $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]
                for_ childQs $ \ch -> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
                rs3 <- for childQs callCountUp
                rs3 `shouldBe` Just <$> [1,2,3]
                rs4 <- for childQs callCountUp
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 2 } procs) $ \_ -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                rs <- for markers $  \m -> isEmptyMVar m
                rs `shouldBe` [False, True]

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \_ -> do
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 2000
            rs <- for [1..volume] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newMessageQueue
                let monitor reason tid  = sendMessage childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityIntensity = 1000 } procs) $ \_ -> do
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..volume]
                async $ for_ childQs $ \ch -> threadDelay 1 *> castFinish ch
                threadDelay 10000
            reports <- for childMons receive
            length reports `shouldBe` volume
            let normalCount = length . filter ((==) Normal . fst) $ reports
                killedCount = length . filter ((==) Killed . fst) $ reports
            normalCount `shouldNotBe` 0
            killedCount `shouldNotBe` 0
            normalCount + killedCount `shouldBe` volume

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3]
                castFinish (head childQs)
                report1 <- takeMVar (head childMons)
                fst report1 `shouldBe` Normal
                rs3 <- for childQs callCountUp
                rs3 `shouldBe` Just <$> [1,4]
                castFinish (head childQs)
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> threadDelay 1000 *> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> threadDelay 1000 *> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids $ \tid -> threadDelay 1000 *> killThread tid
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

    describe "One-for-all Supervisor with static childlen" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts all static children when one of permanent children finished" $ do
            rs <- for [1,2,3] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]
                castFinish (head childQs)
                reports <- for childMons takeMVar
                fst <$> reports `shouldBe` [Normal, Killed, Killed]
                rs3 <- for childQs callCountUp
                rs3 `shouldBe` Just <$> [1,2,3]
                rs4 <- for childQs callCountUp
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newMessageQueue
                let monitor reason tid  = sendMessage childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \_ -> do
                rs <- for childQs callCountUp
                rs `shouldBe` Just <$> [1..volume]
                async $ threadDelay 1 *> castFinish (head childQs)
                threadDelay 10000
            reports <- for childMons receive
            (fst . head) reports `shouldBe` Normal
            tail reports `shouldSatisfy` all ((==) Killed . fst)

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3]
                castFinish (head childQs)
                reports1 <- for childMons takeMVar
                fst <$> reports1 `shouldBe` [Normal, Killed]
                rs3 <- for childQs callCountUp
                rs3 `shouldBe` Just <$> [1,2]
                castFinish (head childQs)
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Transient $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
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
            sv <- newMessageQueue
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
                childQ <- newMessageQueue
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newProcessSpec [monitor] Temporary $ simpleCountingServer childQ n $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> castFinish ch
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
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
            sv <- newMessageQueue
            withAsync(newSupervisor sv OneForAll def procs) $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childQ <- newMessageQueue
                let process             = newProcessSpec [] Permanent $ simpleCountingServer childQ n $> ()
                pure (childQ, process)
            let (childQs, procs) = unzip rs
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def { restartSensitivityPeriod = TimeSpec 0 1000 } procs) $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> threadDelay 1000 *> castFinish ch
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]

        it "longer interval multiple crash of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                marker <- newTVarIO False
                trigger <- newEmptyMVar
                let process             = newProcessSpec [] Transient $ atomically (writeTVar marker True) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, process)
            let (markers, triggers, procs) = unzip3 rs
            sv <- newMessageQueue
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
            sv <- newMessageQueue
            withAsync (newSupervisor sv OneForAll def procs) $ \a -> do
                threadDelay 10000
                tids <- for markers readTVarIO
                tids `shouldSatisfy` notElem myTid
                for_ tids killThread
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                tids <- for markers readTVarIO
                tids `shouldSatisfy` notElem myTid
