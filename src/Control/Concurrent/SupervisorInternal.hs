module Control.Concurrent.SupervisorInternal where

import           Control.Concurrent.STM.TQueue (TQueue, readTQueue, writeTQueue)
import           Control.Monad.STM             (atomically)


type MessageQueue a = TQueue a

makeStateMachine
    :: MessageQueue message -- ^ Event input queue of the state machine.
    -> state                -- ^ Initial state of the state machinwe.
    -> (state -> message -> IO (Either result state))
                            -- ^ Event handler which processes event and returns result or next state.
    -> IO result
makeStateMachine inbox initialState messageHandler = go $ Right initialState
  where
    go (Right state) = atomically (readTQueue inbox) >>= messageHandler state >>= go
    go (Left result) = pure result

sendMessage
    :: MessageQueue message -- ^ Queue the event to be sent.
    -> message              -- ^ Sent event.
    -> IO ()
sendMessage q = atomically . writeTQueue q
