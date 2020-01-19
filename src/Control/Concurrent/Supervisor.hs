{-# LANGUAGE NoImplicitPrelude #-}

{-|
Module      : Control.Concurrent.Supervisor
Copyright   : (c) Naoto Shimazaki 2018-2020
License     : MIT (see the file LICENSE)
Maintainer  : https://github.com/nshimaza
Stability   : experimental

A simplified implementation of Erlang/OTP like supervisor over thread and
underlying behaviors.

-}

module Control.Concurrent.Supervisor
    (
    -- * Message queue
    {-|
        'Inbox' is specifically designed queue for implementing actor.  All
        behaviors available in this package depend on it.  It provides following
        capabilities.

        * Thread-safe read\/pull\/receive and write\/push\/send.
        * Blocking and non-blocking read operation.
        * Selective read operation.
        * Current queue length.
        * Bounded queue.

        The type 'Inbox' is intended to be used only for pulling side as inbox
        of actor.  Single Inbox object is only readable from single actor.  In
        order to avoid from other actors, no Inbox constructor is exposed but
        instead you can get it only via 'newActor' or 'newBoundedActor'.

        'Actor' is actually just a wrapper of 'Inbox'.  Its role is hiding
        write-end API of Inbox.  From outside of actor, only write-end is
        exposed via Actor.  From inside of actor, both read-end and write-end
        are available.  You can read from given inbox directly.  You need to
        wrap the inbox by Actor when you write to the inbox.

        When you need to send a message to your inbox, do this.

        > send (Actor yourInbox) message
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
        Actor is IO action emulating Erlang's actor.  It has a dedicated 'Inbox'
        and processes incoming messages until reaching end state.  'newActor'
        and 'newBoundedActor' create an actor with new Inbox.  It is the only
        exposed way to create a new Inbox.  This limitation is intended.  It
        prevents any code other than message handler of the actor reading the
        inbox.

        From perspective of outside of actor, user supplies an IO action with
        type 'ActorHandler' to 'newActor' or 'newBoundedActor' then user gets IO
        action of created actor and write-end of message queue of the actor,
        which is 'Actor' type value.

        From perspective of inside of actor, in other word, from perspective of
        user supplied message handler, it has a message queue both read and
        write side available.

        __Shared Inbox__

        You can run created actor multiple time simultaneously with different
        thread each.  In such case, each actor instances share single 'Inbox'.
        This would be useful to distribute task stream to multiple worker actor
        instances, however, keep in mind there is no way to control which
        message is routed to what actor.
    -}
    , ActorHandler
    , newActor
    , newBoundedActor
    -- * Supervisable IO action
    -- ** Monitored action
    {-|
        This package provides facility for supervising IO actions.  With types
        and functions in this section, you can run IO action with its own thread
        and receive notification on its termination at another thread with
        reason of termination.  Functions in this section provides guaranteed
        supervision of your thread.

        It looks something similar to 'UnliftIO.bracket'.  What distinguishes
        from bracket is guaranteed work through entire lifetime of thread.

        Use 'UnliftIO.bracket' when you need guaranteed cleanup of resources
        acquired within the same thread.  It works as you expect.  However,
        installing callback for thread supervision using bracket (or
        'UnliftIO.finally' or even low level 'UnliftIO.catch') within a thread
        has /NO/ guarantee.  There is a little window where asynchronous
        exception is thrown after the thread is started but callback is not yet
        installed.  We will discuss this later in this section.

        Notification is delivered via user supplied callback.  Helper functions
        described in this section install your callback to your IO action.  Then
        the callback will be called on termination of the IO action.

        __Important__

        Callback is called in terminated thread.  You have to use inter-thread
        communication in order to notify to another thread.

        User supplied callback receives 'ExitReason' and
        'UnliftIO.Concurrent.ThreadId' so that user can determine witch thread
        was terminated and why it was terminated.  In order to receive those
        parameters, user supplied callback must have type signature 'Monitor',
        which is following.

        > ExitReason -> ThreadId -> IO ()

        Function 'watch' installs your callback to your plain IO action then
        returns monitored action.

        Callback can be nested.  Use 'nestWatch' to install another callback to
        already monitored action.

        Helper functions return IO action with signature 'MonitoredAction'
        instead of plain @IO ()@.  From here to the end of this section it will
        be a little technical deep dive for describing why it has such
        signature.

        The signature of 'MonitoredAction' is this.

        > (IO () -> IO ()) -> IO ()

        It requires an extra function argument.  It is because 'MonitoredAction'
        will be invoked with 'UnliftIO.Concurrent.forkIOWithUnmask'.

        In order to ensure callback on termination works in any timing, the
        callback must be installed under asynchronous exception masked.  At the
        same time, in order to allow killing the tread from another thread, body
        of IO action must be executed under asynchronous exception /unmasked/.
        In order to satisfy both conditions, the IO action and callback must be
        called using 'UnliftIO.Concurrent.forkIOWithUnmask'.  Typically it looks
        like following.

        > mask_ $ forkIOWithUnmask $ \unmask -> unmask action `finally` callback

        The extra function parameter in the signature of 'MonitoredAction' is
        used for accepting the @unmask@ function which is passed by
        'UnliftIO.Concurrent.forkIOWithUnmask'.  Functions defined in this
        section help installing callback and converting type to fit to
        'UnliftIO.Concurrent.forkIOWithUnmask'.
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
