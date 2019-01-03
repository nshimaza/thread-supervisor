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
      -- | 'MessageQueue' is specifically designed queue for implementing all behaviors available in this package.  It provides
      -- following capabilities.
      --
      -- * Thread-safe push (write/send) end.
      -- * Blocking pull (read/receive) operation.
      -- * Selective pull (read) operation with blocking and non-blocking options.
      -- * Current queue length.
      -- * Bounded queue.
      --
      -- Note that it is not a generic thread-safe queue.  Only write-end is thread-safe but read-end is /NOT/ thread-safe.
      -- 'MessageQueue' assumes only one thread reads from a queue.  However, there is no way to prevent multiple threads
      -- read from single queue.  It is user's responsibility to ensure only one thread reads from a queue.
      MessageQueue
    , newMessageQueue
    , newBoundedMessageQueue
    , sendMessage
    , trySendMessage
    , receive
    , tryReceive
    , receiveSelect
    , tryReceiveSelect
    , length
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
