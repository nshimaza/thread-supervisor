module Control.Concurrent.SupervisorInternal where

import           Prelude                       hiding (lookup)

import           Control.Concurrent            (ThreadId, myThreadId)
import           Control.Concurrent.Async      (Async, async, asyncThreadId,
                                                asyncWithUnmask, cancel)
import           Control.Concurrent.STM.TMVar  (TMVar, newEmptyTMVarIO,
                                                putTMVar, takeTMVar)
import           Control.Concurrent.STM.TQueue (TQueue, readTQueue, writeTQueue)
import           Control.Exception.Safe        (SomeException, bracket,
                                                catchAsync, isSyncException,
                                                mask_, uninterruptibleMask_)
import           Control.Monad                 (void)
import           Control.Monad.STM             (atomically)
import           Data.Default
import           Data.Foldable                 (for_, traverse_)
import           Data.Functor                  (($>))
import           Data.IORef                    (IORef, modifyIORef', newIORef,
                                                readIORef, writeIORef)
import           Data.Map.Strict               (Map, delete, elems, empty,
                                                insert, keys, lookup)
import           System.Clock                  (Clock (Monotonic),
                                                TimeSpec (..), diffTimeSpec,
                                                getTime)
import           System.Timeout                (timeout)

import           Data.DelayedQueue             (DelayedQueue,
                                                newEmptyDelayedQueue, pop, push)

{-
    Basic message queue and state machine behavior.
-}
type MessageQueue a = TQueue a

newStateMachine
    :: MessageQueue message -- ^ Event input queue of the state machine.
    -> state                -- ^ Initial state of the state machinwe.
    -> (state -> message -> IO (Either result state))
                            -- ^ Event handler which processes event and returns result or next state.
    -> IO result
newStateMachine inbox initialState messageHandler = go $ Right initialState
  where
    go (Right state) = atomically (readTQueue inbox) >>= messageHandler state >>= go
    go (Left result) = pure result

sendMessage
    :: MessageQueue message -- ^ Queue the event to be sent.
    -> message              -- ^ Sent event.
    -> IO ()
sendMessage q = atomically . writeTQueue q


{-
    Sever behavior
-}
data ServerCommand arg ret
    = Cast arg
    | Call arg (TMVar ret)

type ServerQueue arg ret = MessageQueue (ServerCommand arg ret)

newServer
    :: ServerQueue arg ret                          -- ^ Message queue.
    -> IO state                                     -- ^ Initialize.
    -> (state -> IO a)                              -- ^ Cleanup.
    -> (state -> arg -> IO (ret, Either b state))   -- ^ Call message handler.
    -> IO b
newServer inbox init cleanup handler = bracket init cleanup $ \state ->
    newStateMachine inbox state server
  where
    server state (Cast arg)     = snd <$> handler state arg
    server state (Call arg ret) = do
        (result, nextState) <- handler state arg
        atomically $ putTMVar ret result
        pure nextState

{-|
    Send an asynchronous request to the message queue of a server.
-}
cast
    :: ServerQueue arg ret  -- ^ Message queue.
    -> arg                  -- ^ argument of the cast message.
    -> IO ()
cast srv = sendMessage srv . Cast

newtype CallTimeout = CallTimeout Int

instance Default CallTimeout where
    def = CallTimeout 5000000

{-|
    Make a synchronous call to a server.  Call can fail by timeout.
-}
call
    :: CallTimeout          -- ^ Timeout.
    -> ServerQueue arg ret  -- ^ Message queue.
    -> arg                  -- ^ Request to the server.
    -> IO (Maybe ret)       -- ^ Return value or Nothing when request timeout.
call (CallTimeout usec) srv req = do
    r <- newEmptyTMVarIO
    sendMessage srv $ Call req r
    timeout usec . atomically . takeTMVar $ r

{-
    Make an asynchronous call to a server and give result in CPS style.
    The return value is delivered to given callback function.  It also can fail by timeout.
    It is useful to convert return value of 'call' to a message of calling process asynchronously
    so that calling process can continue processing instead of blocking at 'call'.

    Use this function with care because there is no guaranteed cancellation of background worker
    thread other than timeout.  Giving infinite timeout (zero) to the 'Timeout' argument may cause
    the background thread left to run, possibly indefinitely.
-}
callAsync
    :: CallTimeout          -- ^ Timeout.
    -> ServerQueue arg ret  -- ^ Message queue.
    -> arg                  -- ^ argument of the call message.
    -> (Maybe ret -> IO a)  -- ^ callback to process return value of the call.  Nothing is given on timeout.
    -> IO (Async a)
