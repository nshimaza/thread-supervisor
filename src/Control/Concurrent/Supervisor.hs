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
    -- * Supervisable thread
      Restart (..)
    , ExitReason (..)
    , Monitor
    , ProcessSpec
    , newProcessSpec
    , addMonitor
    -- * Supervisor
    , MessageQueue (..)
    , newStateMachine
    , sendMessage
    , CallTimeout (..)
    , ServerQueue (..)
    , newServer
    , cast
    , call
    , callAsync
    , RestartSensitivity (..)
    , Strategy (..)
    , newSupervisor
    , newSimpleOneForOneSupervisor
    , newChild
    ) where

import           Control.Concurrent.SupervisorInternal
