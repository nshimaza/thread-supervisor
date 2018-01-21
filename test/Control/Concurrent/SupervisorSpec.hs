module Control.Concurrent.SupervisorSpec where

import           Control.Concurrent.Async      (withAsync)
import           Control.Concurrent.MVar       (isEmptyMVar, newEmptyMVar,
                                                putMVar, readMVar, takeMVar)
import           Control.Concurrent.STM.TQueue (TQueue, newTQueueIO, readTQueue,
                                                writeTQueue)
import           Control.Monad.STM             (atomically)
import           Data.Default                  (def)
import           Data.Foldable                 (for_)
import           Data.Functor                  (($>))

import           Test.Hspec

import           Control.Concurrent.Supervisor

data ConstServerMessage = AskFst | AskSnd

simpleCountingServer :: ServerQueue Bool Int -> Int -> IO Int
simpleCountingServer q n = newServer q (initializer n) cleanup handler
  where
    initializer     = pure
    cleanup _       = pure ()
    handler s False = pure (s, Left s)
    handler s True  = pure (s, Right (s + 1))

spec :: Spec
spec = do
    describe "State machine behavior" $ do
        it "returns result when event handler returns Left" $ do
            q <- newTQueueIO
            let statem = newStateMachine q () $ \_ _ -> pure $ Left "Hello"
            sendMessage q ()
            r <- statem
            r `shouldBe` "Hello"

        it "consumes message in the queue until exit" $ do
            q <- newTQueueIO
            let until5 _ 5 = pure $ Left "Done"
                until5 _ _ = pure $ Right ()
                statem     = newStateMachine q () until5
            for_ [1..7] $ sendMessage q
            r <- statem
            r `shouldBe` "Done"
            msg <- atomically $ readTQueue q
            msg `shouldBe` 6

        it "passes next state with Right" $ do
            q <- newTQueueIO
            let handler True  _ = pure $ Right False
                handler False _ = pure $ Left "Finished"
                statem          = newStateMachine q True handler
            for_ [(), ()] $ sendMessage q
            r <- statem
            r `shouldBe` "Finished"

        it "runs state machine by consuming messages until handler returns Left" $ do
            q <- newTQueueIO
            let handler n 10 = pure $ Left (n + 10)
                handler n x  = pure $ Right (n + x)
                statem       = newStateMachine q 0 handler
            for_ [1..100] $ sendMessage q
            r <- statem
            r `shouldBe` 55

    describe "Server" $ do
        it "has call method which return value synchronously" $ do
            srvQ <- newTQueueIO
            let initializer         = pure (1, 2)
                cleanup _           = pure ()
                handler s AskFst    = pure (fst s, Right s)
                handler s AskSnd    = pure (snd s, Right s)
                srv                     = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ AskFst
                r1 `shouldBe` Just 1
                r2 <- call def srvQ AskSnd
                r2 `shouldBe` Just 2

        it "keeps its own state and cast changes the state" $ do
            srvQ <- newTQueueIO
            let initializer = pure 0
                cleanup _   = pure ()
                handler s _ = pure (s, Right (s + 1))
                srv         = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call def srvQ ()
                r1 `shouldBe` Just 0
                cast srvQ ()
                r2 <- call def srvQ ()
                r2 `shouldBe` Just 2

        it "keeps its own state and call can change the state" $ do
            srvQ <- newTQueueIO
            withAsync (simpleCountingServer srvQ 0) $ \_ -> do
                r1 <- call def srvQ True
                r1 `shouldBe` Just 0
                r2 <- call def srvQ True
                r2 `shouldBe` Just 1

        it "timeouts call method when server is not responding" $ do
            srvQ <- newTQueueIO
            blocker <- newEmptyMVar
            let initializer = pure ()
                cleanup _   = pure ()
                handler _ _ = takeMVar blocker $> ((), Right ())
                srv             = newServer srvQ initializer cleanup handler
            withAsync srv $ \_ -> do
                r1 <- call (CallTimeout 10000) srvQ ()
                (r1 :: Maybe ()) `shouldBe` Nothing
