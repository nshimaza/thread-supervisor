# thread-supervisor

[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Build Status](https://travis-ci.org/nshimaza/thread-supervisor.svg?branch=master)](https://travis-ci.org/nshimaza/thread-supervisor)

A simplified implementation of Erlang/OTP like supervisor over thread.

# Overview

This package provides Erlang/OTP like thread supervision.
It provides automatic restart, escalation of intense crash, guaranteed cleanup
of child threads on supervisor termination.

### Motivation

Unlike Unix process, plain Haskell thread, created by forkIO, has no
parent-child relation each other in its lifecycle management.  This means
termination of parent thread doesn't result its children also terminated.
This is good design as a low level API because it gives user greatest
flexibility.  However, it also means managing entire lifecycle of thread is
totally a responsibility of user.

Here one thing you need to be aware.  Garbage collection doesn't work on living
thread.  When you lost reference to an object, garbage collector frees up the
object for you.  However, even though you lost the thread ID of your child
thread, Haskell runtime doesn't consider the thread is orphaned.  The child
thread continues running.

This is prone to create thread leakage.  You can accidentally lose thread ID of
child thread by crash of parent thread.  Now you no longer have way to kill
orphaned child thread.  This is thread leakage.

The low level forkIO API requires you keep track and manage entire thread
lifecycle including accidental case like the above.  Hand crafting it might be
painful.

This package is intended to provide better wrapper API over plain forkIO.  Not
just providing parent-child thread lifecycle management, this package provides
Erlang/OTP like API so that user can leverage well proven practices from
Erlang/OTP.

If you need to keep your child running after parent terminated, this API is not
for you.

### Why not withAsync?

In short, `withAsync` addresses different problem than this package.

* `withAsync`: Accessing multiple REST server concurrently then gather all
  responses with guarantee of cancellation of all the request on termination
  of calling thread.
* `thread-supervisor`: Implementing server where unknown number of independent
  concurrent requests with indeterministic lifecycle will arrive.

A typical use case for this package is TCP server style use case.  In such use
case, you have to create unpredictable number of threads in order to serve to
clients and those threads finish in random timings.

The `withAsync` coming with `async` package solves different problem than this
package.  It is good for taking actions asynchronously but eventually you need
their return values.  Or, even you aren't care of return values, you only need
to take several finite number of actions concurrently.

Bellow explains why `withAsync` is not good for managing large number of
threads.

`withAsync` is essentially a sugar over bracket pattern like this.

```haskell
withAsync action inner = bracket (async action) uninterruptibleCancel inner
```

It guarantees execution of `uninterruptibleCancel` to the `action` on
asynchronous exception occurrence at parent thread where withAsync itself is
living.  However it also guarantees the `uninterruptibleCancel` is executed on
normal exit from `inner` too.  Thus, the `action` can only live within the
lifecycle of the `withAsync` call.  If you want to keep your `action` alive, you
have to keep `inner` continue running until your `action` finishes.

So, what if you kick async action go and make recursive call form `inner` back
to your loop?  It is a bad idea.  Because `withAsync` is a `bracket`, recursive
call from `inner` makes non-tail-recurse call.

In other words, the difference between `withAsync` and `thread-supervisor` is
strategy of installing / un-installing cleanup handler.  `withAsync` installs
cleanup handler on stack so it uninstalls handler based on its lexical scope.
`thread-supervisor` installs cleanup handler surrounding user supplied action so
it uninstalls handlers at actual dynamic thread termination.



# Quick Start

## High level steps to use

1. Create a `MonitoredAction` from your IO action
1. Create a `ChildSpec` from the `MonitoredAction`
1. Let a supervisor run the `ChildSpec` in a supervised thread

Detail will be different whether you create static child thread or dynamic child
thread.

## Create a static child

Static child is thread automatically spawned when supervisor starts.  Following
procedure makes your IO action a static child.

1. Create a `MonitoredAction` from your IO action
1. Create a `ChildSpec` from the `MonitoredAction`
1. Give the `ChildSpec` to `newSupervisor`
1. Run generated supervisor

Static children are automatically forked when supervisor started or one-for-all
supervisor performed restarting action. When IO action inside of static child
terminated, regardless normal completion or exception, supervisor checks if
restart operation needed based on combination of restart type of terminated
child and reason of termination.  If supervisor decides restart is needed, it
performs restarting operation based on its restart strategy, which can be
one-for-one or one-for-all.

A supervisor can have any number of static children.  Static children must be
given when supervisor is created by `newSupervisor`.

## Static child example

Following code creates a supervisor actor with two static children and run it in
new thread.

```haskell
runYourSupervisorWithStaticChildren = do
    (svQ, svAction) <- newActor . newSupervisor $ OneForAll def
        [ newChildSpec Permanent yourIOAction1
        , newChildSpec Permanent yourIOAction2
        ]
    async svAction
```

The idiom `newActor . newSupervisor` returns `(svQ, svAction)` where `svQ` is
write-end of message queue for the supervisor actor, which we don't use here,
and `svAction` is body IO action of the supervisor.  When the `svAction` is
actually evaluated, it automatically forks two threads.  One is for
`yourIOAction1` and the other is for `yourIOAction2`.  Because restart type of
given static children are both `Permanent`, the supervisor always kicks
restarting operation when one of `yourIOAction1` or `yourIOAction2` is
terminated.  When restarting operation is kicked, the supervisor kills remaining
thread and restarts all children again because its restarting strategy is
one-for-all.

When the supervisor is terminated, both `yourIOAction1` and `yourIOAction2` are
automatically killed by the supervisor.  To kill the supervisor, apply `cancel`
to the async object returned by `async svAction`.

## Create a dynamic child

Dynamic child is thread explicitly forked via `newChild` function.  Following
procedure runs your IO action as a dynamic child.

1. Run a supervisor
1. Create a `ChildSpec` from your IO action
1. Request the supervisor to create a dynamic child based on the `ChildSpec` by
   calling `newChild`

Dynamic children are explicitly forked to each thread via `newChild` request to
running supervisor.  Supervisor never restarts dynamic child.  It ignores
restart type defined in `ChildSpec` of dynamic child.

## Dynamic child example

Following code runs a supervisor in different thread then request it to run a
dynamic child.

```haskell
    -- Run supervisor in another thread
    (svQ, svAction) <- newActor $ newSimpleOneForOneSupervisor
    asyncSv <- async svAction
    -- Request to run your action under the supervisor
    let yourChildSpec = newChildSpec Temporary yourIOAction
    maybeChildThreadId <- newChild def svQ yourChildSpec
```

The idiom `newActor $ newSimpleOneForOneSupervisor` returns `(svQ, svAction)`
where `svQ` is write-end of message queue for the supervisor actor and
`svAction` is body IO action of the supervisor.  When the `svAction` is actually
evaluated, it listens `svQ` and wait for request to run dynamic child.

When `newChild` is called with `svQ`, it sends request to the supervisor to run
a dynamic child with given `ChildSpec`.

When the supervisor is terminated, requested children are automatically killed
by the supervisor if they are still running.

To kill the supervisor, apply `cancel` to `asyncSv`.



# Building Blocks

This package consists of following building blocks.

* Actor and Message queue
* Monitored IO action and supervisable IO action
* Behaviors (state machine, server, and supervisor)

Actor and message queue is lowest layer block of this package.  Behaviors are
built upon this block.  It is exposed to user so that you can use it for
implementing actor style concurrent program.

Monitored IO action is the heart of this package.  It implements most sensitive
part of dealing with asynchronous exception.  Monitored IO action provides
guaranteed notification on thread termination so that supervisor can provide
guaranteed supervision on threads.

Behaviors - state machine, server, and supervisor - implement simplified
Erlang/OTP behaviors so that user can leverage best practice of concurrent
programming from Erlang/OTP.

## Actor and Message queue

Actor is restartable IO action with inbound message queue.  Actor is designed to
allow other threads sending messages to an actor keep using the same write-end
of the queue before and after restart of the actor.  Actor consists of message
queue and its handler.  `Inbox` is a message queue designed for actor's message
inbox.  It is thread-safe, bounded or unbounded, and selectively readable queue.

To protect read-end of the queue, it has different type for read-end and
write-end.  Message handler of actor can access to both end but only write-end
is accessible from outside of message handler.  To realize this, constructor of
`Inbox` is not exposed.  The only way to create a new `Inbox` object is creating
a new actor using `newActor` function.

```haskell
newActor :: (Inbox message -> IO result) -> IO (Actor message result)
```

This package provides type synonym for message handler as below.

```haskell
type ActorHandler message result = (Inbox message -> IO result)
```

`newActor` receives an user supplied message handler, creates a new `Inbox`
value, then returns write-end of actor's message queue and IO action of the
actor's body wrapped by `Actor`.  `Actor` is defined as following.

```haskell
data Actor message result = Actor
    { actorQueue  :: ActorQ message -- ^ Write end of message queue of 'Actor'
    , actorAction :: IO result      -- ^ IO action to execute 'Actor'
    }
```

The `ActorQ message` in the `Actor` is the write-end of created `Inbox`.  While
user supplied message handler receives `Inbox`, which is read-end of created
queue, caller of `newActor` gets write-end only.

### Message Queue

`Inbox` is specifically designed queue for implementing actor.  All behaviors
available in this package depend on it.  It provides following capabilities.

* Thread-safe read/pull/receive and write/push/send.
* Blocking and non-blocking read operation.
* Selective read operation.
* Current queue length.
* Bounded queue.

The type `Inbox` is intended to be used only for pulling side as inbox of actor.
Single Inbox object is only readable from single actor.  In order to avoid from
other actors, no Inbox constructor is exposed but instead you can get it only
via `newActor` or `newBoundedActor`.

#### Read an oldest message from `Inbox`

To read a message at the head of message queue, apply `receive` to `Inbox`.  If
one or more message is available, `receive` returns oldest one.  If no message
is available, `receive` blocks until at least one message arrives.  A skeleton
of actor message handler will look like this.

```haskell
myActorHandler :: Inbox YourMessageType -> IO ()
myActorHandler inbox = do
    newMessage <- receive inbox
    doSomethingWith newMessage
    myActorHandler inbox
```

#### Send a message to an actor

To send a message to an actor, call `send` with write-end of the actor's inbox
and the message.

```haskell
    send :: ActorQ message -> message -> IO ()
```

`ActorQ` is write-end of actor's message queue.  `ActorQ` is actually just a
wrapper of `Inbox`.  Its role is hiding read-end API of Inbox.  From outside of
actor, only write-end is exposed via ActorQ.  From inside of actor, both
read-end and write-end are available.  You can read from given inbox directly.
You need to wrap the inbox by Actor when you write to the inbox.

#### Send a message from an actor to itself

When you need to send a message to your inbox, do this.

```haskell
    send (ActorQ yourInbox) message
```

You can convert `Inbox` (read-end) to `ActorQ` (write-end) by wrapping `Inbox`
by `ActorQ` so that you can send a message from an actor to itself.

```haskell
myActorHandler :: Inbox YourMessageType -> IO ()
myActorHandler inbox = do
    newMessage <- receive inbox
    doSomethingWith newMessage

    send (ActorQ inbox) messageToMyself -- Send a message to itself.

    myActorHandler inbox
```

### Actor
Actor is IO action emulating Erlang's actor.  It has a dedicated `Inbox` and
processes incoming messages until reaching end state.

Actor is restartable without replacing message queue.  When actor's IO action
crashed and restarted, the new execution of the IO action continue referring the
same message queue.  Thus, threads sending messages to the actor can continue
using the same write-end of the queue.

`newActor` and `newBoundedActor` create an actor with new Inbox.  It is the only
exposed way to create a new Inbox.  This limitation is intended.  It prevents
any code other than message handler of the actor from reading the inbox.

From perspective of outside of actor, user supplies an IO action with type
`ActorHandler` to `newActor` or `newBoundedActor` then user gets IO action of
created actor and write-end of message queue of the actor, which is `ActorQ`
type value.

From perspective of inside of actor, in other word, from perspective of user
supplied message handler, it has a message queue both read and write side
available.

#### Shared Inbox

You can run created actor multiple time simultaneously with different thread
each.  In such case, each actor instances share single `Inbox`.  This would be
useful to distribute task stream to multiple worker actor instances, however,
keep in mind there is no way to control which message is routed to what actor.

## Monitored IO action

This package provides facility for supervising IO actions.  With types and
functions described in this section, you can run IO action with its own thread
and receive notification on its termination at another thread with reason of
termination.  Functions in this section provides guaranteed supervision of your
thread.

It looks something similar to `UnliftIO.bracket`.  What distinguishes from
bracket is guaranteed work through entire lifetime of thread.

Use `UnliftIO.bracket` when you need guaranteed cleanup of resources acquired
within the same thread.  It works as you expect.  However, installing callback
for thread supervision using bracket (or `UnliftIO.finally` or even low level
`UnliftIO.catch`) within a thread has *NO* guarantee.  There is a little window
where asynchronous exception is thrown after the thread is started but callback
is not yet installed.  We will discuss this later in this section.

Notification is delivered via user supplied callback.  Helper functions
described in this section install your callback to your IO action.  Then the
callback will be called on termination of the IO action.

#### Important:  Callback is called in terminated thread

Callback is called in terminated thread.  You have to use inter-thread
communication in order to notify to another thread.

User supplied callback receives `ExitReason` and `UnliftIO.Concurrent.ThreadId`
so that user can determine witch thread was terminated and why it was
terminated.  In order to receive those parameters, user supplied callback must
have type signature `Monitor`, which is following.

```haskell
ExitReason -> ThreadId -> IO ()
```

Function `watch` installs your callback to your plain IO action then returns
monitored action.

Callback can be nested.  Use `nestWatch` to install another callback to already
monitored action.

Helper functions return IO action with signature `MonitoredAction` instead of
plain `IO ()`.  From here to the end of this section it will be a little
technical deep dive for describing why it has such signature.

The signature of `MonitoredAction` is this.

```haskell
(IO () -> IO ()) -> IO ()
```

It requires an extra function argument.  It is because `MonitoredAction` will be
invoked with `UnliftIO.Concurrent.forkIOWithUnmask`.

In order to ensure callback on termination works in any timing, the callback
must be installed under asynchronous exception masked.  At the same time, in
order to allow killing the tread from another thread, body of IO action must be
executed under asynchronous exception *unmasked*.  In order to satisfy both
conditions, the IO action and callback must be called using
`UnliftIO.Concurrent.forkIOWithUnmask`.  Typically it looks like following.

```haskell
mask_ $ forkIOWithUnmask $ \unmask -> unmask action `finally` callback
```

The extra function parameter in the signature of `MonitoredAction` is used for
accepting the @unmask@ function which is passed by
`UnliftIO.Concurrent.forkIOWithUnmask`.  Functions defined in this section help
installing callback and converting type to fit to
`UnliftIO.Concurrent.forkIOWithUnmask`.


## Child specification - supervisable process

`ChildSpec` is casting mold of child thread IO action which supervisor spawns
and manages.  It is passed to supervisor, then supervisor let it run with its
own thread, monitor it, and restart it if needed.  ChildSpec provides additional
attributes to `MonitoredAction` for controlling restart on thread termination.
That is `Restart`.  `Restart` represents restart type concept came from
Erlang/OTP.  The value of `Restart` defines how restart operation by supervisor
is triggered on termination of the thread.  `ChildSpec` with `Permanent` restart
type triggers restart operation regardless its reason of termination.  It
triggers restarting even by normal exit.  `Transient` triggers restarting only
when the thread is terminated by exception.  `Temporary` never triggers
restarting.

Refer to Erlang/OTP for more detail of restart type concept.

`newMonitoredChildSpec` creates a new `ChildSpec` from a `MonitoredAction` and a
restart type value.  `newChildSpec` is short cut function creating a `ChildSpec`
from a plain IO action and a restart type value.  `addMonitor` adds another
monitor to existing `ChildSpec`.


## Supervisor and underlying behaviors

This package provides supervisor, server, and state machine behavior from
Erlang/OTP with slight modifications.

All behaviors available in this package are defined as `ActorHandler` so that
they can be easily supervised by converting them to actor using `newActor`.

Server behavior is built upon state machine behavior.  Supervisor is built on
top of server behavior.

Details of supervisor and other behaviors are described the next section.

# Behaviors


## Supervisor behavior

WIP

Supervisor behavior provides Erlang/OTP like thread supervision with some
simplification.  




## Server behavior

Server behavior provides synchronous request-response style communication,
a.k.a. ask pattern, with actor.  Server behavior allows user to send a request
to an actor then wait for response form the actor.  This package provides a
framework for implementing such actor.

Server behavior in this package is actually a set of helper functions and type
synonym to help implementing ask pattern over actor.  User need to follow some
of rules described below to utilize those helpers.

### Define ADT type for messages

First, user need to define an algebraic data type for message to the server in
following form.

```haskell
data myServerCommand
    = ReqWithoutResp1
    | ReqWithoutResp2 Arg1
    | ReqWithoutResp3 Arg2 Arg3
    | ReqWithResp1 (ServerCallback Result1)
    | ReqWithResp1 ArgX (ServerCallback Result2)
    | ReqWithResp2 ArgY ArgZ (ServerCallback Result3)
```

The rule is this:

* Define an ADT containing all requests.
* If a request doesn't return response, define a value type for the request as
  usual element of sum type.
* If a request returns a response, put `(ServerCallback ResultType)` at the last
  argument of the constructor for the request where `ResultType` is type of
  returned value.

`ServerCallback` is type synonym of a function type as following.

```haskell
type ServerCallback a = (a -> IO ())
```

So real definition of your `myServerCommand` is:

```haskell
data MyServerCommand
    = ReqWithoutResp1
    | ReqWithoutResp2 Arg1
    | ReqWithoutResp3 Arg2 Arg3
    | ReqWithResp1 (Result1 -> IO ())
    | ReqWithResp2 ArgX (Result2 -> IO ())
    | ReqWithResp3 ArgY ArgZ (Result3 -> IO ())
```

### Define message handler

Next, user need to define an actor handling the message.  In this example, we
will use state machine behavior so that we can focus on core message handling
part.  For simplicity, this example doesn't have internal state and it never
finishes.

Define a state machine message handler handling `myServerCommand`.  

```haskell
myHandler :: () -> MyServerCommand -> IO (Either () ())
myHandler _  ReqWithoutResp1                  = doJob1 $> Right ()
myHandler _ (ReqWithoutResp2 arg1)            = doJob2 arg1 $> Right ()
myHandler _ (ReqWithoutResp3 arg2 arg3)       = doJob3 arg2 arg3 $> Right ()
myHandler _ (ReqWithResp1 cont1)              = (doJob4 >>= cont1) $> Right ()
myHandler _ (ReqWithResp2 argX cont2)         = (doJob5 argX >>= cont2) $> Right ()
myHandler _ (ReqWithResp3 argY argZ cont3)    = (doJob6 argY argZ >>= cont3) $> Right ()
```

The core idea here is implementing request handler in CPS style.  If a request
returns a response, the request message comes with callback function (a.k.a.
continuation).  You can send back response for the request by calling the
callback.

### Requesting to server

Function `call`, `callAsync`, and `callIgnore` are helper functions to implement
request-response communication with server.  They install callback to message,
send the message, returns response to caller.  They receive partially applied
server message constructor, apply it to callback function, then send it to
server.  The installed callback handles response from the server.  You can use
`call` like following.

```haskell
    maybeResult1 <- call def myServerActor ReqWithResp1
    maybeResult2 <- call def myServerActor $ ReqWithResp2 argX
    maybeResult3 <- call def myServerActor $ ReqWithResp3 argY argZ
```

When you send a request without response, use `cast`.

```haskell
    cast myServerActor ReqWithoutResp1
    cast myServerActor $ ReqWithoutResp2 arg1
    cast myServerActor $ ReqWithoutResp3 arg2 arg3
```

When you send a request with response but ignore it, use `callIgnore`.

```haskell
    callIgnore myServerActor ReqWithResp1
    callIgnore myServerActor $ ReqWithResp2 argX
    callIgnore myServerActor $ ReqWithResp3 argY argZ
```

Generally, ask pattern, or synchronous request-response communication is not
recommended in actor model.  It is because synchronous request blocks entire
actor until it receives response or timeout.  You can mitigate the situation by
wrapping the synchronous call with `async`.  Use `callAsync` for such purpose.


## State Machine behavior

State machine behavior is most essential behavior in this package.  It provides
framework for creating IO action of finite state machine running on its own
thread.  State machine has single `Inbox`, its local state, and a user supplied
message handler.  State machine is created with initial state value, waits for
incoming message, passes received message and current state to user supplied
handler, updates state to returned value from user supplied handler, stops or
continue to listen message queue based on what the handler returned.

To create a new state machine, prepare initial state of your state machine and
define your message handler driving your state machine, apply `newStateMachine`
to the initial state and handler.  You will get a `ActorHandler` so you can get
an actor of the state machine by applying `newActor` to it.

```haskell
Actor queue action <-  newActor $ newStateMachine initialState handler
```

Or you can use short-cut helper.

```haskell
Actor queue action <-  newStateMachineActor initialState handler
```

The `newStateMachine` returns write-end of message queue for the state machine
and IO action to run.  You can run the IO action by `Control.Concurrent.forkIO`
or `Control.Concurrent.async`, or you can let supervisor run it.

User supplied message handler must have following type signature.

```haskell
handler :: (state -> message -> IO (Either result state))
```

When a message is sent to state machine's queue, it is automatically received by
state machine framework, then the handler is called with current state and the
message.  The handler must return either result or next state.  When `Left
result` is returned, the state machine stops and returned value of the IO action
is `IO result`.  When `Right state` is returned, the state machine updates
current state with the returned state and wait for next incoming message.


# Design Considerations

## Separate role of threads

When you design thread hierarchy with this package, you have to follow design
rule of Erlang/OTP where only supervisor can have children threads.

In Erlang/OTP, there are two type of Erlang process.

* Supervisor
* Worker

Supervisor has children processes and supervise them.  Worker does real task but
never has child process.

Without this rule, you have to have both supervision functionality and real
task processing functionality within single process.  That leads more complex
implementation of process.

With this rule, worker no longer have to take care of supervising children.  But
at the same time you cannot create child process directly from worker.


## Key Difference from Erlang/OTP Supervisor

* Mutable variables are shared
* Dynamic children are always `Temporary`
* No `shutdown` method to terminate child
* No `RestForOne` strategy
* Every actor has dedicated Haskell thread


### Mutable variables are shared

While "share nothing" is a key concept of Erlang, there is no such guarantee in
this package.  Message passed from one Haskell thread to another thread is
shared between both threads.  This isn't a problem as long as message content is
normal Haskell object.  Normal Haskell object is immutable.  Nobody mutates its
value.  So, in normal Haskell object, sharing is identical to copying.

However, when you pass mutable object like IORef, MVar, or TVar, do it with
care.  Those object can be mutated by other thread.

### Dynamic children are always `Temporary`

Child thread created by `newChild` always created as `Temporary` child
regardless which restart type is designated in its spec.  `Temporary` children
are never been restarted by supervisor.  `Permanent` or `Transient` child must
be a part of `ChildSpec` list given to supervisor spec.

### No `shutdown` method to terminate child

When supervisor terminates its children, supervisor always throw asynchronous
exception to children.  There is no option like `exit(Child, shutdown)` found in
Erlang/OTP.

You must implement appropriate resource cleanup on asynchronous exception.
You can implement graceful shutdown by yourself but it does not arrow you escape
from dealing with asynchronous exception.

### No `RestForOne` strategy

Only `OneForOne` and `OneForAll` restart strategy is supported.

### Every actor has dedicated Haskell thread

Unlike some of other actor implementations, each actor in this package has its
own Haskell thread.  It means every actor has dedicated stack for each.  Thus
calling blocking API in middle of message handling does *NOT* prevent other
actor running.

Some actor implementation give thread and stack to an actor only when it handles
incoming message.  In such implementation, actor has no thread and stack when
it is waiting for next message.  This maximizes scalability.  Even though there
are billions of actors, you only need *n* threads and stacks while you have *n*
core micro processor.

A downside of such implementation is it strictly disallows blocking operation in
middle of message handling.  In such implementation, calling a blocking API in
an actor system running with single thread causes stall of entire actor system
until the blocking API returns.

That doesn't happen in this package.  Though you call any blocking API in middle
of actor message handler, other Haskell threads continue running.

Giving dedicated thread to each actor requires giving dedicated stack frame to
each actor too.  It consumes more memory than the above design.  However, in
Haskell, it won't be a serious problem.  These are the reason why.

* In Haskell, size of stack frame starts from 1KB and grows as needed.
* It can be moved by GC so no continuous address space is required at beginning.

It is one of the greatest characteristic of GHC's runtime.  This package decided
to leverage it.


## Resource management

The word *resource* in this context means object kept in runtime but not
garbage collected.  For example, file handles, network sockets, and threads are
resources.  In Haskell, losing reference to those objects does *NOT* mean those
objects will be closed or terminated.  You have to explicitly close handles and
sockets, terminate threads before you lose reference to them.

This becomes more complex under threaded GHC environment.  Under GHC, thread
can receive asynchronous exception in any timing.  You have to cleanup resources
when your thread received asynchronous exception as well as in case of normal
exit and synchronous exception scenario.

This package does take care of threads managed by supervisor but you have to
take care of any other resources.
