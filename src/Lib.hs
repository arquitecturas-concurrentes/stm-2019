module Lib where

import Control.Concurrent.STM
import Debug.Trace
import Data.Semigroup
import Control.Concurrent
import Control.Monad
import GHC.IO.Unsafe
import System.Random

-- helpers para random

randomInt :: (Int, Int) -> IO Int
randomInt = getStdRandom . randomR

randomSleep :: Float -> IO ()
randomSleep maxSegundos = do
    n <- getStdRandom (randomR (0.0, maxSegundos))
    threadDelay $ round (n * 1000000)

-- helpers para correr async

doAsync :: IO () -> IO ()
doAsync action = forkIO action >> pure ()

doAsyncTimes :: Int -> IO () -> IO ()
doAsyncTimes times action = stimes times $ doAsync action

doAsyncTimesWithIndex :: Int -> (Int -> IO ()) -> IO ()
doAsyncTimesWithIndex times action = forM_ [1..times] $ \x -> doAsync (action x)

-- helpers de retry
retryWithMessageIf :: Bool -> String -> STM ()
retryWithMessageIf condition message = if condition then trace message retry
                                                    else pure ()

-- logging

x `logging` message = trace message x

-- operaciones sobre las colas

pop :: [a] -> (a, [a])
pop (x:xs) = (x, xs)

push :: a -> [a] -> [a]
push x xs = x:xs

isEmpty :: [a] -> Bool
isEmpty = null

hasElements :: [a] -> Bool
hasElements = not . isEmpty

isFull :: [a] -> Bool
isFull = (>= 5) . length

hasSpace :: [a] -> Bool
hasSpace = not . isFull

sacarDe :: TVar [Int] -> IO Int
sacarDe queueRef = atomically $ do
    queue <- readTVar queueRef
    
    retryWithMessageIf (isEmpty queue) (show queue <> " - Queue was empty :(")
    
    let (popped, rest) = pop queue

    writeTVar queueRef rest
        `logging` (show rest <> " - removed " <> show popped)

    return popped

ponerEn :: Int -> TVar [Int] -> IO ()
ponerEn valor queueRef = atomically $ do
    queue <- readTVar queueRef

    retryWithMessageIf (isFull queue) (show queue <> " - Queue was full :(, waiting to add " <> show valor)

    let resultingQueue = push valor queue

    writeTVar queueRef resultingQueue
        `logging` (show resultingQueue <> " - added " <> show valor)

-- como convencion, tomamos que la queue esta llena si tiene 5 elementos

pushYPopConcurrentemente :: IO ()
pushYPopConcurrentemente = do
    queueRef <- newTVarIO []

    doAsyncTimesWithIndex 20 $ \i -> do
        randomSleep 3
        ponerEn i queueRef

    doAsyncTimes 20 $ do
        randomSleep 15
        sacarDe queueRef
        pure ()

-- Como ponerEn y sacarDe son atomicas, y bloquean cuando no pueden poner/sacar de la cola,
-- no hay condicion de carrera

-- Cosas interesantes a notar:
-- El retry solo se hace una vez por thread, no es que el thread reintenta infinitas veces, si no
-- que se bloquea y sabe cuando despertarse (que es cuando cambia la variable que leyó).
-- Por eso es que cada vez que se ve un ' - added x' después aparecen muchos
-- 'Queue was full :(', son todos los threads despertandose y luego bloqueandose porque otro thread
-- los primereó.



-- Pero, que pasa si queremos combinarlas, y sacar lo que hay en una cola para ponerla en otra?

popYPushEnOtraColaConcurrentemente :: IO ()
popYPushEnOtraColaConcurrentemente = do
    queueRef <- newTVarIO [1..20]
    otraQueueRef <- newTVarIO []

    doAsyncTimes 20 $ do
        randomSleep 5
        x <- sacarDe queueRef
        ponerEn x otraQueueRef

-- A pesar de que sacarDe y ponerEn funcionaban por si solas, no son combinables, que es el problema
-- con los locks. En este caso, voy a poder sacar de la primer queue hasta que quede vacía pero
-- va a fallar cuando trato de poner elementos en la segunda cola una vez que se llenó.


-- ¿cual es el problema? que estamos usando IO, no STM, sacarDe y ponerEn son IO y no STM, por lo
-- tanto su atomicidad solo abarca hasta donde termina cada una de ellas.
-- Si cambiamos el tipo a STM y las componemos, el retry afecta a la operacion completa
-- ^ese cambio sería el que mostraría en clase