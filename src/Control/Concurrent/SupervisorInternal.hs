{-|
Module      : Control.Concurrent.SupervisorInternal
Copyright   : (c) Naoto Shimazaki 2018
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

A simplified implementation of Erlang/OTP like supervisor over async.
This is internal module where all real implementations present.

-}
module Control.Concurrent.SupervisorInternal where

import           Prelude             hiding (lookup)

import           Control.Monad       (void)
import           Data.Default
import           Data.Foldable       (foldl', for_, traverse_)
import           Data.Functor        (($>))
import           Data.Map.Strict     (Map, delete, elems, empty, insert, lookup)
import           System.Clock        (Clock (Monotonic), TimeSpec (..),
                                      diffTimeSpec, getTime)
import           UnliftIO            (Async, IORef, SomeException, TMVar,
                                      TQueue, TVar, async, asyncThreadId,
                                      asyncWithUnmask, atomically, bracket,
                                      cancel, catch, finally, mask_,
                                      modifyIORef', modifyTVar',
                                      newEmptyTMVarIO, newIORef, newTQueueIO,
                                      newTVarIO, putTMVar, readIORef,
                                      readTQueue, readTVar, readTVarIO,
                                      retrySTM, takeTMVar, timeout,
                                      tryReadTQueue, uninterruptibleMask_,
                                      writeIORef, writeTQueue, writeTVar)
import           UnliftIO.Concurrent (ThreadId, myThreadId)

import           Data.DelayedQueue   (DelayedQueue, newEmptyDelayedQueue, pop,
                                      push)

{-
    Message queue and selective receive.
-}
{-|
    Message queue abstraction.
-}
data MessageQueue a = MessageQueue
    { messageQueueInbox     :: TQueue a     -- ^ Concurrent queue receiving message from other threads.
    , messageQueueLength    :: TVar Word    -- ^ Number of elements currently held by the 'MessageQueue'.
    , messageQueueSaveStack :: IORef [a]    -- ^ Saved massage by 'receiveSelect'.  It keeps messages
                                            --   not selected by receiveSelect in reversed order.
                                            --   Latest message is kept at head of the list.
    , messageQueueMaxBound  :: Word         -- ^ Maximum length of the 'MessageQueue'
    }

-- | Maximum length of 'MessageQUeue'.
newtype MessageQueueLength = MessageQueueLength Word

instance Default MessageQueueLength where
    def = MessageQueueLength maxBound

-- | Write end of 'MessageQueue' exposed to outside of actor.
newtype MessageQueueTail a = MessageQueueTail (MessageQueue a)

-- | Create a new empty 'MessageQueue'.
newMessageQueue :: MessageQueueLength -> IO (MessageQueue a)
newMessageQueue (MessageQueueLength upperBound) = MessageQueue <$> newTQueueIO <*> newTVarIO 0 <*> newIORef [] <*> pure upperBound

-- -- | Create a new empty 'MessageQueue' with upper bound of length.
-- newBoundedMessageQueue :: Word -> IO (MessageQueue a)
-- newBoundedMessageQueue upperBound = MessageQueue <$> newTQueueIO <*> newTVarIO 0 <*> newIORef [] <*> pure upperBound

-- | Send a message to given 'MessageQueue'.  Block if the 'MessageQueue' is full.
sendMessage :: MessageQueueTail a -> a -> IO ()
sendMessage (MessageQueueTail (MessageQueue inbox lenTVar _ limit)) msg = atomically $ do
    len <- readTVar lenTVar
    if len < limit
    then modifyTVar' lenTVar succ *> writeTQueue inbox msg
    else retrySTM

-- | Try to send a message to given 'MessageQueue'.  Return Nothing if the 'MessageQueue' is full.
trySendMessage :: MessageQueueTail a -> a -> IO (Maybe ())
trySendMessage (MessageQueueTail (MessageQueue inbox lenTVar _ limit)) msg = atomically $ do
    len <- readTVar lenTVar
    if len < limit
    then modifyTVar' lenTVar succ *> writeTQueue inbox msg $> Just ()
    else pure Nothing

-- | Number of elements currently held by the 'MessageQueue'.
length:: MessageQueueTail a -> IO Word
length (MessageQueueTail q) = readTVarIO $ messageQueueLength q

{-|
    Perform selective receive from given 'MessageQueue'.

    'receiveSelect' searches given queue for first interesting message predicated by user supplied function.
    It applies the predicate to the queue, returns the first element that satisfy the predicate and mutates the
    MessageQueue by removing the element found.

    It blocks until interesting message arrived if no interesting message was found in the queue.

    __Caution__

    Use this function with care.  It doesn't discard any message unsatisfying predicate but keep them in the queue for
    future receive and the function itself blocks until interesting message arrived.  That causes your queue filled up
    by non-interesting messages.  There is no escape hatch.

    Consider using 'tryReceiveSelect' instead.

    __Caveat__

    Current implementation has performance caveat.  It has /O(n)/ performance characteristic where /n/ is number of
    messages existing before your interested message appears.  It is because this function performs liner scan from the
    top of the queue every time it is called.  It doesn't cache predicates and results you have given before.

    Use this function in limited situation only.
-}
receiveSelect
    :: (a -> Bool)      -- ^ Predicate to pick a interesting message.
    -> MessageQueue a   -- ^ Message queue where interesting message searched for.
    -> IO a
receiveSelect predicate (MessageQueue inbox lenTVar saveStack _) = do
    saved <- readIORef saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> oneMessageRemoved lenTVar saveStack newSaved $> msg
        Nothing                -> go saved
  where
    go newSaved = do
        msg <- atomically $ readTQueue inbox
        if predicate msg
        then oneMessageRemoved lenTVar saveStack newSaved $> msg
        else go (msg:newSaved)

{-|
    Try to perform selective receive from given 'MessageQueue'.

    'tryReceiveSelect' searches given queue for first interesting message predicated by user supplied function.
    It applies the predicate to the queue, returns the first element that satisfy the predicate and mutates the
    MessageQueue by removing the element found.

    It return Nothing if there is no interesting message found in the queue.

    __Caveat__

    Current implementation has performance caveat.  It has /O(n)/ performance characteristic where /n/ is number of
    messages existing before your interested message appears.  It is because this function performs liner scan from the
    top of the queue every time it is called.  It doesn't cache predicates and results you have given before.

    Use this function in limited situation only.
-}
tryReceiveSelect
    :: (a -> Bool)      -- ^ Predicate to pick a interesting message.
    -> MessageQueue a   -- ^ Message queue where interesting message searched for.
    -> IO (Maybe a)
tryReceiveSelect predicate (MessageQueue inbox lenTVar saveStack _) = do
    saved <- readIORef saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> oneMessageRemoved lenTVar saveStack newSaved $> Just msg
        Nothing                -> go saved
  where
    go newSaved = do
        maybeMsg <- atomically $ tryReadTQueue inbox
        case maybeMsg of
            Nothing                     -> writeIORef saveStack newSaved $> Nothing
            Just msg | predicate msg    -> oneMessageRemoved lenTVar saveStack newSaved $> Just msg
                     | otherwise        -> go (msg:newSaved)

{-|
    Removes oldest message satisfying predicate from saveStack and return the message and updated saveStack.
    Returns Nothing if there is no satisfying message.
-}
pickFromSaveStack :: (a -> Bool) -> [a] -> Maybe (a, [a])
pickFromSaveStack predicate saveStack = go [] $ reverse saveStack
  where
    go newSaved []                    = Nothing
    go newSaved (x:xs) | predicate x  = Just (x, foldl' (flip (:)) newSaved xs)
                       | otherwise    = go (x:newSaved) xs

-- | Mutate 'MessageQueue' when a message was removed from it.
oneMessageRemoved
    :: TVar Word    -- ^ 'TVar' holding current number of messages in the queue.
    -> IORef [a]    -- ^ 'IORef' to saveStack to be overwritten.
    -> [a]          -- ^ New saveStack to mutate given IORef
    -> IO ()
oneMessageRemoved len saveStack newSaved = do
    atomically $ modifyTVar' len pred
    writeIORef saveStack newSaved

-- | Receive first message in 'MessageQueue'.  Block until message available.
receive :: MessageQueue a -> IO a
receive = receiveSelect (const True)

-- | Try to receive first message in 'MessageQueue'.  It returns Nothing if there is no message available.
tryReceive :: MessageQueue a -> IO (Maybe a)
tryReceive = tryReceiveSelect (const True)


type ActorHandler a b = (MessageQueue a -> IO b)

{-|
    Create a new actor.
-}
newActor
    :: MessageQueueLength
    -> ActorHandler a b
    -> IO (MessageQueueTail a, IO b)
newActor maxQLen handler = do
    q <- newMessageQueue maxQLen
    pure (MessageQueueTail q, handler q)


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
    :: state    -- ^ Initial state of the state machine.
    -> (state -> message -> IO (Either result state))
                -- ^ Message handler which processes event and returns result or next state.
    -> ActorHandler message result
newStateMachine initialState messageHandler inbox = go $ Right initialState
  where
    go (Right state) = go =<< mask_ (messageHandler state =<< receive inbox)
    go (Left result) = pure result


{-
    Sever behavior
-}
-- | Type synonym of callback function to obtain return value.
type ServerCallback a = (a -> IO ())

{-|
    Send an asynchronous request to a server.
-}
cast
    :: MessageQueueTail cmd -- ^ Message queue of the target server.
    -> cmd                  -- ^ Request to the server.
    -> IO ()
cast = sendMessage

-- | Timeout of call method for server behavior in microseconds.  Default is 5 second.
newtype CallTimeout = CallTimeout Int

instance Default CallTimeout where
    def = CallTimeout 5000000

{-|
    Send an synchronous request to a server and waits for a return value until timeout.
-}
call
    :: CallTimeout              -- ^ Timeout.
    -> MessageQueueTail cmd     -- ^ Message queue of the target server.
    -> ((a -> IO ()) -> cmd)    -- ^ Request to the server without callback supplied.
    -> IO (Maybe a)
call (CallTimeout usec) srv req = do
    rVar <- newEmptyTMVarIO
    sendMessage srv . req $ atomically . putTMVar rVar
    timeout usec . atomically . takeTMVar $ rVar

{-|
    Make an asynchronous call to a server and give result in CPS style.
    The return value is delivered to given callback function.  It also can fail by timeout.
    It is useful to convert return value of 'call' to a message of calling process asynchronously
    so that calling process can continue processing instead of blocking at 'call'.

    Use this function with care because there is no guaranteed cancellation of background worker
    thread other than timeout.  Giving infinite timeout (zero) to the 'CallTimeout' argument may cause
    the background thread left to run, possibly indefinitely.
-}
callAsync
    :: CallTimeout              -- ^ Timeout.
    -> MessageQueueTail cmd     -- ^ Message queue.
    -> ((a -> IO ()) -> cmd)    -- ^ Request to the server without callback supplied.
    -> (Maybe a -> IO b)        -- ^ callback to process return value of the call.  Nothing is given on timeout.
    -> IO (Async b)
callAsync timeout srv req cont = async $ call timeout srv req >>= cont

{-|
    Send an request to a server but ignore return value.
-}
callIgnore
    :: MessageQueueTail cmd     -- ^ Message queue of the target server.
    -> ((a -> IO ()) -> cmd)    -- ^ Request to the server without callback supplied.
    -> IO ()
callIgnore srv req = sendMessage srv $ req (\_ -> pure ())


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
    Supervisor can run the IO action with separate thread, monitor its termination and
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

{-|
    'IntenseRestartDetector' keeps data used for detecting intense restart.
    It keeps maxR (maximum restart intensity), maxT (period of majoring restart intensity) and
    history of restart with system timestamp in 'Monotonic' form.
-}
data IntenseRestartDetector = IntenseRestartDetector
    { intenseRestartDetectorPeriod  :: TimeSpec                 -- ^ Length of time window in 'TimeSpec' where the number of restarts is counted.
    , intenseRestartDetectorHistory :: DelayedQueue TimeSpec    -- ^ Restart timestamp history.
    }

-- | Create new IntenseRestartDetector with given 'RestartSensitivity' parameters.
newIntenseRestartDetector :: RestartSensitivity -> IntenseRestartDetector
newIntenseRestartDetector (RestartSensitivity maxR maxT) = IntenseRestartDetector maxT (newEmptyDelayedQueue maxR)

{-|
    Determine if the last restart results intensive restart.
    It pushes the last restart timestamp to the 'DelayedQueue' of restart history held inside
    of the IntenseRestartDetector then check if the oldest restart record is pushed out from the queue.
    If no record was pushed out, there are less number of restarts than limit, so it is not intensive.
    If a record was pushed out, it means we had one more restarts than allowed.
    If the oldest restart and newest restart happened within allowed time interval, it is intensive.

    This function implements pure part of 'detectIntenseRestartNow'.
-}
detectIntenseRestart
    :: IntenseRestartDetector           -- ^ Intense restart detector containing history of past restart with maxT and maxR
    -> TimeSpec                         -- ^ System timestamp in 'Monotonic' form when the last restart was triggered.
    -> (Bool, IntenseRestartDetector)   -- ^ Returns 'True' if intensive restart is happening.
                                        --   Returns new history of restart which has the oldest history removed if possible.
detectIntenseRestart (IntenseRestartDetector maxT history) lastRestart = case pop latestHistory of
    Nothing                         ->  (False, IntenseRestartDetector maxT latestHistory)
    Just (oldestRestart, nextHist)  ->  (lastRestart - oldestRestart <= maxT, IntenseRestartDetector maxT nextHist)
  where
    latestHistory = push lastRestart history

-- | Get current system timestamp in 'Monotonic' form.
getCurrentTime :: IO TimeSpec
getCurrentTime = getTime Monotonic

{-|
    Determine if intensive restart is happening now.
    It is called when restart is triggered by some thread termination.
-}
detectIntenseRestartNow
    :: IntenseRestartDetector   -- ^ Intense restart detector containing history of past restart with maxT and maxR.
    -> IO (Bool, IntenseRestartDetector)
detectIntenseRestartNow detector = detectIntenseRestart detector <$> getCurrentTime

{-
    Supervisor
-}

-- | 'SupervisorMessage' defines all message types supervisor can receive.
data SupervisorMessage
    = Down ExitReason ThreadId                              -- ^ Notification of child thread termination.
    | StartChild ProcessSpec (ServerCallback (Async ()))    -- ^ Command to start a new supervised thread.

-- | Type synonym for inbox message queue of supervisor.
type SupervisorQueue = MessageQueueTail SupervisorMessage
type SupervisorInbox = MessageQueue SupervisorMessage

-- | Start a new thread with supervision.
newSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> ProcessSpec      -- ^ Specification of the process to be started.
    -> IO (Async ())
newSupervisedProcess sv procMap procSpec =
    newProcess procMap $ addMonitor monitor procSpec
      where
        monitor reason tid = cast sv (Down reason tid)

-- | Start all given 'ProcessSpec' on new thread each with supervision.
startAllSupervisedProcess
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ProcessMap       -- ^ Map of current live processes which the supervisor monitors.
    -> [ProcessSpec]    -- ^ List of process specifications to be started.
    -> IO ()
startAllSupervisedProcess sv procMap = traverse_ $ newSupervisedProcess sv procMap

-- | Kill all running threads supervised by the supervisor represented by 'SupervisorQueue'.
killAllSupervisedProcess :: SupervisorInbox -> ProcessMap -> IO ()
killAllSupervisedProcess inbox procMap = uninterruptibleMask_ $ do
    pmap <- readIORef procMap
    for_ (elems pmap) $ cancel . fst

    -- Because 'cancel' blocks until killed thread exited
    -- (in other word, it is synchronous operation),
    -- we are sure we no longer have child process still alive.
    -- So it is okay to just put an empty process map.
    writeIORef procMap empty

    -- Inbox of the SV has unprosessed 'Down' massages for killed children.
    -- Let's cleanup them.
    tryReceiveSelect isDownMessage inbox >>= go
  where
    go Nothing  = pure ()
    go (Just _) = tryReceiveSelect isDownMessage inbox >>= go

    isDownMessage (Down _ _) = True
    isDownMessage _          = False

-- | Restart strategy of supervisor
data Strategy
    = OneForOne -- ^ Restart only exited process.
    | OneForAll -- ^ Restart all process supervised by the same supervisor of exited process.

{-|
    Create a supervisor with 'OneForOne' restart strategy and has no static 'ProcessSpec'.
    When it started, it has no child threads.  Only 'newChild' can add new thread supervised by the supervisor.
    Thus the simple one-for-one supervisor only manages dynamic and 'Temporary' children.
-}
newSimpleOneForOneSupervisor :: ActorHandler SupervisorMessage ()
newSimpleOneForOneSupervisor = newSupervisor OneForOne def []

-- data Supervisor = Supervisor SupervisorQueue IntenseRestartDetector

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
    :: Strategy             -- ^ Restarting strategy of monitored processes.  'OneForOne' or 'OneForAll'.
    -> RestartSensitivity   -- ^ Restart intensity sensitivity in restart count and period.
    -> [ProcessSpec]        -- ^ List of supervised process specifications.
    -> ActorHandler SupervisorMessage ()
newSupervisor strategy restartSensitivity procSpecs inbox = bracket newProcessMap (killAllSupervisedProcess inbox) initSupervisor
  where
    initSupervisor procMap = do
        startAllSupervisedProcess (MessageQueueTail inbox) procMap procSpecs
        newStateMachine (newIntenseRestartDetector restartSensitivity) handler inbox
      where
        handler :: IntenseRestartDetector -> SupervisorMessage -> IO (Either () IntenseRestartDetector)
        handler hist (Down reason tid) = do
            pmap <- readIORef procMap
            processRestart $ snd <$> lookup tid pmap
          where
            processRestart :: Maybe ProcessSpec -> IO (Either () IntenseRestartDetector)
            processRestart (Just procSpec@(ProcessSpec _ restart _)) = do
                modifyIORef' procMap $ delete tid
                if restartNeeded restart reason
                then do
                    (intense, nextHist) <- detectIntenseRestartNow hist
                    if intense
                    then pure $ Left ()
                    else restartChild strategy procMap procSpec $> Right nextHist
                else
                    pure $ Right hist
            processRestart Nothing = pure $ Right hist

            restartNeeded Temporary _      = False
            restartNeeded Transient Normal = False
            restartNeeded _         _      = True

        handler hist (StartChild (ProcessSpec monitors _ proc) cont) =
            (newSupervisedProcess (MessageQueueTail inbox) procMap (ProcessSpec monitors Temporary proc) >>= cont) $> Right hist

        restartChild OneForOne procMap spec = void $ newSupervisedProcess (MessageQueueTail inbox) procMap spec
        restartChild OneForAll procMap _    = do
            killAllSupervisedProcess inbox procMap
            startAllSupervisedProcess (MessageQueueTail inbox) procMap procSpecs

-- | Ask the supervisor to spawn new temporary child process.  Returns 'Async' of the new child.
newChild
    :: CallTimeout      -- ^ Request timeout in microsecond.
    -> SupervisorQueue  -- ^ Inbox message queue of the supervisor to ask new process.
    -> ProcessSpec      -- ^ Supervised process specification to spawn.
    -> IO (Maybe (Async ()))
newChild timeout sv spec = call timeout sv $ StartChild spec