callAsync timeout srv req cont = async $ call timeout srv req >>= cont


{-
    Supervisable thread.
-}
data Restart = Permanent | Transient | Temporary deriving (Eq, Show)
data ExitReason = Normal | UncaughtException | Killed deriving (Eq, Show)
type Monitor = ExitReason -> ThreadId -> IO ()
data ProcessSpec = ProcessSpec [Monitor] Restart (IO ())

newProcessSpec :: [Monitor] -> Restart -> IO () -> ProcessSpec
newProcessSpec = ProcessSpec

addMonitor :: Monitor -> ProcessSpec -> ProcessSpec
addMonitor monitor (ProcessSpec monitors restart action) = ProcessSpec (monitor:monitors) restart action

type ProcessMap = IORef (Map ThreadId (Async (), ProcessSpec))

newProcessMap :: IO ProcessMap
newProcessMap = newIORef empty

newProcess
    :: ProcessMap   -- ^ Map of current live processes where the new process to be added.
     -> ProcessSpec -- ^ Specification of newly started process.
     -> IO (Async ())
newProcess procMap procSpec@(ProcessSpec monitors _ action) = mask_ $ do
    a <- asyncWithUnmask $ \unmask ->
        let notify reason   = uninterruptibleMask_ . traverse_ (\monitor -> myThreadId >>= monitor reason)
            toReason e      = if isSyncException (e :: SomeException) then UncaughtException else Killed
        in (unmask action *> notify Normal monitors) `catchAsync` \e -> notify (toReason e) monitors
    modifyIORef' procMap $ insert (asyncThreadId a) (a, procSpec)
    pure a

{-
    Restart intensity handling.
-}
newtype RestartPeriod = RestartPeriod TimeSpec

instance Default RestartPeriod where
    def = RestartPeriod TimeSpec { sec = 5, nsec = 0 }

newtype RestartIntensity = RestartIntensity Int

instance Default RestartIntensity where
    def = RestartIntensity 1

newtype RestartHist = RestartHist (DelayedQueue TimeSpec) deriving (Eq, Show)

newRestartHist :: RestartIntensity -> RestartHist
newRestartHist (RestartIntensity maxR) = RestartHist $ newEmptyDelayedQueue maxR

getCurrentTime :: IO TimeSpec
getCurrentTime = getTime Monotonic

isRestartIntense :: RestartPeriod -> TimeSpec -> RestartHist -> (Bool, RestartHist)
isRestartIntense (RestartPeriod maxT) lastRestart (RestartHist dq) =
    let histWithLastRestart = push lastRestart dq
    in case pop histWithLastRestart of
        Nothing                         ->  (False, RestartHist histWithLastRestart)
        Just (oldestRestart, nextHist)    ->  (lastRestart - oldestRestart <= maxT, RestartHist nextHist)

isRestartIntenseNow :: RestartPeriod -> RestartHist -> IO (Bool, RestartHist)
isRestartIntenseNow maxT restartHist = do
    currentTime <- getCurrentTime
    pure $ isRestartIntense maxT currentTime restartHist

{-
    Supervisor
-}
data SupervisorCommand
    = Down ExitReason ThreadId
    | StartChild ProcessSpec (TMVar (Async ()))

type SupervisorQueue = TQueue SupervisorCommand

-- newSupervisorQueue :: IO SupervisorQueue
-- newSupervisorQueue = newTQueueIO

newSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> ProcessSpec      -- ^ Specification of the process to be started.
    -> IO (Async ())
newSupervisedProcess inbox procMap procSpec =
    newProcess procMap $ addMonitor monitor procSpec
      where
        monitor reason tid = atomically $ writeTQueue inbox (Down reason tid)

startAllSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> [ProcessSpec]    -- ^ List of process specifications to be started.
    -> IO ()
startAllSupervisedProcess inbox procMap = traverse_ $ newSupervisedProcess inbox procMap

