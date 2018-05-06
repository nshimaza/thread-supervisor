{-|
Module      : Control.Concurrent.SupervisorInternal
Copyright   : (c) Naoto Shimazaki 2018
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

A simplified implementation of Erlang/OTP like supervisor over async and underlying behaviors.
This is internal module where all real implementations present.

-}
module Control.Concurrent.SupervisorInternal where

import           Prelude             hiding (lookup)

import           Control.Monad       (void)
import           Data.Default
import           Data.Foldable       (foldl', for_, traverse_)
import           Data.Functor        (($>))
import           Data.Map.Strict     (Map, delete, elems, empty, insert, keys,
                                      lookup)
import           Data.Semigroup      ((<>))
import           System.Clock        (Clock (Monotonic), TimeSpec (..),
                                      diffTimeSpec, getTime)
import           UnliftIO            (Async, Chan, IORef, SomeException, TMVar,
                                      TQueue, TVar, async, asyncThreadId,
                                      asyncWithUnmask, atomically, bracket,
                                      cancel, catch, finally, mask_,
                                      modifyIORef', newChan, newEmptyTMVarIO,
                                      newIORef, newTQueueIO, newTVarIO,
                                      putTMVar, readChan, readIORef, readTQueue,
                                      readTVar, takeTMVar, timeout,
                                      tryReadTQueue, uninterruptibleMask_,
                                      writeChan, writeIORef, writeTQueue,
                                      writeTVar)
import           UnliftIO.Concurrent (ThreadId, myThreadId)

import           Data.DelayedQueue   (DelayedQueue, newEmptyDelayedQueue, pop,
                                      push)

{-
    Message queue and selective receive.
-}
-- | Message queue abstraction
data MessageQueue a = MessageQueue
    { messageQueueInbox     :: TQueue a
    , messageQueueSaveStack :: TVar [a]
    }

-- | Create a new empty 'MessageQueue'
newMessageQueue :: IO (MessageQueue a)
newMessageQueue = MessageQueue <$> newTQueueIO <*> newTVarIO []

-- | Send a message to given 'MessageQueue'
sendMessage :: MessageQueue a -> a -> IO ()
sendMessage (MessageQueue inbox _) = atomically . writeTQueue inbox

{-
    Perform selective receive from given 'MessageQueue'.

    'receiveSelect' seaches given queue for first interesting message predicated by user supplied function.
    It applies the predicate to the queue, returns the first element that satisfy the predicate and
    new MessageQueue with the element removed.

    It blocks until interesting message arrived if no interesting message was found in the queue.
-}
receiveSelect
    :: (a -> Bool)      -- ^ Predicate to pick a interesting message.
    -> MessageQueue a   -- ^ Message queue where interesting message searched for.
    -> IO a
receiveSelect predicate q@(MessageQueue inbox saveStack) = atomically $ do
    saved <- readTVar saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> writeTVar saveStack newSaved $> msg
        Nothing                -> go saved
  where
    go newSaved = do
        msg <- readTQueue inbox
        if predicate msg
        then writeTVar saveStack newSaved $> msg
        else go (msg:newSaved)

{-
    Try to perform selective receive from given 'MessageQueue'.

    'tryReceiveSelect' seaches given queue for first interesting message predicated by user supplied function.
    It applies the predicate to the queue, returns the first element that satisfy the predicate and
    new MessageQueue with the element removed.

    It return Nothing if there is no interesting message found in the queue.
-}
tryReceiveSelect
    :: (a -> Bool)      -- ^ Predicate to pick a interesting message.
    -> MessageQueue a   -- ^ Message queue where interesting message searched for.
    -> IO (Maybe a)
tryReceiveSelect predicate q@(MessageQueue inbox saveStack) = atomically $ do
    saved <- readTVar saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> writeTVar saveStack newSaved $> Just msg
        Nothing                -> go saved
  where
    go newSaved = do
        maybeMsg <- tryReadTQueue inbox
        case maybeMsg of
            Nothing                     -> writeTVar saveStack newSaved $> Nothing
            Just msg | predicate msg    -> writeTVar saveStack newSaved $> Just msg
                     | otherwise        -> go (msg:newSaved)

pickFromSaveStack :: (a -> Bool) -> [a] -> Maybe (a, [a])
pickFromSaveStack predicate saveStack = go [] $ reverse saveStack
  where
    go newSaved []                    = Nothing
    go newSaved (x:xs) | predicate x  = Just (x, foldl' (flip (:)) newSaved xs)
                       | otherwise    = go (x:newSaved) xs


-- | Receive first message in 'MassageQueue'.  Block until message available.
receive :: MessageQueue a -> IO a
receive = receiveSelect (const True)


{-
    State machine behavior.
-}
{-|
    Create a new finite state machine.

    The state machine waits for new message at 'MessageQueue' then callback message handler given by user.
    The message handler must return 'Right' with new state or 'Left' with final result.
    When 'Right' is returned, the state machine waits next message.
    When 'Left' is returned, the state machine terminates and returns the result.

    'newStateMachine' returns an IO action wrapping the state machine described above.
    The returned IO action can be executed within an 'Async' or bare thread.

    Created IO action is designed to run in separate thread from main thread.
    If you try to run the IO action at main thread without having producer of the message queue you gave,
    the state machine will dead lock.
-}
newStateMachine
    :: MessageQueue message -- ^ Event input queue of the state machine.
    -> state                -- ^ Initial state of the state machine.
    -> (state -> message -> IO (Either result state))
                            -- ^ Message handler which processes event and returns result or next state.
    -> IO result            -- ^ Return value when the state machine terminated.
newStateMachine inbox initialState messageHandler = go $ Right initialState
  where
    go (Right state) = go =<< mask_ (messageHandler state =<< receive inbox)
    go (Left result) = pure result


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

-- | Timeout of call method for server behavior in microseconds.  Default is 5 second.
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

{-|
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
    Supervisable IO action.
-}

{-|
    'Restart' defines when a terminated child thread triggers restart operation by its supervisor.
    'Restart' only define when it triggers restart operation.  It does not directly means if the thread
    will be or will not be restarted.  It is determined by restart strategy of supervisor.
    For example, a static 'Temporary' thread never trigger restart on its termination but static 'Temporary'
    thread will be restarted if another 'Permanent' or 'Transient' thread with common supervisor triggered
    restart operation and the supervisor has 'OneForAll' strategy.
-}
data Restart
    = Permanent -- ^ 'Permanent' thread always triggers restart.
    | Transient -- ^ 'Transient' thread triggers restart only if it was terminated by exception.
    | Temporary -- ^ 'Temporary' thread never triggers restart.
    deriving (Eq, Show)

-- | 'ExitReason' indicates reason of thread termination.
data ExitReason
    = Normal                            -- ^ Thread was normally finished.
    | UncaughtException SomeException   -- ^ A synchronous exception was thrown and it was not caught.
                                        --   This indicates some unhandled error happened inside of the thread handler.
    | Killed                            -- ^ An asynchronous exception was thrown.
                                        --   This also happen when the thread was killed by supervisor.
    deriving (Show)

-- | 'Monitor' is user supplied callback function which is called when monitored thread is terminated.
type Monitor
    = ExitReason    -- ^ Reason of thread termination.
    -> ThreadId     -- ^ ID of terminated thread.
    -> IO ()

{-|
    'ProcessSpec' is representation of IO action which can be supervised by supervisor.
    'Supervisor' can run the IO action with separate thread, monitor its termination and
    restart it based on restart type.  Additionally, user can also receive notification
    on its termination by supplying user\'s own callback functions.
-}
data ProcessSpec = ProcessSpec [Monitor] Restart (IO ())

-- | Create a 'ProcessSpec'.
newProcessSpec
    :: [Monitor]    -- ^ List of callback functions.  They are called when the IO action was terminated.
    -> Restart      -- ^ Restart type of resulting 'ProcessSpec'.  One of 'Permanent', 'Transient' or 'Temporary'.
    -> IO ()        -- ^ User supplied IO action which the 'ProcessSpec' actually does.
    -> ProcessSpec
newProcessSpec = ProcessSpec

-- | Add a 'Monitor' function to existing 'ProcessSpec'.
addMonitor
    :: Monitor      -- ^ Callback function called when the IO action of the 'ProcessSpec' terminated.
    -> ProcessSpec  -- ^ Existing 'ProcessSpec' where the 'Monitor' is going to be added.
    -> ProcessSpec  -- ^ Newly created 'ProcessSpec' with the 'Monitor' added.
addMonitor monitor (ProcessSpec monitors restart action) = ProcessSpec (monitor:monitors) restart action

{-|
    'ProcessMap' is mutable variable which holds pool of living threads and 'ProcessSpec' of each thread.
    ProcessMap is used inside of supervisor only.
-}
type ProcessMap = IORef (Map ThreadId (Async (), ProcessSpec))

-- | Create an empty 'ProcessMap'
newProcessMap :: IO ProcessMap
newProcessMap = newIORef empty

{-|
    Start new thread based on given 'ProcessSpec', register the thread to given 'ProcessMap'
    then returns 'Async' of the thread.
-}
newProcess
    :: ProcessMap       -- ^ Map of current live processes where the new process is going to be added.
    -> ProcessSpec      -- ^ Specification of newly started process.
    -> IO (Async ())    -- ^ 'Async' representing forked thread.
newProcess procMap procSpec@(ProcessSpec monitors _ action) = mask_ $ do
    reason <- newIORef Killed
    a <- asyncWithUnmask $ \unmask ->
        ((unmask action *> writeIORef reason Normal) `catch` (writeIORef reason . UncaughtException))
        `finally` (readIORef reason >>= notify monitors)
    modifyIORef' procMap $ insert (asyncThreadId a) (a, procSpec)
    pure a
  where
    notify monitors reason = uninterruptibleMask_ $ for_ monitors (\monitor -> myThreadId >>= monitor reason)

{-
    Restart intensity handling.
-}
{-|
    'RestartSensitivity' defines condition how supervisor determines intensive restart is happening.
    If more than 'restartSensitivityIntensity' time of restart is triggered within 'restartSensitivityPeriod',
    supervisor decides intensive restart is happening and it terminates itself.
    Default intensity (maximum number of acceptable restart) is 1.  Default period is 5 seconds.
-}
data RestartSensitivity = RestartSensitivity
    { restartSensitivityIntensity :: Int        -- ^ Maximum number of restart accepted within the period below.
    , restartSensitivityPeriod    :: TimeSpec   -- ^ Length of time window in 'TimeSpec' where the number of restarts is counted.
    }

instance Default RestartSensitivity where
    def = RestartSensitivity 1 TimeSpec { sec = 5, nsec = 0 }

newtype RestartHist = RestartHist (DelayedQueue TimeSpec) deriving (Eq, Show)

-- | Create a 'RestartHist' with maximum allowed restart embedded as delay of 'DelayedQueue'.
newRestartHist
    :: Int          -- ^ Restart intensity (maximum number of restart allowed before supervisor terminates).
    -> RestartHist
newRestartHist = RestartHist . newEmptyDelayedQueue

-- | Get current system timestamp in 'Monotonic' form.
getCurrentTime :: IO TimeSpec
getCurrentTime = getTime Monotonic

{-|
    Determine if the last restart results intensive restart.
    It pushes the last restart timestamp to the 'DelayedQueue' inside of the restart history
    then check if the oldest restart record is pushed out from the queue.
    If no record was pushed out, there are less number of restarts than limit, so it is not intensive.
    If a record was pushed out, it means we had one more restarts than allowed.
    If the oldest restart and newest restart happened within allowed time interval, it is intensive.

    This function implements pure part of 'isRestartIntenseNow'.
-}
isRestartIntense
    :: TimeSpec             -- ^ Restart period (time window where multiple restarts within it are considered as intensive).
    -> TimeSpec             -- ^ System timestamp in 'Monotonic' form when the last restart was triggered.
    -> RestartHist          -- ^ History of past restart with maximum allowed restarts are delayed to appear in its front.
    -> (Bool, RestartHist)  -- ^ Returns 'True' if intensive restart is happening.
                            --   Returns new history of restart which has the oldest history removed if possible.
isRestartIntense maxT lastRestart (RestartHist dq) =
    let histWithLastRestart = push lastRestart dq
    in case pop histWithLastRestart of
        Nothing                         ->  (False, RestartHist histWithLastRestart)
        Just (oldestRestart, nextHist)  ->  (lastRestart - oldestRestart <= maxT, RestartHist nextHist)

{-|
    Determine if intensive restart is happening now.
    It is called when restart is triggered by some thread termination.
-}
isRestartIntenseNow
    :: TimeSpec                 -- ^ Restart period (time window where multiple restarts within it are considered as intensive).
    -> RestartHist              -- ^ History of past restart with maximum allowed restarts are delayed to appear in its front.
    -> IO (Bool, RestartHist)   -- ^ Returns 'True' if intensive restart is happening.
                                --   Returns new history of restart which has the oldest history removed if possible.
isRestartIntenseNow maxT restartHist = do
    currentTime <- getCurrentTime
    pure $ isRestartIntense maxT currentTime restartHist

{-
    Supervisor
-}

-- | 'SupervisorMessage' defines all message types supervisor can receive.
data SupervisorMessage
    = Down ExitReason ThreadId                  -- ^ Notification of child thread termination.
    | StartChild ProcessSpec (TMVar (Async ())) -- ^ Command to start a new supervised thread.

type SupervisorQueue = MessageQueue SupervisorMessage

-- newSupervisorQueue :: IO SupervisorQueue
-- newSupervisorQueue = newTQueueIO

-- | Start a new thread with supervision.
newSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> ProcessSpec      -- ^ Specification of the process to be started.
    -> IO (Async ())
newSupervisedProcess inbox procMap procSpec =
    newProcess procMap $ addMonitor monitor procSpec
      where
        monitor reason tid = sendMessage inbox (Down reason tid)

-- | Start all given 'ProcessSpec' on new thread each with supervision.
startAllSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> [ProcessSpec]    -- ^ List of process specifications to be started.
    -> IO ()
startAllSupervisedProcess inbox procMap = traverse_ $ newSupervisedProcess inbox procMap

-- | Kill all running threads supervised by the supervisor represented by 'SupervisorQueue'.
killAllSupervisedProcess :: SupervisorQueue -> ProcessMap -> IO ()
killAllSupervisedProcess inbox procMap = uninterruptibleMask_ $ do
    pmap <- readIORef procMap
    for_ (elems pmap) $ cancel . fst
    go pmap
      where
        go pmap | null pmap = writeIORef procMap pmap
                | otherwise = do
                    cmd <- receive inbox
                    case cmd of
                        (Down _ tid) -> go $! delete tid pmap
                        _            -> go pmap

data Strategy = OneForOne | OneForAll

{-|
    Create a supervisor with 'OneForOne' restart strategy and has no static 'ProcessSpec'.
    When it started, it has no child threads.  Only 'newChild' can add new thread supervised by the supervisor.
    Thus the simple one-for-one supervisor only manages dynamic and 'Temporary' children.
-}
newSimpleOneForOneSupervisor :: SupervisorQueue -> IO ()
newSimpleOneForOneSupervisor inbox = newSupervisor inbox OneForOne def []

{-|
    Create a supervisor.

    When created supervisor IO action started, it automatically creates child threads based on given 'ProcessSpec'
    list and supervise them.  After it created such static children, it listens given 'SupervisorQueue'.
    User can let the supervisor creates dynamic child thread by calling 'newChild'.  Dynamic child threads
    created by 'newChild' are also supervised.

    When the supervisor thread is killed or terminated in some reason, all children including static children
    and dynamic children are all killed.

    With 'OneForOne' restart strategy, when a child thread terminated, it is restarted based on its restart type
    given in 'ProcessSpec'.  If the terminated thread has 'Permanent' restart type, supervisor restarts it
    regardless its exit reason.  If the terminated thread has 'Transient' restart type, and termination reason
    is other than 'Normal' (meaning 'UncaughtException' or 'Killed'), it is restarted.  If the terminated thread
    has 'Temporary' restart type, supervisor does not restart it regardless its exit reason.

    Created IO action is designed to run in separate thread from main thread.
    If you try to run the IO action at main thread without having producer of the supervisor queue you gave,
    the state machine will dead lock.
-}
newSupervisor
    :: SupervisorQueue      -- ^ Inbox message queue of the supervisor.
    -> Strategy             -- ^ Restarting strategy of monitored processes.  'OneForOne' or 'OneForAll'.
    -> RestartSensitivity   -- ^ Restart intensity sensitivity in restart count and period.
    -> [ProcessSpec]        -- ^ List of supervised process specifications.
    -> IO ()
newSupervisor inbox strategy (RestartSensitivity maxR maxT) procSpecs = bracket newProcessMap (killAllSupervisedProcess inbox) initSupervisor
  where
    initSupervisor procMap = do
        startAllSupervisedProcess inbox procMap procSpecs
        newStateMachine inbox (newRestartHist maxR) supervisorMessageHandler
      where
        restartChild OneForOne procMap spec = void $ newSupervisedProcess inbox procMap spec
        restartChild OneForAll procMap _    = killAllSupervisedProcess inbox procMap *> startAllSupervisedProcess inbox procMap procSpecs

        supervisorMessageHandler :: RestartHist -> SupervisorMessage -> IO (Either () RestartHist)
        supervisorMessageHandler hist (Down reason tid) = do
            pmap <- readIORef procMap
            processRestart $ snd <$> lookup tid pmap
          where
            processRestart :: Maybe ProcessSpec -> IO (Either () RestartHist)
            processRestart (Just (procSpec@(ProcessSpec _ restart _))) = do
                modifyIORef' procMap $ delete tid
                if restartNeeded restart reason
                then do
                    (intense, nextHist) <- isRestartIntenseNow maxT hist
                    if intense
                    then pure $ Left ()
                    else restartChild strategy procMap procSpec $> Right nextHist
                else
                    pure $ Right hist
            processRestart Nothing = pure $ Right hist

            restartNeeded Temporary _      = False
            restartNeeded Transient Normal = False
            restartNeeded _         _      = True

        supervisorMessageHandler hist (StartChild (ProcessSpec monitors _ proc) callRet) = do
            a <- newSupervisedProcess inbox procMap (ProcessSpec monitors Temporary proc)
            atomically $ putTMVar callRet a
            pure $ Right hist

newChild :: CallTimeout -> SupervisorQueue -> ProcessSpec -> IO (Maybe (Async ()))
newChild (CallTimeout usec) sv spec = do
    r <- newEmptyTMVarIO
    sendMessage sv $ StartChild spec r
    timeout usec . atomically . takeTMVar $ r
