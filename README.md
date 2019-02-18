# async-supervisor

[![License: MIT](https://img.shields.io/badge/License-MIT-brightgreen.svg)](https://opensource.org/licenses/MIT)
[![Build Status](https://travis-ci.org/nshimaza/async-supervisor.svg?branch=master)](https://travis-ci.org/nshimaza/async-supervisor)

A simplified implementation of Erlang/OTP like supervisor over async.

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
* `async-supervisor`: Implementing server where unknown number of independent
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

In other words, the difference between `withAsync` and `async-supervisor` is
strategy of installing / un-installing cleanup handler.  `withAsync` installs
cleanup handler on stack so it uninstalls handler based on its lexical scope.
`async-supervisor` installs cleanup handler surrounding user supplied action so
it uninstalls handlers at actual dynamic thread termination.



# Quick Start

## High level steps to use

1. Create a `MonitoredAction` from your IO action
1. Create a `ProcessSpec` from the `MonitoredAction`
1. Let a supervisor run the `ProcessSpec` in a supervised thread

Detail will be different whether you create static process or dynamic process.

## Create a static process

Static process is thread automatically forked when supervisor starts.
Following procedure makes your IO action a static process.

1. Create a `MonitoredAction` from your IO action
1. Create a `ProcessSpec` from the `MonitoredAction`
1. Give the `ProcessSpec` to `newSupervisor`
1. Run generated supervisor

Static processes are automatically forked to each thread when supervisor started
or one-for-all supervisor performed restarting action. When IO action inside of
static process terminated, regardless normal completion or exception, supervisor
takes restart action based on restart type of terminated static process.

A supervisor can have any number of static processes.  Static processes must be
given when supervisor is created by `newSupervisor`.

## Static process example

Following code creates a supervisor actor with two static processes and run it
in new thread.

```haskell
runYourSupervisorWithStaticProcess = do
    (svQ, svAction) <- newActor . newSupervisor $ OneForAll def
        [ newProcessSpec Permanent $ noWatch yourIOAction1
        , newProcessSpec Permanent $ noWatch yourIOAction2
        ]
    async svAction
```

The idiom `newActor . newSupervisor` returns `(svQ, svAction)` where `svQ` is
write-end of message queue for the supervisor actor, which we don't use here,
and `svAction` is body IO action of the supervisor.  When the `svAction` is
actually evaluated, it automatically forks two threads.  One is for
`yourIOAction1` and the other is for `yourIOAction2`.  Because restart type of
given static processes are both `Permanent`, the supervisor always kicks
restarting action when one of `yourIOAction1` or `yourIOAction2` is terminated.
When restarting action is kicked, the supervisor kills remaining thread and
restarts all processes again because its restarting strategy is one-for-all.

When the supervisor is terminated, both `yourIOAction1` and `yourIOAction2` are
automatically killed by the supervisor.  To kill the supervisor, apply `cancel`
to the async object returned by `async svAction`.

## Create a dynamic process

Dynamic process is thread explicitly forked via `newChild` function.
Following procedure runs your IO action as a dynamic process.

1. Run a supervisor
1. Create a `ProcessSpec` from your IO action
1. Request the supervisor to create a dynamic process based on the `ProcessSpec`
   by calling `newChild`

Dynamic processes are explicitly forked to each thread via `newChild` request to
running supervisor.  Supervisor never restarts dynamic process.  It ignores
restart type defined in `ProcessSpec` of dynamic process.

## Dynamic process example

Following code runs a supervisor in different thread then request it to run a
dynamic process.

```haskell
    -- Run supervisor in another thread
    (svQ, svAction) <- newActor $ newSimpleOneForOneSupervisor
    asyncSv <- async svAction
    -- Request to run your process under the supervisor
    let yourProcessSpec = newProcessSpec Temporary $ noWatch yourIOAction
    maybeChildAsync <- newChild def svQ yourProcessSpec
```

The idiom `newActor $ newSimpleOneForOneSupervisor` returns `(svQ, svAction)`
where `svQ` is write-end of message queue for the supervisor actor and
`svAction` is body IO action of the supervisor.  When the `svAction` is actually
evaluated, it listens `svQ` and wait for request to run dynamic process.

When `newChild` is called with `svQ`, it sends request to the supervisor to run
a dynamic process with given `ProcessSpec`.

When the supervisor is terminated, requested processes are automatically
killed by the supervisor if they are still running.

To kill the supervisor, apply `cancel` to `asyncSv`.



# Building Blocks

This package consists of following building blocks.

* Actor and Message queue
* Monitored IO action and supervisable process
* Supervisor and underlying behaviors

Actor and message queue is lowest layer block of this package.  Behaviors are
built upon this block.  It is exposed to user so that you can use it for
implementing actor style concurrent program.

Monitored IO action is the heart of this package.  Most sensitive part for
dealing with asynchronous exception is implemented here.  Monitored IO action
provides guaranteed notification on thread termination so that supervisor can
provide guaranteed supervision on threads.

Lastly supervisor and underlying behaviors implement simplified Erlang/OTP
behaviors so that user can leverage best practice of concurrent programming
from Erlang/OTP.

## Actor and Message queue

Actor is restartable IO action with inbound message queue.  Actor is designed
to allow supervisor restart the actor while other threads sending messages to
the actor keep using the same write-end of the queue before and after restart.
Actor consists of message queue and its handler.  `Inbox` is a message queue
designed for actor's message inbox.  It is thread-safe, bounded or unbounded,
and selectively readable queue.

To protect read-end of the queue, it has different type for read-end and
write-end.  Message handler of actor can access to both end but only write-end
is accessible from outside of message handler.  To realize this, constructor of
`Inbox` is not exposed.  The only way to create a new `Inbox` object is creating
a new actor using `newActor` function.

```haskell
newActor :: (Inbox a -> IO b) -> IO (Actor a, IO b)
```

This package provides type synonym for message handler as below.

```haskell
type ActorHandler a b = (Inbox a -> IO b)
```

`newActor` receives an user supplied message handler, creates a new `Inbox`
value, then returns write-end of actor's message queue and IO action of the
actor's body.  The `Actor a` in the returned value is the write-end of created
`Inbox`.  While user supplied message handler receives `Inbox`, which is
read-end of created queue, caller of `newActor` gets write-end only.

### Read an oldest message from `Inbox`

To read a message at the head of message queue, apply `receive` to `Inbox`.
If one or more message is available, `receive` returns oldest one.  If no
message is available, `receive` blocks until at least one message arrives.
A skeleton of actor message handler will look like this.

```haskell
myActorHandler :: Inbox YourMessageType -> IO ()
myActorHandler inbox = do
    newMessage <- receive inbox
    doSomethingWith newMessage
    myActorHandler inbox
```

### Send a message to an actor

To send a message to an actor, call `send` with write-end of the actor's inbox
and the message.

```haskell
send :: Actor a -> a -> IO ()
```

`Actor` is write-end of actor's message queue.

#### Send a message from an actor to itself

You can convert `Inbox` (read-end) to `Actor` (write-end) by wrapping `Inbox` by
`Actor` so that you can send a message from an actor to itself.

```haskell
myActorHandler :: Inbox YourMessageType -> IO ()
myActorHandler inbox = do
    newMessage <- receive inbox
    doSomethingWith newMessage

    send (Actor inbox) messageToMyself

    myActorHandler inbox
```

### How Actor works

Actor is IO action which is restartable without replacing message queue.  When
actor's IO action crashed and restarted, the new calculation of the IO action
continue referring the same message queue.  Thus, threads sending messages to
the actor can continue using the same write-end of the queue.


## Monitored IO action and supervisable process



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

Server behavior provides ask pattern, or synchronous request-response style
communication with actor.  Server behavior allows user to send a request to an
actor then wait for response form the actor.  This package provides a framework
for implementing such actor.

Server behavior in this package is actually a set of helper functions and type
synonym to help implementing ask pattern over actor.  User need to follow some
of rules described below to utilize those helpers.

### Definition of message to server

First, user need to define a data type for message of user's server in following
form.

```haskell
data myServerCommand
    = RequestWithoutResponse1
    | RequestWithoutResponse2 Arg1
    | RequestWithoutResponse3 Arg2 Arg3
    | RequestWithResponse1 (ServerCallback Result1)
    | RequestWithResponse1 ArgX (ServerCallback Result2)
    | RequestWithResponse2 ArgY ArgZ (ServerCallback Result3)
```

Define an ADT containing all requests.  If a request doesn't return response,
define a value type for the request as usual element of sum type.  If a request
returns response, put `(ServerCallback ResultType)` at the last argument of the
constructor for the request where `ResultType` is type of returned value.

`ServerCallback` is type synonym of a function type as following.

```haskell
type ServerCallback a = (a -> IO ())
```

So real definition of your `myServerCommand` is:

```haskell
data MyServerCommand
    = RequestWithoutResponse1
    | RequestWithoutResponse2 Arg1
    | RequestWithoutResponse3 Arg2 Arg3
    | RequestWithResponse1 (Result1 -> IO ())
    | RequestWithResponse2 ArgX (Result2 -> IO ())
    | RequestWithResponse3 ArgY ArgZ (Result3 -> IO ())
```

### Message handler

Next, user need to define an actor handling the message.  In this example, we
will use state machine behavior so that we can focus on core message handling
part.  For simplicity, this example doesn't have internal state and it never
finishes.

Define a state machine message handler handling `myServerCommand`.  

```haskell
myServerHandler :: () -> MyServerCommand -> IO (Either () ())
myServerHandler _  RequestWithoutResponse1                  = doSomething1 $> Right ()
myServerHandler _ (RequestWithoutResponse2 arg1)            = doSomething2 arg1 $> Right ()
myServerHandler _ (RequestWithoutResponse3 arg2 arg3)       = doSomething3 arg2 arg3 $> Right ()
myServerHandler _ (RequestWithResponse1 cont1)              = (doSomething4 >>= cont1) $> Right ()
myServerHandler _ (RequestWithResponse2 argX cont2)         = (doSomething5 argX >>= cont2) $> Right ()
myServerHandler _ (RequestWithResponse3 argY argZ cont3)    = (doSomething6 argY argZ >>= cont3) $> Right ()
```

The core idea here is implementing request handler in CPS style.  If a request
returns a response, the request message comes with callback function (a.k.a.
continuation).  You can send back response for the request by calling the
callback.

### Requesting to server

Function `call`, `callAsync`, and `callIgnore` are helper functions to
implement request-response communication with server.  They install callback to
message, send the message, returns response to caller.  They receive partially
applied server message constructor, apply it to callback function, then send it
to server.  The installed callback handles response from the server.  You can
use `call` like following.

```haskell
    maybeResult1 <- call def myServerActor RequestWithResponse1
    maybeResult2 <- call def myServerActor $ RequestWithResponse2 argX
    maybeResult3 <- call def myServerActor $ RequestWithResponse3 argY argZ
```

When you send a request without response, use `cast`.

```haskell
    cast myServerActor RequestWithWithoutResponse1
    cast myServerActor $ RequestWithWithoutResponse1 arg1
    cast myServerActor $ RequestWithWithoutResponse1 arg2 arg3
```

When you send a request with response but ignore it, use `callIgnore`.

```haskell
    callIgnore myServerActor RequestWithResponse1
    callIgnore myServerActor $ RequestWithResponse2 argX
    callIgnore myServerActor $ RequestWithResponse3 argY argZ
```

Generally, ask pattern, or synchronous request-response communication is not
recommended in actor model.  It is because synchronous request blocks entire
actor until it receives response or timeout.  You can mitigate the situation
by wrapping the synchronous call with `async`.  Use `callAsync` for such
purpose.


## State Machine behavior

State machine behavior is most essential behavior in this package.  It provides
framework for creating IO action of finite state machine running on its own
thread.  State machine has single `Inbox`, its local state, and a user supplied
message handler.  State machine is created with initial state value, waits for
incoming message, passes received message and current state to user supplied
handler, updates state returned from user supplied handler, stops or continue to
listen message queue based on what the handler returned.

To create a new state machine, prepare initial state of your state machine and
define your message handler driving your state machine, apply `newStateMachine`
to the initial state and handler.  You will get a `ActorHandler` so you can
get an actor of the state machine by applying `newActor` to it.

```haskell
    (queue, action) <-  newActor $ newStateMachine yourInitialState yourHandler
```

The `newStateMachine` returns write-end of message queue for the state machine
and IO action to run.  You can run the IO action by `forkIO` or `async`, or you
can let supervisor run it.

```haskell
handler :: (state -> message -> IO (Either result state))
```

When a message is sent to state machine's queue, it is automatically received
by state machine framework, then the handler is called with current state and
the message.  The handler must eturn either result or next state.  When `Left`
(or result) is returned, the state machine stops and returned value of the IO
action is `IO result`.  When `Right` (or state) is returned, the state machine
updates current state with the returned state and wait for next incoming
message.


# Design Considerations

## Separate role of threads

When you design thread hierarchy with this package, you have to follow design
rule of Erlang/OTP where only supervisor can have child processes.

In Erlang/OTP, there are two type of process.

* Supervisor
* Worker

Supervisor has child processes and supervise them.  Worker does real task but
never has child process.

Without this rule, you have to have both supervision functionality and real
task processing functionality within single process.  That leads more complex
implementation of process.

With this rule, worker no longer have to take care of supervising children.
But at the same time you cannot create child process directly from worker.


## Key Difference from Erlang/OTP Supervisor

* Mutable variables are shared
* Dynamic processes are always `Temporary` processes
* No `shutdown` method to terminate child
* No `RestForOne` strategy
* Every actor has dedicated Haskell thread


### Mutable variables are shared

There is no "share nothing" concept in this package.  Message passed from one
process to another process is shared between both processes.  This isn't a
problem as long as message content is normal Haskell object.  Normal Haskell
object is immutable.  Nobody mutates its value.  So, in normal Haskell object,
sharing is identical to copying.

However, when you pass mutable object like IORef, MVar, or TVar, do it with
care.  Those object can be mutated by other process.

### Dynamic processes are always `Temporary` processes

Process created by `newChild` always created as `Temporary` process regardless
which restart type is designated in its spec.  `Temporary` processes are never
been restarted by supervisor.  `Permanent` or `Transient` process must be a part
of process list given to supervisor spec.

### No `shutdown` method to terminate child

When supervisor terminates its children, supervisor always throw asynchronous
exception to children.  There is no option like `exit(Child, shutdown)` in
Erlang/OTP.

You must implement appropriate resource cleanup on asynchronous exception.
You can implement graceful shutdown by yourself but it does not arrow you escape
from dealing with asynchronous exception.

### No `RestForOne` strategy

Only `OneForOne` and `OneForAll` restart strategy is supported.

### Every actor has dedicated Haskell thread

Unlike some of other actor implementations, each actor in this package has its
own Haskell thread.  It means every actor has dedicated stack for each.  Thus
calling blocking API in middle of message handling does *NOT* prevents other
actor running.

Some actor implementation give thread and stack to an actor only when it handles
incoming message.  In such implementation, actor has no thread and stack when
it is waiting for next message.  This maximizes scalability.  Even though there
are billions of actors, you only need *n* threads and stacks while you have *n*
core processor.

Downside of such implementation is it strictly disallows blocking operation in
middle of message handling.  In such implementation, calling blocking API in
single threaded actor system causes entire actor system stalls until the
blocking API returns.

That doesn't happen in this package.  Though you call any blocking API in middle
of actor message handler, other Haskell threads continue running.

Giving dedicated thread to each actor requires giving dedicated stack frame to
each actor too.  It consumes more memory than the above design.  However, in
Haskell it won't be a serious problem.  These are the reason why.

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
