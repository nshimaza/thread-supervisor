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
    -- * Actor and Message queue
    {-|
        Actor is restartable IO action with inbound message queue.  Actor is
        designed to allow other threads sending messages to an actor keep using
        the same write-end of the queue before and after restart of the actor.
        Actor consists of message queue and its handler.  'Inbox' is a message
        queue designed for actor's message inbox.  It is thread-safe, bounded or
        unbounded, and selectively readable queue.

        To protect read-end of the queue, it has different type for read-end and
        write-end.  Message handler of actor can access to both end but only
        write-end is accessible from outside of message handler.  To realize
        this, constructor of 'Inbox' is not exposed.  The only way to create a
        new 'Inbox' object is creating a new actor using 'newActor' function.

        > newActor :: (Inbox message -> IO result) -> IO (Actor message result)

        This package provides type synonym for message handler as below.

        > type ActorHandler message result = (Inbox message -> IO result)

        'newActor' receives an user supplied message handler, creates a new
        'Inbox' value, then returns write-end of actor's message queue and IO
        action of the actor's body wrapped by 'Actor'.  'Actor' is defined as
        following.

        > data Actor message result = Actor
        >     { actorQueue  :: ActorQ message -- ^ Write end of message queue of 'Actor'
        >     , actorAction :: IO result      -- ^ IO action to execute 'Actor'
        >     }

        The 'ActorQ message' in the 'Actor' is the write-end of created 'Inbox'.
        While user supplied message handler receives 'Inbox', which is read-end
        of created queue, caller of 'newActor' gets write-end only.
    -}
    -- ** Message queue
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
    -}
    -- *** Read an oldest message from 'Inbox'
    {-|
        To read a message at the head of message queue, apply 'receive' to
        'Inbox'.  If one or more message is available, 'receive' returns oldest
        one.  If no message is available, 'receive' blocks until at least one
        message arrives.  A skeleton of actor message handler will look like
        this.

        > myActorHandler :: Inbox YourMessageType -> IO ()
        > myActorHandler inbox = do
        >     newMessage <- receive inbox
        >     doSomethingWith newMessage
        >     myActorHandler inbox
    -}
    -- *** Send a message to an actor
    {-|
        To send a message to an actor, call 'send' with write-end of the actor's
        inbox and the message.

        >     send :: ActorQ message -> message -> IO ()
    -}
    {-|
        'ActorQ' is write-end of actor's message queue.  'ActorQ' is actually
        just a wrapper of 'Inbox'.  Its role is hiding read-end API of Inbox.
        From outside of actor, only write-end is exposed via ActorQ.  From
        inside of actor, both read-end and write-end are available.  You can
        read from given inbox directly.  You need to wrap the inbox by Actor
        when you write to the inbox.
    -}
    -- *** Send a message from an actor to itself
    {-|
        When you need to send a message to your inbox, do this.

        >     send (ActorQ yourInbox) message

        You can convert 'Inbox' (read-end) to 'ActorQ' (write-end) by wrapping
        'Inbox' by 'ActorQ' so that you can send a message from an actor to
        itself.

        > myActorHandler :: Inbox YourMessageType -> IO ()
        > myActorHandler inbox = do
        >     newMessage <- receive inbox
        >     doSomethingWith newMessage
        > 
        >     send (ActorQ inbox) messageToMyself -- Send a message to itself.
        > 
        >     myActorHandler inbox
    -}
      Inbox
    , ActorQ (..)
    , send
    , trySend
    , length
    , receive
    , tryReceive
    , receiveSelect
    , tryReceiveSelect
    -- ** Actor
    {-|
        Actor is IO action emulating Erlang's actor.  
        It has a dedicated 'Inbox' and processes incoming messages until
        reaching end state.

        Actor is restartable without replacing message queue.  When actor's IO
        action crashed and restarted, the new execution of the IO action
        continue referring the same message queue.  Thus, threads sending
        messages to the actor can continue using the same write-end of the
        queue.

        'newActor' and 'newBoundedActor' create an actor with new Inbox.  It is
        the only exposed way to create a new Inbox.  This limitation is
        intended.  It prevents any code other than message handler of the actor
        from reading the inbox.

        From perspective of outside of actor, user supplies an IO action with
        type 'ActorHandler' to 'newActor' or 'newBoundedActor' then user gets IO
        action of created actor and write-end of message queue of the actor,
        which is 'ActorQ' type value.

        From perspective of inside of actor, in other word, from perspective of
        user supplied message handler, it has a message queue both read and
        write side available.
    -}
    -- *** Shared Inbox
    {-|
        You can run created actor multiple time simultaneously with different
        thread each.  In such case, each actor instances share single 'Inbox'.
        This would be useful to distribute task stream to multiple worker actor
        instances, however, keep in mind there is no way to control which
        message is routed to what actor.
    -}
    , ActorHandler
    , Actor (..)
    , newActor
    , newBoundedActor
    -- * Supervisable IO action
    -- ** Monitored action
    {-|
        This package provides facility for supervising IO actions.  With types
        and functions described in this section, you can run IO action with its
        own thread and receive notification on its termination at another thread
        with reason of termination.  Functions in this section provides
        guaranteed supervision of your thread.

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
    -}
    -- *** Important:  Callback is called in terminated thread
    {-|
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
    -- ** Child Specification
    {-|
        'ChildSpec' is casting mold of child thread IO action which supervisor
        spawns and manages.  It is passed to supervisor, then supervisor let it
        run with its own thread, monitor it, and restart it if needed.
        ChildSpec provides additional attributes to 'MonitoredAction' for
        controlling restart on thread termination.  That is 'Restart'.
        'Restart' represents restart type concept came from Erlang/OTP.  The
        value of 'Restart' defines how restart operation by supervisor is
        triggered on termination of the thread.  'ChildSpec' with 'Permanent'
        restart type triggers restart operation regardless its reason of
        termination.  It triggers restarting even by normal exit.  'Transient'
        triggers restarting only when the thread is terminated by exception.
        'Temporary' never triggers restarting.

        Refer to Erlang/OTP for more detail of restart type concept.

        'newMonitoredChildSpec' creates a new 'ChildSpec' from a
        'MonitoredAction' and a restart type value.  'newChildSpec' is short cut
        function creating a 'ChildSpec' from a plain IO action and a restart
        type value.  'addMonitor' adds another monitor to existing 'ChildSpec'.
    -}
    , Restart (..)
    , ChildSpec
    , newChildSpec
    , newMonitoredChildSpec
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
    {-|
        State machine behavior is most essential behavior in this package.  It
        provides framework for creating IO action of finite state machine
        running on its own thread.  State machine has single 'Inbox', its local
        state, and a user supplied message handler.  State machine is created
        with initial state value, waits for incoming message, passes received
        message and current state to user supplied handler, updates state to
        returned value from user supplied handler, stops or continue to listen
        message queue based on what the handler returned.

        To create a new state machine, prepare initial state of your state
        machine and define your message handler driving your state machine,
        apply 'newStateMachine' to the initial state and handler.  You will get
        a 'ActorHandler' so you can get an actor of the state machine by
        applying 'newActor' to it.

        > Actor queue action <-  newActor $ newStateMachine initialState handler

        Or you can use short-cut helper.

        > Actor queue action <-  newStateMachineActor initialState handler

        The 'newStateMachine' returns write-end of message queue for the state
        machine and IO action to run.  You can run the IO action by
        'Control.Concurrent.forkIO' or 'Control.Concurrent.async', or you can
        let supervisor run it.

        User supplied message handler must have following type signature.

        > handler :: (state -> message -> IO (Either result state))

        When a message is sent to state machine's queue, it is automatically
        received by state machine framework, then the handler is called with
        current state and the message.  The handler must return either result or
        next state.  When 'Left result' is returned, the state machine stops and
        returned value of the IO action is @IO result@.  When 'Right state' is
        returned, the state machine updates current state with the returned
        state and wait for next incoming message.
    -}
    , newStateMachine
    , newStateMachineActor
    -- * Simple server behavior
    {-|
        Server behavior provides synchronous request-response style
        communication, a.k.a. ask pattern, with actor.  Server behavior allows
        user to send a request to an actor then wait for response form the
        actor.  This package provides a framework for implementing such actor.

        Server behavior in this package is actually a set of helper functions
        and type synonym to help implementing ask pattern over actor.  User need
        to follow some of rules described below to utilize those helpers.
    -}
    -- ** Define ADT type for messages
    {-|
        First, user need to define an algebraic data type for message to the
        server in following form.

        > data myServerCommand
        >     = ReqWithoutResp1
        >     | ReqWithoutResp2 Arg1
        >     | ReqWithoutResp3 Arg2 Arg3
        >     | ReqWithResp1 (ServerCallback Result1)
        >     | ReqWithResp1 ArgX (ServerCallback Result2)
        >     | ReqWithResp2 ArgY ArgZ (ServerCallback Result3)

        The rule is this:

        * Define an ADT containing all requests.
        * If a request doesn't return response, define a value type for the
          request as usual element of sum type.
        * If a request returns a response, put @(ServerCallback ResultType)@ at
          the last argument of the constructor for the request where
          @ResultType@ is type of returned value.

        'ServerCallback' is type synonym of a function type as following.

        > type ServerCallback a = (a -> IO ())

        So real definition of your @myServerCommand@ is:

        > data MyServerCommand
        >     = ReqWithoutResp1
        >     | ReqWithoutResp2 Arg1
        >     | ReqWithoutResp3 Arg2 Arg3
        >     | ReqWithResp1 (Result1 -> IO ())
        >     | ReqWithResp2 ArgX (Result2 -> IO ())
        >     | ReqWithResp3 ArgY ArgZ (Result3 -> IO ())
    -}
    -- ** Define message handler
    {-|
        Next, user need to define an actor handling the message.  In this
        example, we will use state machine behavior so that we can focus on core
        message handling part.  For simplicity, this example doesn't have
        internal state and it never finishes.

        Define a state machine message handler handling @myServerCommand@.  

        > myHandler :: () -> MyServerCommand -> IO (Either () ())
        > myHandler _  ReqWithoutResp1                  = doJob1 $> Right ()
        > myHandler _ (ReqWithoutResp2 arg1)            = doJob2 arg1 $> Right ()
        > myHandler _ (ReqWithoutResp3 arg2 arg3)       = doJob3 arg2 arg3 $> Right ()
        > myHandler _ (ReqWithResp1 cont1)              = (doJob4 >>= cont1) $> Right ()
        > myHandler _ (ReqWithResp2 argX cont2)         = (doJob5 argX >>= cont2) $> Right ()
        > myHandler _ (ReqWithResp3 argY argZ cont3)    = (doJob6 argY argZ >>= cont3) $> Right ()

        The core idea here is implementing request handler in CPS style.  If a
        request returns a response, the request message comes with callback
        function (a.k.a.  continuation).  You can send back response for the
        request by calling the callback.
    -}
    -- ** Requesting to server
    {-|
        Function 'call', 'callAsync', and 'callIgnore' are helper functions to
        implement request-response communication with server.  They install
        callback to message, send the message, returns response to caller.  They
        receive partially applied server message constructor, apply it to
        callback function, then send it to server.  The installed callback
        handles response from the server.  You can use 'call' like following.

        >     maybeResult1 <- call def myServerActor ReqWithResp1
        >     maybeResult2 <- call def myServerActor $ ReqWithResp2 argX
        >     maybeResult3 <- call def myServerActor $ ReqWithResp3 argY argZ

        When you send a request without response, use `cast`.

        >     cast myServerActor ReqWithoutResp1
        >     cast myServerActor $ ReqWithoutResp2 arg1
        >     cast myServerActor $ ReqWithoutResp3 arg2 arg3

        When you send a request with response but ignore it, use `callIgnore`.

        >     callIgnore myServerActor ReqWithResp1
        >     callIgnore myServerActor $ ReqWithResp2 argX
        >     callIgnore myServerActor $ ReqWithResp3 argY argZ

        Generally, ask pattern, or synchronous request-response communication is
        not recommended in actor model.  It is because synchronous request
        blocks entire actor until it receives response or timeout.  You can
        mitigate the situation by wrapping the synchronous call with `async`.
        Use `callAsync` for such purpose.
    -}
    , CallTimeout (..)
    , ServerCallback
    , cast
    , call
    , callAsync
    , callIgnore
    ) where

import           Control.Concurrent.SupervisorInternal
