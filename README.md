# async-supervisor

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

This package is intended to provide better replacement API over plain forkIO.
Not just providing parent-child thread lifecycle management, this package
provides Erlang/TOP like API so that user can leverage well proven practices
from Erlang/OTP.

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




# Design Consideration

When you design thread hierarchy, you have to follow design rule of Erlang/OTP
where only supervisor can have child process.

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
