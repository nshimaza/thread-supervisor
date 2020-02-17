{-# LANGUAGE Strict #-}

{-|
Module      : Control.Concurrent.SupervisorInternal
Copyright   : (c) Naoto Shimazaki 2018-2020
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

A simplified implementation of Erlang/OTP like supervisor over thread.
This is internal module where all real implementations present.

-}
module Control.Concurrent.SupervisorInternal where

import           Prelude             hiding (lookup)

import           Control.Monad       (void)
import           Data.Default
import           Data.Foldable       (foldl', for_, traverse_)
import           Data.Functor        (($>))
import           Data.Map.Strict     (Map, delete, empty, insert, keys, lookup)
import           System.Clock        (Clock (Monotonic), TimeSpec (..), getTime)
import           UnliftIO            (Async, IORef, STM, SomeException, TQueue,
                                      TVar, async, atomically, bracket, catch,
                                      catchAny, finally, mask_, modifyIORef',
                                      modifyTVar', newEmptyTMVarIO, newIORef,
                                      newTQueueIO, newTVarIO, putTMVar,
                                      readIORef, readTQueue, readTVar,
                                      readTVarIO, retrySTM, takeTMVar, throwIO,
                                      timeout, tryReadTQueue,
                                      uninterruptibleMask_, writeIORef,
                                      writeTQueue, writeTVar)
import           UnliftIO.Concurrent (ThreadId, forkIOWithUnmask, killThread,
                                      myThreadId)

import           Data.DelayedQueue   (DelayedQueue, newEmptyDelayedQueue, pop,
                                      push)

{-
    Message queue for actor inbox and selective receive.
-}
{-|
    Message queue abstraction.
-}
data Inbox a = Inbox
    { inboxQueue     :: TQueue a    -- ^ Concurrent queue receiving message from other threads.
    , inboxLength    :: TVar Word   -- ^ Number of elements currently held by the 'Inbox'.
    , inboxSaveStack :: TVar [a]    -- ^ Saved massage by 'receiveSelect'.  It keeps messages
                                    --   not selected by receiveSelect in reversed order.
                                    --   Latest message is kept at head of the list.
    , inboxMaxBound  :: Word        -- ^ Maximum length of the 'Inbox'.
    }

-- | Maximum length of 'Inbox'.
newtype InboxLength = InboxLength Word

instance Default InboxLength where
    def = InboxLength maxBound

-- | Write end of 'Inbox' exposed to outside of actor.
newtype ActorQ a = ActorQ (Inbox a)

-- | Create a new empty 'Inbox'.
newInbox :: InboxLength -> IO (Inbox a)
newInbox (InboxLength upperBound) = Inbox <$> newTQueueIO <*> newTVarIO 0 <*> newTVarIO [] <*> pure upperBound

-- | Send a message to given 'ActorQ'.  Block while the queue is full.
send
  :: ActorQ a   -- ^ Write-end of target actor's message queue.
  -> a          -- ^ Message to be sent.
  -> IO ()
send (ActorQ (Inbox inbox lenTVar _ limit)) msg = atomically $ do
    len <- readTVar lenTVar
    if len < limit
    then modifyTVar' lenTVar succ *> writeTQueue inbox msg
    else retrySTM

-- | Try to send a message to given 'ActorQ'.  Return Nothing if the queue is
-- already full.
trySend
    :: ActorQ a -- ^ Write-end of target actor's message queue.
    -> a        -- ^ Message to be sent.
    -> IO (Maybe ())
trySend (ActorQ (Inbox inbox lenTVar _ limit)) msg = atomically $ do
    len <- readTVar lenTVar
    if len < limit
    then modifyTVar' lenTVar succ *> writeTQueue inbox msg $> Just ()
    else pure Nothing

-- | Number of elements currently held by the 'ActorQ'.
length :: ActorQ a -> IO Word
length (ActorQ q) = readTVarIO $ inboxLength q

{-|
    Perform selective receive from given 'Inbox'.

    'receiveSelect' searches given queue for first interesting message
    predicated by user supplied function.  It applies the predicate to the
    queue, returns the first element that satisfy the predicate, and remove the
    element from the Inbox.

    It blocks until interesting message arrived if no interesting message was
    found in the queue.

    __Caution__

    Use this function with care.  It does NOT discard any message unsatisfying
    predicate.  It keeps them in the queue for future receive and the function
    itself blocks until interesting message arrived.  That causes your queue
    filled up by non-interesting messages.  There is no escape hatch.

    Consider using 'tryReceiveSelect' instead.

    __Caveat__

    Current implementation has performance caveat.  It has /O(n)/ performance
    characteristic where /n/ is number of messages existing before your
    interested message appears.  It is because this function performs liner scan
    from the top of the queue every time it is called.  It doesn't cache pair of
    predicates and results you have given before.

    Use this function in limited situation only.
-}
receiveSelect
    :: (a -> Bool)  -- ^ Predicate to pick a interesting message.
    -> Inbox a      -- ^ Message queue where interesting message searched for.
    -> IO a
receiveSelect predicate (Inbox inbox lenTVar saveStack _) = atomically $ do
    saved <- readTVar saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> oneMessageRemoved lenTVar saveStack newSaved $> msg
        Nothing                -> go saved
  where
    go newSaved = do
        msg <- readTQueue inbox
        if predicate msg
        then oneMessageRemoved lenTVar saveStack newSaved $> msg
        else go (msg:newSaved)

{-|
    Try to perform selective receive from given 'Inbox'.

    'tryReceiveSelect' searches given queue for first interesting message
    predicated by user supplied function.  It applies the predicate to the
    queue, returns the first element that satisfy the predicate, and remove the
    element from the Inbox.

    It return Nothing if there is no interesting message found in the queue.

    __Caveat__

    Current implementation has performance caveat.  It has /O(n)/ performance
    characteristic where /n/ is number of messages existing before your
    interested message appears.  It is because this function performs liner scan
    from the top of the queue every time it is called.  It doesn't cache pair of
    predicates and results you have given before.

    Use this function in limited situation only.
-}
tryReceiveSelect
    :: (a -> Bool)  -- ^ Predicate to pick a interesting message.
    -> Inbox a      -- ^ Message queue where interesting message searched for.
    -> IO (Maybe a)
tryReceiveSelect predicate (Inbox inbox lenTVar saveStack _) = atomically $ do
    saved <- readTVar saveStack
    case pickFromSaveStack predicate saved of
        (Just (msg, newSaved)) -> oneMessageRemoved lenTVar saveStack newSaved $> Just msg
        Nothing                -> go saved
  where
    go newSaved = do
        maybeMsg <- tryReadTQueue inbox
        case maybeMsg of
            Nothing                     -> writeTVar saveStack newSaved $> Nothing
            Just msg | predicate msg    -> oneMessageRemoved lenTVar saveStack newSaved $> Just msg
                     | otherwise        -> go (msg:newSaved)

{-|
    Find oldest message satisfying predicate from 'saveStack', return the
    message, and remove it from the saveStack.  Returns 'Nothing' if there is no
    satisfying message.
-}
pickFromSaveStack :: (a -> Bool) -> [a] -> Maybe (a, [a])
pickFromSaveStack predicate saveStack = go [] $ reverse saveStack
  where
    go _        []                    = Nothing
    go newSaved (x:xs) | predicate x  = Just (x, foldl' (flip (:)) newSaved xs)
                       | otherwise    = go (x:newSaved) xs

-- | Update 'Inbox' with new 'saveStack' which already have one message removed.
oneMessageRemoved
    :: TVar Word    -- ^ 'TVar' holding current number of messages in the queue.
    -> TVar [a]     -- ^ TVar to hold given new saveStack.
    -> [a]          -- ^ New saveStack to update given TVar.
    -> STM ()
oneMessageRemoved len saveStack newSaved = do
    modifyTVar' len pred
    writeTVar saveStack newSaved

-- | Receive first message in 'Inbox'.  Block until message available.
receive :: Inbox a -> IO a
receive = receiveSelect (const True)

-- | Try to receive first message in 'Inbox'.  It returns Nothing if there is no
-- message available.
tryReceive :: Inbox a -> IO (Maybe a)
tryReceive = tryReceiveSelect (const True)

-- | Type synonym of user supplied message handler working inside actor.
type ActorHandler message result = (Inbox message -> IO result)

-- | Actor representation.
data Actor message result = Actor
    { actorQueue  :: ActorQ message -- ^ Write end of message queue of 'Actor'
    , actorAction :: IO result      -- ^ IO action to execute 'Actor'
    }

{-|
    Create a new actor.

    Users have to supply a message handler function with 'ActorHandler' type.
    ActorHandler accepts a 'Inbox' and returns anything.

    'newActor' creates a new 'Inbox', apply user supplied message handler to the
    queue, returns reference to write-end of the queue and IO action of the
    actor.  Because 'newActor' only returns 'ActorQ', caller of 'newActor' can
    only send messages to created actor.  Caller cannot receive message from the
    queue.

    'Inbox', or read-end of the queue, is passed to user supplied message
    handler so the handler can receive message to the actor.  If the handler
    need to send a message to itself, wrap the message queue by 'ActorQ'
    constructor then use 'send' over created 'ActorQ'.  Here is an example.

    > send (ActorQ yourInbox) message
-}
newActor
    :: ActorHandler message result  -- ^ IO action handling received messages.
    -> IO (Actor message result)
newActor = newBoundedActor def

{-|
    Create a new actor with bounded inbox queue.
-}
newBoundedActor
    :: InboxLength                  -- ^ Maximum length of inbox message queue.
    -> ActorHandler message result  -- ^ IO action handling received messages.
    -> IO (Actor message result)
newBoundedActor maxQLen handler = do
    q <- newInbox maxQLen
    pure . Actor (ActorQ q) $ handler q

{-
    State machine behavior.
-}
{-|
    Create a new finite state machine.

    The state machine waits for new message at 'Inbox' then callback user
    supplied message handler.  The message handler must return 'Right' with new
    state or 'Left' with final result.  When 'Right' is returned, the state
    machine waits for next message.  When 'Left' is returned, the state machine
    terminates and returns the result.

    'newStateMachine' returns an IO action wrapping the state machine described
    above.  The returned IO action can be executed within an 'Async' or bare
    thread.

    Created IO action is designed to run in separate thread from main thread.
    If you try to run the IO action at main thread without having producer of
    the message queue you gave, the state machine will dead lock.
-}
newStateMachine
    :: state    -- ^ Initial state of the state machine.
    -> (state -> message -> IO (Either result state))
                -- ^ Message handler which processes event and returns result or next state.
    -> ActorHandler message result
newStateMachine initialState messageHandler inbox = go $ Right initialState
  where
    go (Right state) = receive inbox >>= messageHandler state >>= go
    go (Left result) = pure result

-- | create an unbound actor of newStateMachine.  Short-cut of following.
--
-- > newActor $ newStateMachine initialState messageHandler
newStateMachineActor :: state -> (state -> message -> IO (Either result state)) -> IO (Actor message result)
newStateMachineActor initialState = newActor . newStateMachine initialState

{-
    Sever behavior
-}
-- | Type synonym of callback function to obtain return value.
type ServerCallback a = (a -> IO ())

{-|
    Send an asynchronous request to a server.
-}
cast
    :: ActorQ cmd   -- ^ Message queue of the target server.
    -> cmd          -- ^ Request to the server.
    -> IO ()
cast = send

-- | Timeout of call method for server behavior in microseconds.  Default is 5 second.
newtype CallTimeout = CallTimeout Int

instance Default CallTimeout where
    def = CallTimeout 5000000

{-|
    Send an synchronous request to a server and waits for a return value until timeout.
-}
call
    :: CallTimeout                  -- ^ Timeout.
    -> ActorQ cmd                   -- ^ Message queue of the target server.
    -> (ServerCallback a -> cmd)    -- ^ Request to the server without callback supplied.
    -> IO (Maybe a)
call (CallTimeout usec) srv req = do
    rVar <- newEmptyTMVarIO
    send srv . req $ atomically . putTMVar rVar
    timeout usec . atomically . takeTMVar $ rVar

{-|
    Make an asynchronous call to a server and give result in CPS style.  The
    return value is delivered to given callback function.  It also can fail by
    timeout.  Calling thread can 'UnliftIO.wait' for a return value from the
    callback.

    Use this function with care because there is no guaranteed cancellation of
    background worker thread other than timeout.  Giving infinite timeout (zero)
    to the 'CallTimeout' argument may cause the background thread left to run,
    possibly indefinitely.
-}
callAsync
    :: CallTimeout                  -- ^ Timeout.
    -> ActorQ cmd                   -- ^ Message queue.
    -> (ServerCallback a -> cmd)    -- ^ Request to the server without callback supplied.
    -> (Maybe a -> IO b)            -- ^ callback to process return value of the call.  Nothing is given on timeout.
    -> IO (Async b)
callAsync tout srv req cont = async $ call tout srv req >>= cont

-- | Send an request to a server but ignore return value.
callIgnore
    :: ActorQ cmd                   -- ^ Message queue of the target server.
    -> (ServerCallback a -> cmd)    -- ^ Request to the server without callback supplied.
    -> IO ()
callIgnore srv req = send srv $ req (\_ -> pure ())


{-
    Supervisable IO action.
-}

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
    'MonitoredAction' is type synonym of function with callback on termination
    installed.  Its type signature fits to argument for 'forkIOWithUnmask'.
-}
type MonitoredAction = (IO () -> IO ()) -> IO ()

-- | Install 'Monitor' callback function to simple IO action.
watch :: Monitor -> IO () -> MonitoredAction
watch monitor = nestWatch monitor . noWatch

-- | Convert simple IO action to 'MonitoredAction' without installing 'Monitor'.
noWatch :: IO () -> MonitoredAction
noWatch action unmask = unmask action

-- | Install another 'Monitor' callback function to 'MonitoredAction'.
nestWatch :: Monitor -> MonitoredAction -> MonitoredAction
nestWatch monitor monitoredAction unmask = do
    reason <- newIORef Killed
    ((monitoredAction unmask *> writeIORef reason Normal) `catch` (writeIORef reason . UncaughtException))
        `finally` (readIORef reason >>= \r -> myThreadId >>= report r)
  where
    report r tid = do
        monitor r tid
        case r of
            UncaughtException e -> throwIO e
            _                   -> pure ()

{-|
    'Restart' defines when terminated child thread triggers restart operation by
    its supervisor.  'Restart' only defines when it triggers restart operation.
    It does not directly means if the thread will be or will not be restarted.
    It is determined by restart strategy of supervisor.  For example, a static
    'Temporary' child never triggers restart on its termination but static
    'Temporary' child will be restarted if another 'Permanent' or 'Transient'
    thread with common supervisor triggered restart operation and the supervisor
    has 'OneForAll' strategy.
-}
data Restart
    = Permanent -- ^ 'Permanent' thread always triggers restart.
    | Transient -- ^ 'Transient' thread triggers restart only if it was terminated by exception.
    | Temporary -- ^ 'Temporary' thread never triggers restart.
    deriving (Eq, Show)

{-|
    'ChildSpec' is representation of IO action which can be supervised by
    supervisor.  Supervisor can run the IO action with separate thread, watch
    its termination and restart it based on restart type.
-}
data ChildSpec = ChildSpec Restart MonitoredAction

-- | Create a 'ChildSpec' from 'MonitoredAction'.
newMonitoredChildSpec
    :: Restart          -- ^ Restart type of resulting 'ChildSpec'.  One of 'Permanent', 'Transient' or 'Temporary'.
    -> MonitoredAction  -- ^ User supplied monitored IO action which the 'ChildSpec' actually does.
    -> ChildSpec
newMonitoredChildSpec = ChildSpec

-- | Create a 'ChildSpec' from plain IO action.
newChildSpec
    :: Restart  -- ^ Restart type of resulting 'ChildSpec'.  One of 'Permanent', 'Transient' or 'Temporary'.
    -> IO ()    -- ^ User supplied IO action which the 'ChildSpec' actually does.
    -> ChildSpec
newChildSpec restart action = newMonitoredChildSpec restart $ noWatch action

-- | Add a 'Monitor' function to existing 'ChildSpec'.
addMonitor
    :: Monitor      -- ^ Callback function called when the IO action of the 'ChildSpec' terminated.
    -> ChildSpec    -- ^ Existing 'ChildSpec' where the 'Monitor' is going to be added.
    -> ChildSpec    -- ^ Newly created 'ChildSpec' with the 'Monitor' added.
addMonitor monitor (ChildSpec restart monitoredAction) = ChildSpec restart $ nestWatch monitor monitoredAction

-- | 'ThreadMap' is mutable variable which holds pool of living threads and
-- 'ChildSpec' of each thread.  ThreadMap is used inside of supervisor only.
type ThreadMap = IORef (Map ThreadId ChildSpec)

-- | Create an empty 'ThreadMap'
newThreadMap :: IO ThreadMap
newThreadMap = newIORef empty

-- | Start new thread based on given 'ChildSpec', register the thread to given
-- 'ThreadMap' then returns 'ThreadId' of the thread.
newThread
    :: ThreadMap    -- ^ Map of current live threads where the new thread is going to be added.
    -> ChildSpec    -- ^ Specification of newly started thread.
    -> IO ThreadId  -- ^ Thread ID of forked thread.
newThread children childSpec@(ChildSpec _ monitoredAction) = mask_ $ do
    tid <- forkIOWithUnmask $ \unmask -> monitoredAction unmask `catchAny` \_ -> pure ()
    modifyIORef' children $ insert tid childSpec
    pure tid

{-
    Restart intensity handling.
-}
{-|
    'RestartSensitivity' defines condition how supervisor determines intensive restart is happening.  If more than
    'restartSensitivityIntensity' time of restart is triggered within 'restartSensitivityPeriod', supervisor decides
    intensive restart is happening and it terminates itself.  Default intensity (maximum number of acceptable restart)
    is 1.  Default period is 5 seconds.
-}
data RestartSensitivity = RestartSensitivity
    { restartSensitivityIntensity :: Int        -- ^ Maximum number of restart accepted within the period below.
    , restartSensitivityPeriod    :: TimeSpec   -- ^ Length of time window in 'TimeSpec' where the number of restarts is counted.
    }

instance Default RestartSensitivity where
    def = RestartSensitivity 1 TimeSpec { sec = 5, nsec = 0 }

{-|
    'IntenseRestartDetector' keeps data used for detecting intense restart.  It keeps maxR (maximum restart intensity),
    maxT (period of majoring restart intensity) and history of restart with system timestamp in 'Monotonic' form.
-}
data IntenseRestartDetector = IntenseRestartDetector
    { intenseRestartDetectorPeriod  :: TimeSpec                 -- ^ Length of time window in 'TimeSpec' where the number of restarts is counted.
    , intenseRestartDetectorHistory :: DelayedQueue TimeSpec    -- ^ Restart timestamp history.
    }

-- | Create new IntenseRestartDetector with given 'RestartSensitivity' parameters.
newIntenseRestartDetector :: RestartSensitivity -> IntenseRestartDetector
newIntenseRestartDetector (RestartSensitivity maxR maxT) = IntenseRestartDetector maxT (newEmptyDelayedQueue maxR)

{-|
    Determine if the last restart results intensive restart.  It pushes the last restart timestamp to the 'DelayedQueue'
    of restart history held inside of the IntenseRestartDetector then check if the oldest restart record is pushed out
    from the queue.  If no record was pushed out, there are less number of restarts than limit, so it is not intensive.
    If a record was pushed out, it means we had one more restarts than allowed.  If the oldest restart and newest
    restart happened within allowed time interval, it is intensive.

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
    Determine if intensive restart is happening now.  It is called when restart is triggered by some thread termination.
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
    = Down ExitReason ThreadId                          -- ^ Notification of child thread termination.
    | StartChild ChildSpec (ServerCallback ThreadId)    -- ^ Command to start a new supervised thread.

-- | Type synonym for write-end of supervisor's message queue.
type SupervisorQueue = ActorQ SupervisorMessage
-- | Type synonym for read-end of supervisor's message queue.
type SupervisorInbox = Inbox SupervisorMessage

-- | Start a new thread with supervision.
newSupervisedThread
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ThreadMap        -- ^ Map of current live threads which the supervisor monitors.
    -> ChildSpec        -- ^ Specification of the child thread to be started.
    -> IO ThreadId
newSupervisedThread sv children childSpec =
    newThread children $ addMonitor monitor childSpec
      where
        monitor reason tid = cast sv (Down reason tid)

-- | Start all given 'ChildSpec' on new thread each with supervision.
startAllSupervisedThread
    :: SupervisorQueue  -- ^ Inbox message queue of the supervisor.
    -> ThreadMap        -- ^ Map of current live threads which the supervisor monitors.
    -> [ChildSpec]      -- ^ List of child specifications to be started.
    -> IO ()
startAllSupervisedThread sv children = traverse_ $ newSupervisedThread sv children

-- | Kill all running threads supervised by the supervisor represented by 'SupervisorQueue'.
killAllSupervisedThread :: SupervisorInbox -> ThreadMap -> IO ()
killAllSupervisedThread inbox children = uninterruptibleMask_ $ do
    pmap <- readIORef children
    for_ (keys pmap) killThread

    -- Because 'cancel' blocks until killed thread exited (in other word, it is
    -- synchronous operation), we are sure we no longer have any child thread
    -- still alive.  So it is okay to just put an empty thread map.
    writeIORef children empty

    -- Inbox of the SV potentially has unprocessed 'Down' massages for killed
    -- children remaining but they are no longer needed to to be processed since
    -- we already killed all children.  Let's cleanup but also keep messages
    -- other than 'Down' in the inbox.
    tryReceiveSelect isDownMessage inbox >>= go
  where
    go Nothing  = pure ()
    go (Just _) = tryReceiveSelect isDownMessage inbox >>= go

    isDownMessage (Down _ _) = True
    isDownMessage _          = False

-- | Restart strategy of supervisor
data Strategy
    = OneForOne -- ^ Restart only exited thread.
    | OneForAll -- ^ Restart all threads supervised by the same supervisor of exited thread.

{-|
    Create a supervisor with 'OneForOne' restart strategy and has no static
    'ChildSpec'.  When it started, it has no child threads.  Only 'newChild' can
    add new thread supervised by the supervisor.  Thus the simple one-for-one
    supervisor only manages dynamic and 'Temporary' children.
-}
newSimpleOneForOneSupervisor :: ActorHandler SupervisorMessage ()
newSimpleOneForOneSupervisor = newSupervisor OneForOne def []

{-|
    Create a supervisor.

    When created supervisor IO action started, it automatically creates child
    threads based on given 'ChildSpec' list and supervise them.  After it
    created such static children, it listens given 'SupervisorQueue'.  User can
    let the supervisor creates dynamic child thread by calling 'newChild'.
    Dynamic child threads created by 'newChild' are also supervised.

    When the supervisor thread is killed or terminated in some reason, all
    children including static children and dynamic children are all killed.

    With 'OneForOne' restart strategy, when a child thread terminated, it is
    restarted based on its restart type given in 'ChildSpec'.  If the terminated
    thread has 'Permanent' restart type, supervisor restarts it regardless its
    exit reason.  If the terminated thread has 'Transient' restart type, and
    termination reason is other than 'Normal' (meaning 'UncaughtException' or
    'Killed'), it is restarted.  If the terminated thread has 'Temporary'
    restart type, supervisor does not restart it regardless its exit reason.

    Created IO action is designed to run in separate thread from main thread.
    If you try to run the IO action at main thread without having producer of
    the supervisor queue you gave, the supervisor will dead lock.
-}
newSupervisor
    :: Strategy             -- ^ Restarting strategy of monitored threads.  'OneForOne' or 'OneForAll'.
    -> RestartSensitivity   -- ^ Restart intensity sensitivity in restart count and period.
    -> [ChildSpec]          -- ^ List of supervised child specifications.
    -> ActorHandler SupervisorMessage ()
newSupervisor strategy restartSensitivity childSpecs inbox = bracket newThreadMap (killAllSupervisedThread inbox) initSupervisor
  where
    initSupervisor children = do
        startAllSupervisedThread (ActorQ inbox) children childSpecs
        newStateMachine (newIntenseRestartDetector restartSensitivity) handler inbox
      where
        handler :: IntenseRestartDetector -> SupervisorMessage -> IO (Either () IntenseRestartDetector)
        handler hist (Down reason tid) = do
            pmap <- readIORef children
            threadRestart $ lookup tid pmap
          where
            threadRestart :: Maybe ChildSpec -> IO (Either () IntenseRestartDetector)
            threadRestart (Just childSpec@(ChildSpec restart _)) = do
                modifyIORef' children $ delete tid
                if restartNeeded restart reason
                then do
                    (intense, nextHist) <- detectIntenseRestartNow hist
                    if intense
                    then pure $ Left ()
                    else restartChild strategy children childSpec $> Right nextHist
                else
                    pure $ Right hist
            threadRestart Nothing = pure $ Right hist

            restartNeeded Temporary _      = False
            restartNeeded Transient Normal = False
            restartNeeded _         _      = True

        handler hist (StartChild (ChildSpec _ action) cont) =
            (newSupervisedThread (ActorQ inbox) children (ChildSpec Temporary action) >>= cont) $> Right hist

    restartChild OneForOne children spec = void $ newSupervisedThread (ActorQ inbox) children spec
    restartChild OneForAll children _    = do
        killAllSupervisedThread inbox children
        startAllSupervisedThread (ActorQ inbox) children childSpecs

-- | Ask the supervisor to spawn new temporary child thread.  Returns 'ThreadId'
-- of the new child.
newChild
    :: CallTimeout      -- ^ Request timeout in microsecond.
    -> SupervisorQueue  -- ^ Inbox message queue of the supervisor to ask new thread.
    -> ChildSpec        -- ^ Child specification of the thread to spawn.
    -> IO (Maybe ThreadId)
newChild tout sv spec = call tout sv $ StartChild spec
