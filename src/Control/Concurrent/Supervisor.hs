module Control.Concurrent.Supervisor
    (
      MessageQueue (..)
    , makeStateMachine
    , sendMessage
    )where

import           Control.Concurrent.SupervisorInternal
