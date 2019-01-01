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
      MessageQueue
    , newMessageQueue
    , newBoundedMessageQueue
    , sendMessage
    , trySendMessage
    , receiveSelect
    , receive
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
    , ServerQueue (..)
    , ServerCallback
    , newServer
    , cast
    , call
    , callAsync
    , callIgnore
    ) where

import           Control.Concurrent.SupervisorInternal
