module Control.Concurrent.SupervisorInternal where

import           Control.Concurrent.Async      (Async, async)
import           Control.Concurrent.STM.TMVar  (TMVar, newEmptyTMVarIO,
                                                putTMVar, takeTMVar)
import           Control.Concurrent.STM.TQueue (TQueue, readTQueue, writeTQueue)
import           Control.Exception.Safe        (bracket)
import           Control.Monad.STM             (atomically)
import           Data.Default
import           System.Timeout                (timeout)


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


data ServerCommand arg ret
    = Cast arg
    | Call arg (TMVar ret)

type ServerQueue arg ret = MessageQueue (ServerCommand arg ret)

newServer
    :: ServerQueue arg ret                          -- ^ Message queue.
    -> IO state                                     -- ^ Initialize.
    -> (state -> IO a)                              -- ^ Cleanup.
    -> (state -> arg -> IO (Either b state))        -- ^ Cast message handler.
    -> (state -> arg -> IO (ret, Either b state))   -- ^ Call message handler.
    -> IO b
newServer inbox init cleanup castHandler callHandler = bracket init cleanup $ \state ->
    newStateMachine inbox state server
  where
    server state (Cast arg)     = castHandler state arg
    server state (Call arg ret) = do
        (result, nextState) <- callHandler state arg
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
