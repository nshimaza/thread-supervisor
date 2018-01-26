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
    -- * Supervisable IO action
      Restart (..)
    , ExitReason (..)
    , Monitor
    , ProcessSpec
    , newProcessSpec
    , addMonitor
    -- * Supervisor
    , RestartSensitivity (..)
    , Strategy (..)
    , newSupervisor
    , newSimpleOneForOneSupervisor
    , newChild
    -- * State machine
    , MessageQueue (..)
    , newStateMachine
    , sendMessage
    , CallTimeout (..)
    -- * Simple server behavior
    , ServerQueue (..)
    , newServer
    , cast
    , call
    , callAsync
    ) where

import           Control.Concurrent.SupervisorInternal