killAllSupervisedProcess :: SupervisorQueue -> ProcessMap -> IO ()
killAllSupervisedProcess inbox procMap = uninterruptibleMask_ $ do
    pmap <- readIORef procMap
    for_ (elems pmap) $ cancel . fst
    go pmap
      where
        go pmap | null pmap = writeIORef procMap pmap
                | otherwise = do
                    cmd <- atomically $ readTQueue inbox
                    case cmd of
                        (Down _ tid) -> go $! delete tid pmap
                        _            -> go pmap

data Strategy = OneForOne | OneForAll

newSimpleOneForOneSupervisor :: SupervisorQueue -> IO ()
newSimpleOneForOneSupervisor inbox = newSupervisor inbox OneForOne def def []

newSupervisor
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> Strategy         -- ^ Restarting strategy of monitored processes.
    -> RestartIntensity -- ^ Maximum restart intensity of the process.  Used with the next argument.
                        --   If proccess crashed more than this value within given period, the supervisor will restart itself.
    -> RestartPeriod    -- ^ Period of restart intensity window.  If intense crash happened within this period,
                        --   the supervisor will restart itself.
    -> [ProcessSpec]    -- ^ List of supervised process specifications.
    -> IO ()
newSupervisor inbox strategy maxR maxT procSpecs =
    bracket newProcessMap (killAllSupervisedProcess inbox) initSupervisor
      where
        initSupervisor procMap = do
            startAllSupervisedProcess inbox procMap procSpecs
            supervisorLoop inbox (restartChild strategy procMap) maxR isIntense procMap procSpecs

        restartChild OneForOne pmap spec = void $ newSupervisedProcess inbox pmap spec
        restartChild OneForAll pmap _    = killAllSupervisedProcess inbox pmap *> startAllSupervisedProcess inbox pmap procSpecs

        isIntense = isRestartIntenseNow maxT

supervisorLoop
    :: SupervisorQueue                          -- ^ Inbox message queue of the supervisor.
    -> (ProcessSpec -> IO ())                   -- ^ Function to perform process restart.
    -> RestartIntensity                         -- ^ Maximum restart intensity of the process.  Used with the next argument.
                                                --   If process crashed more than this value within given period,
                                                --   the supervisor will restart itself.
    -> (RestartHist -> IO (Bool, RestartHist))  -- ^ Check if SV restart is needed and update restart history.
    -> ProcessMap                               -- ^ Map of current live processes which the supervisor monitors.
    -> [ProcessSpec]                            -- ^ List of supervised process specifications.
    -> IO ()
supervisorLoop inbox restartChild maxR isIntense procMap procSpecs = go (Just $ newRestartHist maxR)
  where
    go :: Maybe RestartHist -> IO ()
    go (Just hist) =do
        next <- mask_ $ do
            cmd <- atomically (readTQueue inbox)
            processSupervisorCommand hist cmd
        go next
    go Nothing = pure ()

    processSupervisorCommand :: RestartHist -> SupervisorCommand -> IO (Maybe RestartHist)
    processSupervisorCommand hist (Down reason tid) = do
        pmap <- readIORef procMap
        processRestart $ snd <$> lookup tid pmap
      where
        processRestart :: Maybe ProcessSpec -> IO (Maybe RestartHist)
        processRestart (Just (procSpec@(ProcessSpec _ restart _))) = do
            modifyIORef' procMap $ delete tid
            if restartNeeded restart reason
            then do
                (intense, nextHist) <- isIntense hist
                if intense
                then pure Nothing
                else restartChild procSpec $> Just nextHist
            else
                pure (Just hist)
        processRestart Nothing = pure $ Just hist

        restartNeeded Temporary _      = False
        restartNeeded Transient Normal = False
        restartNeeded _         _      = True

    processSupervisorCommand hist (StartChild (ProcessSpec monitors _ proc) callRet) = do
        a <- newSupervisedProcess inbox procMap (ProcessSpec monitors Temporary proc)
        atomically $ putTMVar callRet a
        pure (Just hist)

newChild :: CallTimeout -> SupervisorQueue -> ProcessSpec -> IO (Maybe (Async ()))
newChild (CallTimeout usec) sv spec = do
    r <- newEmptyTMVarIO
    atomically . writeTQueue sv $ StartChild spec r
    timeout usec . atomically . takeTMVar $ r
