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
      -- * Thread-safe read (pull/receive) and write (push/send) end.
      -- * Blocking and non-blocking read (pull/receive) operation.
      -- * Selective read (pull/receive) operation.
      -- * Current queue length.
      -- * Bounded queue.
      --
      -- Note that 'MessageQueue' is intended to be used for inbox of actor.  In order to avoid different actors
      -- accidentally reading from same 'MessageQueue', no 'MessageQueue' constructor is exposed but instead you can get
      -- it only via 'newActor' or 'newBoundedActor'.
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
    -- __Shared Inbox__
    --
    -- You can run created actor multiple time simultaneously with different thread each.  In such case, each actor
    -- instances share single 'MessageQueue'.  This would be useful to distribute task stream to multiple worker
    -- actors, however, keep in mind there is no way to control which message is routed to what actor.
    , ActorHandler
    , newActor
    , newBoundedActor
    -- * Supervisable IO action
    , Restart (..)
    , ExitReason (..)
    , Monitor
    , installMonitor
    , installNestedMonitor
    , installNullMonitor
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
