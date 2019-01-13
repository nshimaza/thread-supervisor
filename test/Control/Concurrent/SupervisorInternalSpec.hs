module Control.Concurrent.SupervisorInternalSpec where

import           Data.Char                             (chr, ord)
import           Data.Default                          (def)
import           Data.Foldable                         (for_)
import           Data.Functor                          (($>))
import           Data.Maybe                            (fromJust, isJust,
                                                        isNothing)
import           Data.Traversable                      (for)
import           System.Clock                          (TimeSpec (..),
                                                        fromNanoSecs)
import           UnliftIO                              (StringException (..),
                                                        asyncThreadId,
                                                        atomically, cancel,
                                                        fromException,
                                                        newEmptyMVar,
                                                        newTQueueIO, poll,
                                                        putMVar, readMVar,
                                                        readTQueue, takeMVar,
                                                        throwString,
                                                        tryReadTQueue, wait,
                                                        withAsync, writeTQueue)
import           UnliftIO.Concurrent                   (threadDelay)

import           Test.Hspec
import           Test.Hspec.QuickCheck
import           Test.QuickCheck

import           Control.Concurrent.SupervisorInternal hiding (length)
import qualified Control.Concurrent.SupervisorInternal as Sv (length)

{-# ANN module "HLint: ignore Reduce duplication" #-}

instance Eq ExitReason where
    (UncaughtException e) == _  = error "should not compare exception by Eq"
    _ == (UncaughtException e)  = error "should not compare exception by Eq"
    Normal == Normal            = True
    Killed == Killed            = True
    _ == _                      = False

reasonToString :: ExitReason -> String
reasonToString  (UncaughtException e) = toStr $ fromException e
  where toStr (Just (StringException str _)) = str

spec :: Spec
spec = do
    describe "MessageQueue receive" $ do
        prop "receives message in sent order" $ \xs -> do
            q <- newMessageQueue def
            for_ (xs :: [Int]) $ sendMessage $ MessageQueueTail q
            r <- for xs $ const $ receive q
            r `shouldBe` xs

        it "blocks until message available" $ do
            q <- newMessageQueue def
            withAsync (receive q) $ \a -> do
                threadDelay 1000
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                sendMessage (MessageQueueTail q) "Hello"
                r2 <- wait a
                r2 `shouldBe` "Hello"

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 100000)  $ prop "concurrent read and write to the same queue" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            withAsync (for_ xs (sendMessage qtail . Just) *> sendMessage qtail Nothing) $ \_ -> do
                let go ys = do
                        maybeInt <- receive q
                        case maybeInt of
                            Just y  -> go (y:ys)
                            Nothing -> pure $ reverse ys
                rs <- go []
                rs `shouldBe` (xs :: [Int])

    describe "MessageQueue tryReceive" $ do
        prop "receives message in sent order" $ \xs -> do
            q <- newMessageQueue def
            for_ (xs :: [Int]) $ sendMessage $ MessageQueueTail q
            r <- for xs $ const $ tryReceive q
            r `shouldBe` map Just xs

        it "returns Nothing if no message available" $ do
            q <- newMessageQueue def :: IO (MessageQueue ())
            r <- tryReceive q
            r `shouldSatisfy` isNothing

    describe "MessageQueue receiveSelect" $ do
        it "allows selective receive" $ do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q

            for_ ['a'..'z'] $ sendMessage qtail
            r1 <- receiveSelect (== 'a') q
            r1 `shouldBe` 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ sendMessage qtail
            r3 <- receiveSelect (== 'h') q
            r3 `shouldBe` 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` ['a'..'g'] <> ['i'..'z']

            for_ ['a'..'z'] $ sendMessage qtail
            r5 <- receiveSelect (== 'z') q
            r5 `shouldBe` 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ sendMessage qtail
                r7 <- receiveSelect (== chr i) q
                ord r7 `shouldBe` i
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` ['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z']

        it "returns the first element satisfying supplied predicate" $ do
            q <- newMessageQueue def
            for_ "abcdefabcdef" $ sendMessage $ MessageQueueTail q
            r1 <- receiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "blocks until interesting message arrived" $ do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            for_ ['a'..'y'] $ sendMessage qtail
            withAsync (receiveSelect (== 'z') q) $ \a -> do
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                sendMessage qtail 'z'
                r2 <- wait a
                r2 `shouldBe` 'z'

        prop "keeps entire content if predicate was never satisfied" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            for_ (xs :: [Int]) $ sendMessage qtail . Just
            for_ [1..2] $ \_ -> sendMessage qtail Nothing
            let go ys = do
                    maybeInt <- receiveSelect isNothing q
                    case maybeInt of
                        Just y  -> go (y:ys)
                        Nothing -> pure $ reverse ys
            rs <- go []
            rs `shouldBe` []
            remains <- for xs $ const $ fromJust <$> receive q
            remains `shouldBe` xs

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 10000) $ prop "selectively reads massive number of messages concurrently" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            let evens = filter even xs :: [Int]
            withAsync (for_ xs (sendMessage qtail . Just) *> sendMessage qtail Nothing) $ \_ -> do
                let evenOrNothing (Just n) = even n
                    evenOrNothing Nothing  = True
                    go ys = do
                        maybeInt <- receiveSelect evenOrNothing q
                        case maybeInt of
                            Just y  -> go (y:ys)
                            Nothing -> pure $ reverse ys
                rs <- go []
                rs `shouldBe` evens

    describe "MessageQueue tryReceiveSelect" $ do
        it "returns Nothing if no message available" $ do
            q <- newMessageQueue def
            r <- tryReceiveSelect (const True) q
            r `shouldBe` (Nothing :: Maybe Int)

        it "allows selective receive" $ do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q

            for_ ['a'..'z'] $ sendMessage qtail
            r1 <- tryReceiveSelect (== 'a') q
            r1 `shouldBe` Just 'a'
            r2 <- for [1..25] $ const $ receive q
            r2 `shouldBe` ['b'..'z']

            for_ ['a'..'z'] $ sendMessage qtail
            r3 <- tryReceiveSelect (== 'h') q
            r3 `shouldBe` Just 'h'
            r4 <- for [1..25] $ const $ receive q
            r4 `shouldBe` (['a'..'g'] <> ['i'..'z'])

            for_ ['a'..'z'] $ sendMessage qtail
            r5 <- tryReceiveSelect (== 'z') q
            r5 `shouldBe` Just 'z'
            r6 <- for [1..25] $ const $ receive q
            r6 `shouldBe` ['a'..'y']

            for_ [ord 'b' .. ord 'y'] $ \i -> do
                for_ ['a'..'z'] $ sendMessage qtail
                r7 <- tryReceiveSelect (== chr i) q
                r7 `shouldBe` Just (chr i)
                r8 <- for [1..25] $ const $ receive q
                r8 `shouldBe` (['a' .. chr (i - 1)] <> [chr (i + 1) .. 'z'])

        it "returns the first element satisfying supplied predicate" $ do
            q <- newMessageQueue def
            for_ "abcdefabcdef" $ sendMessage $ MessageQueueTail q
            r1 <- tryReceiveSelect (\c -> c == 'c' || c == 'd' || c == 'e') q
            r1 `shouldBe` Just 'c'
            r2 <- for [1..11] $ const $ receive q
            r2 `shouldBe` "abdefabcdef"

        it "return Nothing when there is no interesting message in the queue" $ do
            q <- newMessageQueue def
            for_ ['a'..'y'] $ sendMessage $ MessageQueueTail q
            r <- tryReceiveSelect (== 'z') q
            r `shouldBe` Nothing

        prop "keeps entire content if predicate was never satisfied" $ \xs -> do
            q <- newMessageQueue def
            for_ xs $ sendMessage $ MessageQueueTail q
            rs <- for xs $ const $ tryReceiveSelect (const False) q
            rs `shouldBe` map (const Nothing) xs
            remains <- for xs $ const $ receive q
            remains `shouldBe` (xs :: [Int])

        modifyMaxSuccess (const 10) $ modifyMaxSize (const 10000) $ prop "try selectively reads massive number of messages concurrently" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            let evens = filter even xs :: [Int]
            withAsync (for_ xs (sendMessage qtail . Right) *> sendMessage qtail (Left ())) $ \_ -> do
                let evenOrLeft (Right n) = even n
                    evenOrLeft (Left _)  = True
                    go ys = do
                        maybeEither <- tryReceiveSelect evenOrLeft q
                        case maybeEither of
                            Just e  -> case e of
                                Right y -> go (y:ys)
                                Left _  -> pure $ reverse ys
                            Nothing -> go ys
                rs <- go []
                rs `shouldBe` evens

    describe "MessageQueue length" $ do
        prop "returns number of queued messages" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            for_ (xs :: [Int]) $ sendMessage qtail
            qLen <- Sv.length qtail
            qLen `shouldBe` (fromIntegral . length) xs

        prop "returns number of remaining messages" $ \(xs, ys)  -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            for_ (xs <> ys :: [Int]) $ sendMessage qtail
            for_ xs $ const $ receive q
            qLen <- Sv.length qtail
            qLen `shouldBe` (fromIntegral . length) ys

        prop "remains unchanged after failing selective receives" $ \xs -> do
            q <- newMessageQueue def
            let qtail = MessageQueueTail q
            for_ (xs :: [Int]) $ sendMessage qtail
            qLenBefore <- Sv.length qtail
            for_ xs $ const $ tryReceiveSelect (const False) q
            qLenAfter <- Sv.length qtail
            qLenBefore `shouldBe` qLenAfter

    describe "Bounded MessageQueue" $ do
        prop "sendMessage blocks when the queue is full" $ \xs -> do
            let ys = 0:xs :: [Int]
            q <- newMessageQueue $ MessageQueueLength (fromIntegral $ length ys)
            let qtail = MessageQueueTail q
            marker <- newEmptyMVar
            let sender = do
                    for_ ys $ sendMessage qtail
                    putMVar marker ()
                    sendMessage qtail 0
            withAsync sender $ \a -> do
                takeMVar marker
                threadDelay 1000
                r1 <- poll a
                r1 `shouldSatisfy` isNothing
                receive q
                r2 <- wait a
                r2 `shouldBe` ()

        prop "trySendMessage returns Nothing when the queue is full" $ \xs -> do
            q <- newMessageQueue $ MessageQueueLength (fromIntegral $ length (xs :: [Int]))
            let qtail = MessageQueueTail q
            for_ xs $ trySendMessage qtail
            r <- trySendMessage qtail 0
            r `shouldBe` Nothing

        prop "readling from queue makes room again" $ \xs -> do
            let ys = 0:xs :: [Int]
            q <- newMessageQueue $ MessageQueueLength (fromIntegral $ length ys)
            let qtail = MessageQueueTail q
            for_ ys $ trySendMessage qtail
            r1 <- trySendMessage qtail 0
            r1 `shouldBe` Nothing
            receive q
            r2 <- trySendMessage qtail 1
            r2 `shouldBe` Just ()

    describe "Process" $ do
        it "reports exit code Normal on normal exit" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar trigger $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            report <- atomically $ readTQueue sv
            report `shouldBe` (Normal, asyncThreadId a)

        it "reports exit code UncaughtException on synchronous exception which wasn't caught" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            (reason, tid) <- atomically $ readTQueue sv
            tid `shouldBe` asyncThreadId a
            reasonToString reason `shouldBe` "oops"

        it "reports exit code Killed when it received asynchronous exception" $ do
            blocker <- newEmptyMVar
            pmap <- newProcessMap
            sv <- newTQueueIO
            let monitor reason tid  = atomically $ writeTQueue sv (reason, tid)
                process             = newProcessSpec [monitor] Temporary $ readMVar blocker $> ()
            a <- newProcess pmap process
            noReport <- atomically $ tryReadTQueue sv
            noReport `shouldSatisfy` isNothing
            cancel a
            report <- atomically $ readTQueue sv
            report `shouldBe` (Killed, asyncThreadId a)

        it "can notify its normal exit to multiple monitors" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar trigger $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Normal, asyncThreadId a)

        it "can notify its exit by uncaught exception to multiple monitors" $ do
            trigger <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar trigger *> throwString "oops" $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            putMVar trigger ()
            for_ svs $ \sv -> do
                (reason, tid) <- atomically $ readTQueue sv
                tid `shouldBe` asyncThreadId a
                reasonToString reason `shouldBe` "oops"

        it "can notify its exit by asynchronous exception to multiple monitors" $ do
            blocker <- newEmptyMVar
            pmap <- newProcessMap
            svs <- for [1..10] $ const newTQueueIO
            let mons    = (\sv reason tid -> atomically $ writeTQueue sv (reason, tid)) <$> svs
                process = newProcessSpec mons Temporary $ readMVar blocker $> ()
            a <- newProcess pmap process
            for_ svs $ \sv -> do
                noReport <- atomically $ tryReadTQueue sv
                noReport `shouldSatisfy` isNothing
            cancel a
            for_ svs $ \sv -> do
                report <- atomically $ readTQueue sv
                report `shouldBe` (Killed, asyncThreadId a)
