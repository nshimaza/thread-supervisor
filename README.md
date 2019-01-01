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
thread, Haskel runtime doesn't consider the thread is orphaned.  The child
thread continue running.

This is prone to create thread leakage.  You can accidentally lose thread ID of
child thread by crash of parent thread.  Now you no longer have way to kill
orphaned child thread.  This is thread leakage.

The low level forkIO API requires you keep track and manage entire thread
lifecycle including accidental case like the above.  Hand crafting it might be
painful.

This package is intended to provide better wrapper API over plain forkIO.  Not
just providing parent-child thread lifecycle management, this package provides
Erlang/TOP like API so that user can leverage well proven practices from
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




# Usage

## Supervisor behavior
TBD

Implement your worker actor as a "process" which can be supervised.

### High level steps to use

1. Create a `MessageQueue` for your actor
1. Create an IO action handling the `MessageQueue`
1. Create a `ProcessSpec` from the IO action
1. Let a supervisor run the `ProcessSpec` in a supervised thread

### Create a static process

Static process is thread automatically forked when supervisor starts.
Following procedure makes your IO action a static process.

1. Create a `ProcessSpec` from your IO action
1. Give the `ProcessSpec` to `newSupervisor`
1. Run generated supervisor

Static processes are automatically forked to each thread when supervisor started
or one-for-all supervisor performed restarting action. When IO action inside of
static process terminated, regardless normal completion or exception, supervisor
takes restart action based on restart restart type of terminated static process.

A supervisor can have any number of static processes.  Static processes must be
given when supervisor is created by `newSupervisor`.

#### Static process example

Following code creates a supervisor with two static processes.

```haskell
createYourSupervisorWithStaticProcess = do
    svQ <- newMessageQueue
    newSupervisor svQ OneForAll def
        [ newProcessSpec [] Permanent yourIOAction1
        , newProcessSpec [] Permanent yourIOAction2
        ]
```

`newSupervisor` returns an `IO ()` IO action.  When the IO action actually
evaluated, it automatically forks two threads.  One is for `yourIOAction1` and
the other is for `yourIOAction2`.  Because restart type of `yourIOAction1` is
`Permanent`, the supervisor always kicks restarting action when one of
`yourIOAction1` or `yourIOAction2` terminated.  When restarting action is
kicked, the supervisor kills remaining thread and restarts all processes again.

### Create a dynamic process

Dynamic process is thread explicitly forked via `newChild` function.
Following procedure runs your IO action as a dynamic process.

1. Run a supervisor
1. Create a `ProcessSpec` from your IO action
1. Request the supervisor to create a dynamic process based on the `ProcessSpec`
   by calling `newChild`

Dynamic processes are explicitly forked to each thread via `newChild` request to
running supervisor.  Supervisor never restarts dynamic process.  It ignores
restart type defined in `ProcessSpec` of dynamic process.

#### Dynamic process example

Following code runs a supervisor in different thread then request it to run a
dynamic process.

```haskell
    -- Assume somewhere in a program
    -- create a supervisor somewhere
    svQ <- newMessageQueue
    newSimpleOneForOneSupervisor svQ
    -- Another place in a program
    -- Assume the supervisor is already running on another thread
    let yourProcessSpec = newProcessSpec [] Temporary yourIOAction
    maybeChildAsync <- newChild def svQ yourProcessSpec
```

## Server behavior

WIP

## State Machine behavior

State machine behavior is most essential behavior in this package.  It provides
framework for creating IO action of finite state machine running on its own
thread.  State machine has single inbound `MessageQueue`, its local state, and
a user supplied message handler.  State machine is created with initial state
value, waits for incoming message, passes received message and current state to
user supplied handler, updates state returned from user supplied handler, stops
or continue to listen message queue based on what the handler returned.

To create a new state machine, prepare initial state of your state machine and
define your message handler driving your state machine, create a `MessageQueue`,
and call `newStateMachine` with the queue, initial state, and handler.

```haskell
    stateMachineQ <- newMessageQueue
    newStateMachine stateMachineQ yourInitialState yourHandler
```

The `newStateMachine` returns IO action which can run under its own thread.
You can pass the IO action to low level `forkIO` or `async` but of course you
can wrap it by newProcessSpec and let it run by Supervisor of this package.

User supplied handler must have following type signature.

```haskell
handler :: (state -> message -> IO (Either result state))
```

A message was sent to given queue, handler is called with current state and
received message.  The handler must return either result or next state.  When
`Left` (or result) is returned, the state machine stops and returned value of
the IO action is `IO result`.  When `Right` (or state) is returned, the state
machine updates current state with the returned state and wait for next incoming
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


### Mutable variables are shared

There is no "share nothing" concept in this package.  Message passed from one
process to another process is shared between both processes.  This isn't a
problem as long as message content is normal Haskell object because normal
Haskell object is immutable so nobody mutate its value.

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


## Resource management

The word *resource* in this context means object kept in runtime but not
garbage collected such like file handles, network sockets, and threads.  In
Haskell, losing reference to those objects do *NOT* mean those objects will be
closed or terminated.  You have to explicitly close handles and sockets,
terminate threads before you lose reference to them.

This becomes more complex under threaded GHC environment.  Under GHC, thread
can receive asynchronous exception in any timing.  You have to cleanup resources
when your thread received asynchronous exception as well as in case of normal
exit and synchronous exception scenario.
