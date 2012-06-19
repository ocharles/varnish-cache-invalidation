{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE OverloadedStrings #-}

import           Control.Applicative ((<*>), (<$>))
import           Control.Concurrent (forkIO)
import           Control.Concurrent.QSem
import           Control.Monad (forever)
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad.Reader (ReaderT, asks, runReaderT)
import           Control.Monad.Trans.Resource (ResourceT, runResourceT)
import           Data.Aeson (FromJSON(..), decode, (.:), Object, Value(..))
import           Data.Aeson.Types (Parser)
import qualified Data.ByteString.Lazy.Char8 as LBS
import           Data.Text (Text)
import           Database.PostgreSQL.Simple (Connection, connect, defaultConnectInfo, Only(..), query, ConnectInfo(..))
import           Network.AMQP (consumeMsgs, Ack(..), queueName, bindQueue, openChannel, declareQueue, newQueue, ackEnv, openConnection, msgBody, Message, Envelope, declareExchange, newExchange, exchangeName, exchangeType)
import           Network.HTTP.Conduit (http, withManager, parseUrl, method, Manager, newManager, def)
import           System.Log.Logger (debugM, infoM, errorM, updateGlobalLogger, setLevel, Priority(..))

-- | A basic environment the script runs in.
data Env = Env { pgConn :: Connection, httpManager :: Manager, sem :: QSem }

type Script a = ReaderT Env (ResourceT IO) a

-- | There are 3 different classes of events - updates, which contain an old and
-- new 'Row'; inserts, which contain a single new row; and deletes, which
-- contain just the deleted row.
data Event = Update Row Row | Insert Row | Delete Row
  deriving (Show)

-- | The various different rows inside the database, with the columns that are
-- important for cache invalidation.
data Row = Artist { artistId :: Int, artistMbid :: String }
  deriving (Show)

-- | Map a table name to a JSON parser. May fail, if we don't have a parser for
-- this table (which means we probably aren't interested in its contents for
-- cache invalidation.)
jsonRowMapping :: String -> Maybe (Object -> Parser Row)
jsonRowMapping tableName = case tableName of
  "artist" -> return $ \o -> Artist <$> o .: "id" <*> o .: "gid"
  _ -> Nothing

instance FromJSON Event where
  parseJSON (Object v) = do
      tableName <- v .: "table"
      event     <- v .: "event"
      case jsonRowMapping tableName of
        Nothing -> fail $ "Unknown table " ++ tableName
        Just m -> do
          case event of
            "insert" -> Insert <$> takeData v "new" m
            "delete" -> Delete <$> takeData v "old" m
            "update" -> Update <$> takeData v "old" m <*> takeData v "new" m
            _ -> fail (event ++ " is not a recognised event type")
      where takeData v l m = (v .: l) >>= m

  parseJSON _ = fail "Expected a JSON object"

rowChanged :: Row -> Script ()
rowChanged (Artist id mbid) = addBan $ "artist:" ++ show id

varnishPrefix :: String
varnishPrefix = "http://localhost:9000/"

addBan :: String -> Script ()
addBan path = do
  sem <- asks sem
  env <- asks httpManager
  liftIO $ do
    waitQSem sem
    debugM "MBCacheInvalidator" $ "Adding a ban on " ++ path
    forkIO $ runResourceT $ do
      initReq <- parseUrl $ varnishPrefix ++ path
      let req = initReq { method = "BAN" }
      http req httpManager
      liftIO $ signalQSem sem
  return ()

handleEvent :: Event -> Script ()
handleEvent e = mapM_ rowChanged rows
  where rows = case e of
                 Update old new -> [ old, new ]
                 Insert new -> return new
                 Delete old -> return old

receiveMessage :: (Message, Envelope) -> Script ()
receiveMessage (msg, env) = do
  case decode (msgBody msg) of
    Nothing -> liftIO $ do
      errorM "MBCacheInvalidator" $ "Error occured handling event"
      errorM "MBCacheInvalidator" $ "Message body: " ++ (LBS.unpack $ msgBody msg)
    Just event -> do
      liftIO $ debugM "MBCacheInvalidator" $ "Handling: " ++ show event
      handleEvent event
  liftIO $ ackEnv env

main :: IO ()
main = do
    updateGlobalLogger "MBCacheInvalidator" (setLevel DEBUG)

    conn <- openConnection "127.0.0.1" "/" "guest" "guest"
    chan <- openChannel conn

    -- declare a queue, exchange and binding
    declareQueue chan newQueue {queueName = "database"}
    declareExchange chan newExchange {exchangeName = "pg", exchangeType = "fanout"}
    bindQueue chan "database" "pg" "database"

    -- subscribe to the queue
    buildCallback >>= consumeMsgs chan "database" Ack

    forever getLine
  where buildCallback = do pgConn <- connect defaultConnectInfo { connectDatabase = "musicbrainz" }
                           httpManager <- newManager def
                           sem <- newQSem 5
                           let env = Env { pgConn = pgConn, httpManager = httpManager, sem = sem }
                           return $ \cb -> runResourceT $ runReaderT (receiveMessage cb) env
