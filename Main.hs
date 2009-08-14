{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
module Main where

import Happstack.State
import Happstack.Server hiding (Host)
import Data.Typeable
import Control.Monad.State (put, get, modify)
import Control.Monad.Reader
import Control.Concurrent
import Data.Monoid
import Data.Generics
import qualified Data.Map as Map

type Host = String
type TestName = String
type Revision = String
type Duration = Float
type Measurement = (Host, TestName, Revision, Duration)

duration :: Measurement -> Duration
duration (_,_,_,d) = d

instance FromData Measurement where
    fromData = do
        test <- look "test"
        duration <- lookRead "duration"
        host <- look "host"
        revision <- look "revision"
        return (host, test, revision, duration)

type Measurements = Map.Map (Host, TestName) (Duration, [(Revision, Duration, Bool)])

data State = State {measurements :: Measurements} deriving (Typeable)
instance Version State
$(deriveSerialize ''State)

instance Component State where 
    type Dependencies State = End
    initialValue = State $ Map.fromList []

addMeasurement :: Measurement -> Update State Bool
addMeasurement (host, tname, rev, duration) = do
    State measurements <- get
    let newmap = upd measurements
    put . State $ newmap
    let (_,_,res) = head.snd $ newmap Map.! (host, tname)
    return res
    where upd = Map.insertWith upd' (host, tname) (duration, [(rev, duration, True)])
          upd' _ (mdur, ms) = (min mdur duration, (rev, duration, duration <= mdur * 1.05):ms)

getMeasurements :: Query State Measurements
getMeasurements = fmap measurements ask

$(mkMethods ''State ['addMeasurement, 'getMeasurements])

report :: ServerPart String
report = do
    Just measurement <- getData
    res <- update (AddMeasurement measurement)
    return $ if res
                then "PASS"
                else "FAIL"
    
listMeasurements :: ServerPart String
listMeasurements = do
    measurements <- query (GetMeasurements)
    return . foldr g "" $ Map.toList measurements
    where g ((host, test), val) = ss host . ss " " . ss test . ss "\n" . shows val . ss "\n\n"
          ss = showString


displayDetails :: String -> String -> ServerPart String
displayDetails hostName testName = do
    allMeasurements <- query (GetMeasurements)
    let measurements = allMeasurements Map.! (hostName, testName)
    return $ show measurements


entryPoint :: Proxy State
entryPoint = Proxy

controller = dir "report" report  
    `mappend`  (nullDir >> listMeasurements) 
    `mappend`  (dir "details" $ path (\hostName -> path (\testName -> displayDetails hostName testName)))


main = do 
    control <- startSystemState entryPoint
    tid <- forkIO $ simpleHTTP nullConf $ controller
    putStrLn "listening on port 8000"
    waitForTermination
    killThread tid
    createCheckpoint control
    shutdownSystem control

