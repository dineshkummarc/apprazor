{-# LANGUAGE TypeFamilies, DeriveDataTypeable, TemplateHaskell,
             MultiParamTypeClasses, FlexibleContexts,
             FlexibleInstances, TypeSynonymInstances #-}
module Main where

import Happstack.State
import Happstack.Server hiding (Host)
import Data.Typeable
import Control.Arrow
import Control.Concurrent
import Control.Monad.State (put, get, modify)
import Control.Monad.Reader
import Data.Monoid
import Data.Maybe
import Data.Generics
import System.Environment
import qualified Data.Map as Map
import Text.JSON
import Data.List

type Host = String
type TestName = String
type Revision = String
type Duration = Float
type Measurement = (Host, TestName, Revision, Duration)
type Margin = Float
defaultMargin = 0.125

duration :: Measurement -> Duration
duration (_,_,_,d) = d

instance FromData Measurement where
    fromData = do
        test <- look "test"
        duration <- lookRead "duration"
        host <- look "host"
        revision <- look "revision"
        return (host, test, revision, duration)

type Measurements0 = Map.Map (Host, TestName) (Duration, [(Revision, Duration, Bool)])
type Measurements = Map.Map (Host, TestName) (Duration, Margin, [(Revision, Duration, Bool)])

data State0 = State0 Measurements0 deriving (Typeable)
data State = State {measurements :: Measurements} deriving (Typeable)
instance Version State0
$(deriveSerialize ''State0)
instance Version State where
    mode = extension 1 (Proxy :: Proxy State0)
$(deriveSerialize ''State)

instance Migrate State0 State where
    migrate (State0 ms) = State (Map.map (\(x, y) -> (x, defaultMargin, y)) ms)

instance Component State where
    type Dependencies State = End
    initialValue = State $ Map.fromList []

addMeasurement :: Measurement -> Float -> Update State (Bool, Float)
addMeasurement (host, tname, rev, duration) margin = do
    State measurements <- get
    let newmap = upd measurements
    put . State $ newmap
    let (best,  _, (_, _, res):_) = newmap Map.! (host, tname)
    return (res, best)
    where upd = Map.insertWith upd' (host, tname) (duration, margin, [(rev, duration, True)])
          upd' _ (mdur, _, ms) = (min mdur duration, margin, (rev, duration, duration <= mdur * (1.0+margin)):ms)


deleteResult :: Measurement -> Update State ()
deleteResult (host, test, revision, dur) = do
    State measurements <- get
    put $ State $ Map.adjust g (host, test) measurements
    where g (best, margin, ms) = let newMs = filter (not.toDelete) ms in (bestResult newMs, margin, newMs)
          toDelete (r, d, _) = r == revision && d == dur
          bestResult = foldl' min 99999999.0 . map duration
          duration (_, d, _) = d


getMeasurements :: Query State Measurements
getMeasurements = fmap measurements ask

$(mkMethods ''State ['addMeasurement, 'getMeasurements, 'deleteResult])

reportMeasurement :: TestName -> Host -> ServerPart Response
reportMeasurement test host = do
    Just revision <- getDataFn $ look "revision"
    Just duration <- getDataFn $ lookRead "duration"
    maybeMargin <- getDataFn $ lookRead "margin"
    let margin = fromMaybe defaultMargin maybeMargin
    (res, best) <- update (AddMeasurement (host, test, revision, duration) margin)
    return . toResponse $ if res
                then "PASS"
                else "FAIL\n" ++ show best

listMeasurements :: ServerPart Response
listMeasurements = do
    measurements <- query (GetMeasurements)
    return . toResponse . foldr g "" $ Map.toList measurements
    where g ((host, test), val) = ss host . ss " " . ss test . ss "\n" . shows val . ss "\n\n"
          ss = showString

tests :: ServerPart Response
tests = do
    measurements <- query (GetMeasurements)
    return . toResponse . encode . Map.keys $ measurements

displayDetails :: Host -> TestName -> ServerPart Response
displayDetails hostName testName = do
    allMeasurements <- query GetMeasurements
    if (hostName, testName) `Map.member` allMeasurements
        then fileServeStrict [] "static/test-details.html"
        else fail $ "no such test or host" ++ show (testName, hostName)

testInfo :: Host -> TestName -> ServerPart Response
testInfo hostName testName = do
    allMeasurements <- query GetMeasurements
    let measurements = allMeasurements Map.! (hostName, testName)
    return . toResponse . encode $ measurements

justTestInfo :: TestName -> ServerPart Response
justTestInfo testName = do
    allMeasurements <- query GetMeasurements
    return . toResponse . encode . map (first fst) . filter ((==testName).snd.fst) . Map.toList $ allMeasurements

justTest :: TestName -> ServerPart Response
justTest testName = (nullDir >> fileServeStrict [] "static/test.html")
          `mappend` (dir "json" $ methodSP GET $ justTestInfo testName)


handleRemoveResult :: Host -> TestName -> ServerPart Response
handleRemoveResult host test = do
    Just revision <- getDataFn $ look "revision"
    Just dur <- getDataFn $ lookRead "duration"
    update (DeleteResult (host, test, revision, dur))
    return $ toResponse $ "ok" ++ show (revision, dur)


testHostPart test host = msum [
        methodSP GET $ displayDetails host test
      , methodSP POST $ reportMeasurement test host
      , dir "json" $ testInfo host test
      , dir "remove" $ methodSP POST $ handleRemoveResult host test
    ]


controller = msum [
          nullDir >> fileServeStrict [] "static/index.html"
        , dir "static" $ fileServeStrict [] "static"
        , dir "tests" tests -- json
        , dir "list" listMeasurements -- raw page
        , path (\testName -> justTest testName `mappend` path (\hostName -> testHostPart testName hostName))
    ]


main = do
    args <- getArgs
    let stateName = case args of
         [name] -> name
         [] -> "apprazor"
    withProgName stateName $ do
        control <- startSystemState entryPoint
        tid <- forkIO $ simpleHTTP (Conf 5003 Nothing) $ controller
        putStrLn "listening on port 5003"
        waitForTermination
        killThread tid
        createCheckpoint control
        shutdownSystem control
    where entryPoint :: Proxy State
          entryPoint = Proxy

