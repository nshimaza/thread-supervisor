{-# LANGUAGE NoImplicitPrelude #-}

{-|
Module      : Control.Concurrent.Supervisor
Copyright   : (c) Naoto Shimazaki 2018
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

A simplified implementation of Erlang/OTP like supervisor over async and underlying behaviors.

-}

module Control.Concurrent.Supervisor
    (
      -- * Message queue
      --
      -- | 'MessageQueue' is specifically designed queue for implementing actor which is all behaviors available in this
      -- package depend on.  It provides following capabilities.
      --
      -- * Thread-safe write (push/send) end.
      -- * Blocking read (pull/receive) operation.
      -- * Selective read (pull/receive) operation with blocking and non-blocking options.
      -- * Current queue length.
      -- * Bounded queue.
      --
      -- Note that it is not a generic thread-safe queue.  Only write-end is thread-safe but read-end is /NOT/
      -- thread-safe.  'MessageQueue' assumes only one thread reads from a queue.  In order to protect read-end of
      -- 'MessageQueue', no 'MessageQueue' constructor is exposed but instead you can get it only via 'newActor' or
      -- 'newBoundedActor'.
      --
      -- From outside of actor, only write-end is exposed via 'MessageQueueTail'.  From inside of actor, read-end is
      -- available via 'MessageQueue' and write-end is available too via wrapping 'MessageQueue' by 'MessageQueueTail'.
      MessageQueue
    , MessageQueueTail (..)
    , sendMessage
    , trySendMessage
    , length
    , receive
    , tryReceive
    , receiveSelect
    , tryReceiveSelect
    -- * Actor
    --
    -- | Actor is IO action emulating Erlang's actor.  It has a dedicated 'MessageQueue' and processes incoming messages
    -- until reaching end state.  'newActor' and 'newBoundedActor' create an actor with new 'MessageQueue'.  It is the
    -- only exposed way to create a new 'MessageQueue'.  This limitation is intended to make it harder to access to
    -- read-end of 'MessageQueue' from other than inside of actor's message handler.
    --
    -- From perspective of outside of actor, user supplies an IO action with type 'ActorHandler' to 'newActor' or
    -- 'newBoundedActor' then get actor and write-end of message queue of the actor.
    --
    -- From perspective of inside of actor, in other word, from perspective of user supplied message handler, it has
    -- a message queue both side available.
    --
    -- __Important__
    --
    -- Current actor implementation does /NOT/ allow shared inbox.  /NEVER/ run actor (IO action returned by 'newActor'
    -- or 'newBoundedActor') in multiple thread at a time.  If you need to run your IO action concurrently, you have to
    -- create multiple actor instances from the same IO action in order to ensure each actor has dedicated
    -- 'MessageQueue' instance.
    , ActorHandler
    , newActor
    , newBoundedActor
    -- * Supervisable IO action
    , Restart (..)
    , ExitReason (..)
    , Monitor
    , ProcessSpec
    , newProcessSpec
    , addMonitor
    -- * Supervisor
    , RestartSensitivity (..)
    , IntenseRestartDetector
    , newIntenseRestartDetector
    , detectIntenseRestart
    , detectIntenseRestartNow
    , Strategy (..)
    , SupervisorQueue
    , newSupervisor
    , newSimpleOneForOneSupervisor
    , newChild
    -- * State machine
    , newStateMachine
    , CallTimeout (..)
    -- * Simple server behavior
    , ServerCallback
    , cast
    , call
    , callAsync
    , callIgnore
    ) where

import           Control.Concurrent.SupervisorInternal
