{-# OPTIONS_GHC -Wno-orphans       #-}
{-# OPTIONS_GHC -Wno-type-defaults #-}

module Control.Concurrent.SupervisorSpec where

import           Data.Default                  (def)
import           Data.Foldable                 (for_)
import           Data.Functor                  (($>))
import           Data.List                     (unzip4)
import           Data.Maybe                    (isJust, isNothing)
import           Data.Traversable              (for)
import           Data.Typeable                 (typeOf)
import           System.Clock                  (TimeSpec (..))
import           UnliftIO                      (StringException (..), async,
                                                asyncThreadId, atomically,
                                                cancel, fromException,
                                                isEmptyMVar, mask_,
                                                newEmptyMVar, newTQueueIO,
                                                newTVarIO, poll, putMVar,
                                                readMVar, readTQueue,
                                                readTVarIO, takeMVar,
                                                throwString, wait, withAsync,
                                                withAsyncWithUnmask,
                                                writeTQueue, writeTVar)
import           UnliftIO.Concurrent           (killThread, myThreadId,
                                                threadDelay)

import           Test.Hspec
import           Test.Hspec.QuickCheck

import           Control.Concurrent.Supervisor hiding (length)

{-# ANN module "HLint: ignore Reduce duplication" #-}
{-# ANN module "HLint: ignore Use head" #-}

instance Eq ExitReason where
    (UncaughtException _) == _  = error "should not compare exception by Eq"
    _ == (UncaughtException _)  = error "should not compare exception by Eq"
    Normal == Normal            = True
    Killed == Killed            = True
    _ == _                      = False

reasonToString :: ExitReason -> String
reasonToString (UncaughtException e)    = toStr $ fromException e
  where
    toStr (Just (StringException str _)) = str
    toStr _                              = error "Not a StringException"
reasonToString _                        = error "ExitReason is not Uncaught Exception"

data ConstServerCmd = AskFst (ServerCallback Int) | AskSnd (ServerCallback Char)

data TickerServerCmd = Tick (ServerCallback Int) | Tack

tickerServer :: Inbox TickerServerCmd -> IO Int
tickerServer = newStateMachine 0 handler
  where
    handler s (Tick cont) = cont s $> Right (s + 1)
    handler s Tack        = pure $ Right (s + 1)

data SimpleCountingServerCmd
    = CountUp (ServerCallback Int)
    | Finish

simpleCountingServer :: Int -> Inbox SimpleCountingServerCmd -> IO Int
simpleCountingServer n = newStateMachine n handler
  where
    handler s (CountUp cont) = cont s $> Right (s + 1)
    handler s Finish         = pure (Left s)

callCountUp :: ActorQ SimpleCountingServerCmd -> IO (Maybe Int)
callCountUp q = call def q CountUp

castFinish :: ActorQ SimpleCountingServerCmd -> IO ()
castFinish q = cast q Finish

spec :: Spec
spec = do
    describe "Actor" $ do
        prop "accepts ActorHandler and returns action with ActorQ" $ \n -> do
            Actor actorQ action <- newActor receive
            send actorQ (n :: Int)
            r2 <- action
            r2 `shouldBe` n

        prop "can send a message to itself" $ \n -> do
            Actor actorQ action <- newActor $ \inbox -> do
                msg <- receive inbox
                sendToMe inbox (msg + 1)
                receive inbox
            send actorQ (n :: Int)
            r2 <- action
            r2 `shouldBe` (n + 1)

    describe "State machine behavior" $ do
        it "returns result when event handler returns Left" $ do
            Actor actorQ statem <- newActor $ newStateMachine () $ \_ _ -> pure $ Left "Hello"
            send actorQ ()
            r <- statem
            r `shouldBe` "Hello"

        it "consumes message in the queue until exit" $ do
            let until5 q 5 = pure $ Left ("Done", q)
                until5 q _ = pure $ Right q
                actorHandler inbox = newStateMachine inbox until5 inbox
            Actor actorQ statem <- newActor actorHandler
            for_ [1..7] $ send actorQ
            (r, lastQ) <- statem
            r `shouldBe` "Done"
            msg <- receive lastQ
            msg `shouldBe` 6

        it "passes next state with Right" $ do
            let handler True  _ = pure $ Right False
                handler False _ = pure $ Left "Finished"
            Actor actorQ statem <- newActor $ newStateMachine True handler
            for_ [(), ()] $ send actorQ
            r <- statem
            r `shouldBe` "Finished"

        it "runs state machine by consuming messages until handler returns Left" $ do
            let handler n 10 = pure $ Left (n + 10)
                handler n x  = pure $ Right (n + x)
            Actor actorQ statem <- newActor $ newStateMachine 0 handler
            for_ [1..100] $ send actorQ
            r <- statem
            r `shouldBe` 55

    describe "Server" $ do
        it "has call method which return value synchronously" $ do
            let handler s (AskFst cont) = cont (fst s) $> Right s
                handler s (AskSnd cont) = cont (snd s) $> Right s
            Actor srvQ srv <- newActor $ newStateMachine (1, 'a') handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ AskFst
                r1 `shouldBe` Just 1
                r2 <- call def srvQ AskSnd
                r2 `shouldBe` Just 'a'

        it "keeps its own state and cast changes the state" $ do
            Actor srvQ srv <- newActor tickerServer
            withAsync srv $ \_ -> do
                r1 <- call def srvQ Tick
                r1 `shouldBe` Just 0
                cast srvQ Tack
                r2 <- call def srvQ Tick
                r2 `shouldBe` Just 2

        it "keeps its own state and callIgnore changes the state" $ do
            Actor srvQ srv <- newActor tickerServer
            withAsync srv $ \_ -> do
                r1 <- call def srvQ Tick
                r1 `shouldBe` Just 0
                callIgnore srvQ Tick
                r2 <- call def srvQ Tick
                r2 `shouldBe` Just 2

        it "keeps its own state and call can change the state" $ do
            Actor srvQ srv <- newActor $ simpleCountingServer 0
            withAsync srv $ \_ -> do
                r1 <- callCountUp srvQ
                r1 `shouldBe` Just 0
                r2 <- callCountUp srvQ
                r2 `shouldBe` Just 1

        it "timeouts call method when server is not responding" $ do
            blocker <- newEmptyMVar
            let handler _ _ = takeMVar blocker $> Right ()
            Actor srvQ srv <- newActor $ newStateMachine () handler
            withAsync srv $ \_ -> do
                r1 <- call (CallTimeout 10000) srvQ AskFst
                (r1 :: Maybe Int) `shouldBe` Nothing

    describe "Monitored IO action" $ do
        it "reports exit code Normal on normal exit" $ do
            trigger <- newEmptyMVar
            mark <- newEmptyMVar
            let monitor reason tid  = putMVar mark (reason, tid)
                monitoredAction     = watch monitor $ readMVar trigger $> ()
            mask_ $ withAsyncWithUnmask monitoredAction $ \a -> do
                noReport <- isEmptyMVar mark
                noReport `shouldBe` True
                putMVar trigger ()
                report <- takeMVar mark
                report `shouldBe` (Normal, asyncThreadId a)

        it "reports exit code UncaughtException on synchronous exception which wasn't caught" $ do
            trigger <- newEmptyMVar
            mark <- newEmptyMVar
            let monitor reason tid  = putMVar mark (reason, tid)
                monitoredAction     = watch monitor $ readMVar trigger *> throwString "oops" $> ()
            mask_ $ withAsyncWithUnmask monitoredAction $ \a -> do
                noReport <- isEmptyMVar mark
                noReport `shouldBe` True
                putMVar trigger ()
                (reason, tid) <- takeMVar mark
                tid `shouldBe` asyncThreadId a
                reasonToString reason `shouldBe` "oops"

        it "reports exit code Killed when it received asynchronous exception" $ do
            blocker <- newEmptyMVar
            mark <- newEmptyMVar
            let monitor reason tid  = putMVar mark (reason, tid)
                monitoredAction     = watch monitor $ readMVar blocker $> ()
            mask_ $ withAsyncWithUnmask monitoredAction $ \a -> do
                noReport <- isEmptyMVar mark
                noReport `shouldBe` True
                cancel a
                report <- takeMVar mark
                report `shouldBe` (Killed, asyncThreadId a)

        it "can nest monitors and notify its normal exit to both" $ do
            trigger <- newEmptyMVar
            mark1 <- newEmptyMVar
            mark2 <- newEmptyMVar
            let monitor1 reason tid = putMVar mark1 (reason, tid)
                monitoredAction1    = watch monitor1 $ readMVar trigger $> ()
                monitor2 reason tid = putMVar mark2 (reason, tid)
                monitoredAction2    = nestWatch monitor2 monitoredAction1
            mask_ $ withAsyncWithUnmask monitoredAction2 $ \a -> do
                noReport1 <- isEmptyMVar mark1
                noReport1 `shouldBe` True
                noReport2 <- isEmptyMVar mark2
                noReport2 `shouldBe` True
                putMVar trigger ()
                report1 <- takeMVar mark1
                report1 `shouldBe` (Normal, asyncThreadId a)
                report2 <- takeMVar mark2
                report2 `shouldBe` (Normal, asyncThreadId a)

        it "can nest monitors and notify UncaughtException to both" $ do
            trigger <- newEmptyMVar
            mark1 <- newEmptyMVar
            mark2 <- newEmptyMVar
            let monitor1 reason tid = putMVar mark1 (reason, tid)
                monitoredAction1    = watch monitor1 $ readMVar trigger *> throwString "oops" $> ()
                monitor2 reason tid = putMVar mark2 (reason, tid)
                monitoredAction2    = nestWatch monitor2 monitoredAction1
            mask_ $ withAsyncWithUnmask monitoredAction2 $ \a -> do
                noReport1 <- isEmptyMVar mark1
                noReport1 `shouldBe` True
                noReport2 <- isEmptyMVar mark2
                noReport2 `shouldBe` True
                putMVar trigger ()
                (reason1, tid1) <- takeMVar mark1
                tid1 `shouldBe` asyncThreadId a
                reasonToString reason1 `shouldBe` "oops"
                (reason2, tid2) <- takeMVar mark2
                tid2 `shouldBe` asyncThreadId a
                reasonToString reason2 `shouldBe` "oops"

        it "can nest monitors and notify Killed to both" $ do
            blocker <- newEmptyMVar
            mark1 <- newEmptyMVar
            mark2 <- newEmptyMVar
            let monitor1 reason tid = putMVar mark1 (reason, tid)
                monitoredAction1    = watch monitor1 $ readMVar blocker $> ()
                monitor2 reason tid = putMVar mark2 (reason, tid)
                monitoredAction2    = nestWatch monitor2 monitoredAction1
            mask_ $ withAsyncWithUnmask monitoredAction2 $ \a -> do
                noReport1 <- isEmptyMVar mark1
                noReport1 `shouldBe` True
                noReport2 <- isEmptyMVar mark2
                noReport2 `shouldBe` True
                cancel a
                report1 <- takeMVar mark1
                report1 `shouldBe` (Killed, asyncThreadId a)
                report2 <- takeMVar mark2
                report2 `shouldBe` (Killed, asyncThreadId a)

        it "can nest many monitors and notify its normal exit to all" $ do
            trigger <- newEmptyMVar
            marks <- for [1..100] $ const newEmptyMVar
            let monitors              = map (\mark reason tid -> putMVar mark (reason, tid)) marks
                nestedMonitoredAction = foldr nestWatch (noWatch $ readMVar trigger $> ()) monitors
            mask_ $ withAsyncWithUnmask nestedMonitoredAction $ \a -> do
                noReports <- for marks isEmptyMVar
                noReports `shouldSatisfy` and
                putMVar trigger ()
                reports <- for marks takeMVar
                reports `shouldSatisfy` all (== (Normal, asyncThreadId a))

        it "can nest many monitors and notify UncaughtException to all" $ do
            trigger <- newEmptyMVar
            marks <- for [1..100] $ const newEmptyMVar
            let monitors              = map (\mark reason tid -> putMVar mark (reason, tid)) marks
                nestedMonitoredAction = foldr nestWatch (noWatch $ readMVar trigger *> throwString "oops" $> ()) monitors
            mask_ $ withAsyncWithUnmask nestedMonitoredAction $ \a -> do
                noReports <- for marks isEmptyMVar
                noReports `shouldSatisfy` and
                putMVar trigger ()
                reports <- for marks takeMVar
                reports `shouldSatisfy` all ((==) (asyncThreadId a) . snd)
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)

        it "can nest many monitors and notify Killed to all" $ do
            blocker <- newEmptyMVar
            marks <- for [1..100] $ const newEmptyMVar
            let monitors              = map (\mark reason tid -> putMVar mark (reason, tid)) marks
                nestedMonitoredAction = foldr nestWatch (noWatch $ readMVar blocker $> ()) monitors
            mask_ $ withAsyncWithUnmask nestedMonitoredAction $ \a -> do
                noReports <- for marks isEmptyMVar
                noReports `shouldSatisfy` and
                cancel a
                reports <- for marks takeMVar
                reports `shouldSatisfy` all (== (Killed, asyncThreadId a))

    describe "SimpleOneForOneSupervisor" $ do
        it "starts a dynamic child" $ do
            trigger <- newEmptyMVar
            mark <- newEmptyMVar
            blocker <- newEmptyMVar
            var <- newTVarIO (0 :: Int)
            Actor svQ sv <- newActor newSimpleOneForOneSupervisor
            withAsync sv $ \_ -> do
                maybeChildAsync <- newChild def svQ $ newChildSpec Temporary $ do
                    readMVar trigger
                    atomically $ writeTVar var 1
                    putMVar mark ()
                    _ <- readMVar blocker
                    pure ()
                isJust maybeChildAsync `shouldBe` True
                currentVal0 <- readTVarIO var
                currentVal0 `shouldBe` 0
                putMVar trigger ()
                readMVar mark
                currentVal1 <- readTVarIO var
                currentVal1 `shouldBe` 1

        it "does not restart finished dynamic child regardless restart type" $ do
            Actor svQ sv <- newActor newSimpleOneForOneSupervisor
            withAsync sv $ \_ -> for_ [Permanent, Transient, Temporary] $ \restart -> do
                startMark <- newEmptyMVar
                trigger <- newEmptyMVar
                finishMark <- newEmptyMVar
                Just _ <- newChild def svQ $ newChildSpec restart $ do
                    putMVar startMark ()
                    readMVar trigger
                    putMVar finishMark ()
                    pure ()
                takeMVar startMark
                putMVar trigger ()
                takeMVar finishMark
                threadDelay 1000
                r <- isEmptyMVar startMark
                r `shouldBe` True

        it "does not exit itself by massive child crash" $ do
            Actor svQ sv <- newActor newSimpleOneForOneSupervisor
            withAsync sv $ \a -> do
                blocker <- newEmptyMVar
                for_ [1..10] $ \_ -> do
                    Just tid <- newChild def svQ $ newChildSpec Permanent $ readMVar blocker $> ()
                    killThread tid
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                maybeAsync <- newChild def svQ $ newChildSpec Permanent $ readMVar blocker $> ()
                isJust maybeAsync `shouldBe` True

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor svQ sv <- newActor newSimpleOneForOneSupervisor
            withAsync sv $ \_ -> do
                for_ procs $ newChild def svQ
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor svQ sv <- newActor newSimpleOneForOneSupervisor
            withAsync sv $ \_ -> do
                for_ procs $ newChild def svQ
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..volume]
                _ <- async $ for_ childQs $ \ch -> threadDelay 1000 *> castFinish ch
                threadDelay (100 * 1000)
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

    describe "One-for-one Supervisor with static children" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, _, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts finished children with permanent restart type" $ do
            rs <- for [1,2,3] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityIntensity = 3 } procs
            withAsync sv $ \_ -> do
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
                    process             = newMonitoredChildSpec restart $ watch monitor $ putMVar marker () *> takeMVar trigger $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityIntensity = 2 } procs
            withAsync sv $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Normal . fst)
                threadDelay 1000
                rs2 <- for markers $  \m -> isEmptyMVar m
                rs2 `shouldBe` [True, True]

        it "restarts crashed transient child but does not restart crashed temporary child" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec restart $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityIntensity = 2 } procs
            withAsync sv $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
                threadDelay 10000
                rs2 <- for markers $  \m -> isEmptyMVar m
                rs2 `shouldBe` [False, True]

        it "restarts killed transient child but does not restart killed temporary child" $ do
            blocker <- newEmptyMVar
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec restart $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityIntensity = 2 } procs
            withAsync sv $ \_ -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 10000
                rs1 <- for markers $ \m -> isEmptyMVar m
                rs1 `shouldBe` [False, True]

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 2000
            rs <- for [1..volume] $ \n -> do
                childMon <- newTQueueIO
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityIntensity = 1000 } procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..volume]
                _ <- async $ for_ childQs $ \ch -> threadDelay 1000 *> castFinish ch
                threadDelay (100 * 1000)
            reports <- for childMons $ atomically . readTQueue
            length reports `shouldBe` volume
            let normalCount = length . filter ((==) Normal . fst) $ reports
                killedCount = length . filter ((==) Killed . fst) $ reports
            normalCount `shouldNotBe` 0
            killedCount `shouldNotBe` 0
            normalCount + killedCount `shouldBe` volume

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
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
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive killing temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def procs
            withAsync sv $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs
            withAsync sv $ \a -> do
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
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs
            withAsync sv $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> threadDelay 1000 *> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple killing transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForOne def { restartSensitivityPeriod = TimeSpec 0 1000 } procs
            withAsync sv $ \a -> do
                tids <- for markers takeMVar
                for_ tids $ \tid -> threadDelay 1000 *> killThread tid
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

    describe "One-for-all Supervisor with static children" $ do
        it "automatically starts children based on given ProcessSpec list" $ do
            rs <- for [1,2,3] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, _, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1,2,3]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2,3,4]

        it "automatically restarts all static children when one of permanent children finished" $ do
            rs <- for [1,2,3] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
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
                    process             = newMonitoredChildSpec restart $ watch monitor $ putMVar marker () *> takeMVar trigger $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def { restartSensitivityIntensity = 2 } procs
            withAsync sv $ \_ -> do
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
                    process             = newMonitoredChildSpec restart $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def { restartSensitivityIntensity = 2 } procs
            withAsync sv $ \a -> do
                for_ markers takeMVar
                putMVar (head triggers) ()
                reports <- for childMons takeMVar
                fst (reports !! 0) `shouldSatisfy` ((==) "oops" . reasonToString)
                fst (reports !! 1) `shouldBe` Killed
                threadDelay 1000
                tids <- for markers takeMVar
                killThread $ head tids
                reports1 <- for childMons takeMVar
                fst <$> reports1 `shouldBe` [Killed, Killed]
                threadDelay 1000
                rs3 <- for markers takeMVar
                typeOf <$> rs3 `shouldBe` replicate 2 (typeOf $ asyncThreadId a)

        it "does not restarts any children even if a temporary child crashed" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec restart $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` [(), ()]
                putMVar (triggers !! 1) ()
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldSatisfy` ((==) "oops" . reasonToString)
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
                rs2 `shouldBe` [True, True]

        it "does not restarts any children even if a temporary child killed" $ do
            rs <- for [Transient, Temporary] $ \restart -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec restart $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, _, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
                tids <- for markers takeMVar
                killThread $ tids !! 1
                (reason, _) <- takeMVar $ childMons !! 1
                reason `shouldBe` Killed
                threadDelay 1000
                rs2 <- for markers isEmptyMVar
                rs2 `shouldBe` [True, True]

        it "kills all children when it is killed" $ do
            rs <- for [1..10] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
            reports <- for childMons takeMVar
            reports `shouldSatisfy` all ((==) Killed . fst)

        it "can be killed when children is finishing at the same time" $ do
            let volume = 1000
            rs <- for [1..volume] $ \n -> do
                childMon <- newTQueueIO
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = atomically $ writeTQueue childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \_ -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..volume]
                _ <- async $ threadDelay 1000 *> castFinish (head childQs)
                threadDelay (100 * 1000)
            reports <- for childMons $ atomically . readTQueue
            (fst . head) reports `shouldBe` Normal
            tail reports `shouldSatisfy` all ((==) Killed . fst)

        it "intensive normal exit of permanent child causes termination of Supervisor itself" $ do
            rs <- for [1,2] $ \n -> do
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Permanent $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
            rs <- for [1,2] $ \_ -> do
                marker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Transient $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
                childMon <- newEmptyMVar
                Actor childQ child <- newActor $ simpleCountingServer n
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ child $> ()
                pure (childQ, childMon, process)
            let (childQs, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
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
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                trigger <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ putMVar marker () *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, childMon, process)
            let (markers, triggers, childMons, procs) = unzip4 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
                rs1 <- for markers takeMVar
                rs1 `shouldBe` replicate 10 ()
                for_ triggers $ \t -> putMVar t ()
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) "oops" . reasonToString . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "intensive killing temporary child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \_ -> do
                marker <- newEmptyMVar
                blocker <- newEmptyMVar
                childMon <- newEmptyMVar
                let monitor reason tid  = putMVar childMon (reason, tid)
                    process             = newMonitoredChildSpec Temporary $ watch monitor $ (myThreadId >>= putMVar marker) *> takeMVar blocker $> ()
                pure (marker, childMon, process)
            let (markers, childMons, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
                tids <- for markers takeMVar
                for_ tids killThread
                reports <- for childMons takeMVar
                reports `shouldSatisfy` all ((==) Killed . fst)
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing

        it "longer interval multiple normal exit of permanent child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \n -> do
                Actor childQ child <- newActor $ simpleCountingServer n
                let process             = newChildSpec Permanent $ child $> ()
                pure (childQ, process)
            let (childQs, procs) = unzip rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def { restartSensitivityPeriod = TimeSpec 0 1000 } procs
            withAsync sv $ \a -> do
                rs1 <- for childQs callCountUp
                rs1 `shouldBe` Just <$> [1..10]
                rs2 <- for childQs callCountUp
                rs2 `shouldBe` Just <$> [2..11]
                for_ childQs $ \ch -> threadDelay 1000 *> castFinish ch
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                rs3 <- for childQs callCountUp
                rs3 `shouldBe` Just <$> [1..10]

        it "longer interval multiple crash of transient child does not terminate Supervisor" $ do
            rs <- for [1..10] $ \_ -> do
                marker <- newTVarIO False
                trigger <- newEmptyMVar
                let process             = newChildSpec Transient $ atomically (writeTVar marker True) *> takeMVar trigger *> throwString "oops" $> ()
                pure (marker, trigger, process)
            let (markers, triggers, procs) = unzip3 rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def { restartSensitivityPeriod = TimeSpec 0 1000 } procs
            withAsync sv $ \a -> do
                threadDelay 1000
                rs1 <- for markers readTVarIO
                rs1 `shouldBe` replicate 10 True
                for_ markers $ \m -> atomically $ writeTVar m True
                for_ triggers $ \t -> threadDelay 1000 *> putMVar t ()
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                rs2 <- for markers readTVarIO
                rs2 `shouldBe` replicate 10 True

        it "longer interval multiple killing transient child does not terminate Supervisor" $ do
            myTid <- myThreadId
            rs <- for [1..3] $ \_ -> do
                marker <- newTVarIO myTid
                blocker <- newEmptyMVar
                let process             = newChildSpec Transient $ (myThreadId >>= atomically . writeTVar marker) *> takeMVar blocker $> ()
                pure (marker, process)
            let (markers, procs) = unzip rs
            Actor _ sv <- newActor $ newSupervisor OneForAll def procs
            withAsync sv $ \a -> do
                threadDelay 10000
                tids <- for markers readTVarIO
                tids `shouldSatisfy` notElem myTid
                for_ tids killThread
                threadDelay 1000
                r <- poll a
                r `shouldSatisfy` isNothing
                tids1 <- for markers readTVarIO
                tids1 `shouldSatisfy` notElem myTid
