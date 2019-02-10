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
      {-|
          'Inbox' is specifically designed queue for implementing actor which is all behaviors available in this package
          depend on.  It provides following capabilities.

          * Thread-safe read (pull, receive) and write (push, send) end.
          * Blocking and non-blocking read (pull, receive) operation.
          * Selective read (pull, receive) operation.
          * Current queue length.
          * Bounded queue.

          Note that 'Inbox' is intended to be used for inbox of actor.  In order to avoid different actors accidentally
          reading from same 'Inbox', no 'Inbox' constructor is exposed but instead you can get it only via 'newActor' or
          'newBoundedActor'.

          From outside of actor, only write-end is exposed via 'Actor'.  From inside of actor, read-end is available via
          'Inbox' and write-end is available too via wrapping 'Inbox' by 'Actor'.
      -}
      Inbox
    , Actor (..)
    , send
    , trySend
    , length
    , receive
    , tryReceive
    , receiveSelect
    , tryReceiveSelect
    -- * Actor
    {-|
        Actor is IO action emulating Erlang's actor.  It has a dedicated 'Inbox' and processes incoming messages until
        reaching end state.  'newActor' and 'newBoundedActor' create an actor with new 'Inbox'.  It is the only exposed
        way to create a new 'Inbox'.  This limitation is intended to make it harder to access to read-end of 'Inbox'
        from other than inside of actor's message handler.

        From perspective of outside of actor, user supplies an IO action with type 'ActorHandler' to 'newActor' or
        'newBoundedActor' then get actor and write-end of message queue of the actor.

        From perspective of inside of actor, in other word, from perspective of user supplied message handler, it has a
        message queue both side available.

        __Shared Inbox__

        You can run created actor multiple time simultaneously with different thread each.  In such case, each actor
        instances share single 'Inbox'.  This would be useful to distribute task stream to multiple worker actors,
        however, keep in mind there is no way to control which message is routed to what actor.
    -}
    , ActorHandler
    , newActor
    , newBoundedActor
    -- * Supervisable IO action
    -- ** Monitored action
    {-|
        This package provides facility for supervising IO actions.  With types and functions in this section, you can
        run IO action its own thread (wrapped by 'UnliftIO.Async') and receive notification on its termination at
        another thread with reason of termination.

        Use 'UnliftIO.bracket' when you just need resource cleanup on thread termination.  Use this API when you need to
        watch termination of a thread from another thread.  Supervisor internally uses this API.

        Notification is delivered via user supplied callback.  You can install your callback to your IO action, then the
        callback will be called on termination of the IO action.

        __Important__

        Callback is called in terminated thread.  You have to use inter-thread communication to notify it to another
        thread.

        'MonitoredAction' is IO action with callback installed.  It has following type signature instead of @IO ()@.

        > (IO () -> IO ()) -> IO ()

        It is because 'MonitoredAction' will be invoked with 'UnliftIO.asyncWithUnmask'.  In order to ensure callback on
        termination works in any timing, the callback must be installed under asynchronous exception masked.  At the
        same time, in order to allow killing the tread from another thread, body IO action must be executed with
        asynchronous exception allowed.  To satisfy both conditions, the IO action and callback must be called using
        'UnliftIO.asyncWithUnmask'.  Typically it looks like following.

        > mask_ $ asyncWithUnmask $ \unmask -> unmask action `finally` callback

        Type signature of 'MonitoredAction' fits to argument for 'UnliftIO.asyncWithUnmask'.  Functions defined in this
        section help installing callback and converting type to fit to 'UnliftIO.asyncWithUnmask'.

        Callback function installed with a helper function in this section receives 'ExitReason' so that user can
        determine why the tread is terminated.  To receive 'ExitReason' callback must have type signature 'Monitor'.

        Callback can be nested.  Use 'nestWatch' to install another callback to already monitored action.
    -}
    , MonitoredAction
    , ExitReason (..)
    , Monitor
    , watch
    , nestWatch
    , noWatch
    -- ** Process Specification
    , Restart (..)
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
