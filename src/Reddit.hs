-- | This module should be most of what you need to operate the library.
--   It exports functionality for running built 'RedditT' actions, as well
--   as re-exporting a few helpful types from around the library. Not every
--   type is exported, however, due to clashing record fields. It's recommended
--   to import modules from @Reddit.Types.*@ qualified so that you can use all
--   the record fields without having to deal with ambiguous functions.
module Reddit
  ( runReddit
  , runRedditAnon
  , runRedditWith
  , runResumeRedditWith
  , interpretIO
  , RedditOptions(..)
  , defaultRedditOptions
  , LoginMethod(..)
  -- * Re-exports
  , APIError(..)
  , module Reddit.Actions
  , module Reddit.Types
  , module Reddit.Types.Error
  , module Reddit.Types.Reddit ) where

import Reddit.Actions
import Reddit.Login
import Reddit.Types.Error
import Reddit.Types
import Reddit.Types.Reddit hiding (info, should)

import Control.Concurrent
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Free
import Data.ByteString.Char8 (ByteString)
import Data.Default.Class
import Data.Maybe (fromMaybe, isNothing)
import Data.Monoid
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8)
import Data.Version
import Network.API.Builder as API
import Network.HTTP.Client
import Network.HTTP.Client.TLS
import Network.HTTP.Types
import qualified Data.ByteString.Char8 as BS

import qualified Paths_reddit

versionString :: ByteString
versionString =
  case Paths_reddit.version of
    Version xs _ -> BS.intercalate "." $ map (BS.pack . show) xs

-- | Options for how we should run the 'Reddit' action.
--
-- - 'rateLimitingEnabled': 'True' if the connection should be automatically rate-limited
--   and should pause when we hit the limit, 'False' otherwise. Default is 'True'.
--
-- - 'connectionManager': @'Just' x@ if the connection should use the 'Manager' @x@, 'Nothing'
--   if we should create a new one for the connection. Default is 'Nothing'.
--
-- - 'loginMethod': The method we should use for authentication, described in 'LoginMethod'.
--   Default is 'Anonymous'.
--
-- - 'customUserAgent': @'Just' "string"@ if the connection should use the user agent @"string"@,
--   @'Nothing'@ if it should use the default agent. Default is 'Nothing'.
data RedditOptions =
  RedditOptions { rateLimitingEnabled :: Bool
                , connectionManager :: Maybe Manager
                , loginMethod :: LoginMethod
                , customUserAgent :: Maybe ByteString }

instance Default RedditOptions where
  def = RedditOptions True Nothing Anonymous Nothing

-- | The default set of options
defaultRedditOptions :: RedditOptions
defaultRedditOptions = def

-- | Should we log in to Reddit? If so, should we use a stored set of credentials
--   or get a new fresh set?
data LoginMethod = Anonymous -- ^ Don't login, instead use an anonymous account
                 | Credentials Text Text -- ^ Login using the specified username and password
                 | StoredDetails LoginDetails -- ^
                 --   Login using a stored set of credentials. Usually the best way to get
                 --   these is to do @'runRedditAnon' $ 'login' user pass@.
  deriving (Show)

instance Default LoginMethod where def = Anonymous

-- | Run a 'Reddit' action (or a 'RedditT' transformer action). This uses the default logged-in settings
--   for 'RedditOptions': rate limiting enabled, default manager, login via username and password, and
--   the default user-agent. You should change the user agent if you're making anything more complex than
--   a basic script, since Reddit's API policy says that you should have a uniquely identifiable user agent.
runReddit :: MonadIO m => Text -> Text -> RedditT m a -> m (Either (APIError RedditError) a)
runReddit user pass = runRedditWith def { loginMethod = Credentials user pass }

-- | Run a 'Reddit' action (or a 'RedditT' transformer action). This uses the default logged-out settings, so
--   you won't be able to do anything that requires authentication (like checking messages or making a post).
--   At the moment, authentication isn't statically checked, so it'll return a runtime error if you try to do
--   anything you don't have permissions for.
runRedditAnon :: MonadIO m => RedditT m a -> m (Either (APIError RedditError) a)
runRedditAnon = runRedditWith def

-- | Run a 'Reddit' or 'RedditT' action with custom settings. You probably won't need this function for
--   most things, but it's handy if you want to persist a connection over multiple 'Reddit' sessions or
--   use a custom user agent string.
runRedditWith :: MonadIO m => RedditOptions -> RedditT m a -> m (Either (APIError RedditError) a)
runRedditWith opts reddit = liftM dropResume $ runResumeRedditWith opts reddit

-- | Run a 'Reddit' or 'RedditT' action with custom settings. You probably won't need this function for
--   most things, but it's handy if you want to persist a connection over multiple 'Reddit' sessions or
--   use a custom user agent string.
runResumeRedditWith :: MonadIO m => RedditOptions -> RedditT m a -> m (Either (APIError RedditError, Maybe (RedditT m a)) a)
runResumeRedditWith (RedditOptions rl man lm ua) reddit = do
  when (isNothing ua) customUAWarning
  manager <- case man of
    Just m -> return m
    Nothing -> liftIO $ newManager tlsManagerSettings
  loginCreds <- case lm of
    Anonymous -> return $ Right Nothing
    StoredDetails ld -> return $ Right $ Just ld
    Credentials user pass -> liftM (fmap Just) $ interpretIO (RedditState loginBaseURL rl manager [] Nothing) $ login user pass
  case loginCreds of
    Left (err, _) -> return $ Left (err, Just reddit)
    Right lds ->
      interpretIO
        (RedditState mainBaseURL rl manager [("User-Agent", fromMaybe ("reddit-haskell " <> versionString) ua)] lds) reddit

interpretIO :: MonadIO m => RedditState -> RedditT m a -> m (Either (APIError RedditError, Maybe (RedditT m a)) a)
interpretIO rstate (RedditT r) =
  runFreeT r >>= \case
    Pure x -> return $ Right x
    Free (WithBaseURL u x n) ->
      interpretIO (rstate { currentBaseURL = u }) x >>= \case
        Left (err, Just resume) ->
          return $ Left (err, Just $ resume >>= RedditT . n)
        Left (err, Nothing) -> return $ Left (err, Nothing)
        Right res -> interpretIO rstate $ RedditT $ n res
    Free (FailWith x) -> return $ Left (x, Nothing)
    Free (Nest x n) ->
      interpretIO rstate $ RedditT $ wrap $ NestResuming x (n . dropResume)
    Free (NestResuming x n) -> do
      res <- interpretIO rstate x
      interpretIO rstate $ RedditT $ n res
    Free (RunRoute route n) ->
      interpretIO rstate $ RedditT $ wrap $ ReceiveRoute route (n . unwrapJSON)
    Free (ReceiveRoute route n) ->
      handleReceive route rstate >>= \case
        Left err@(APIError (RateLimitError secs _)) ->
          if rateLimit rstate
            then do
              liftIO $ threadDelay $ fromInteger secs * 1000 * 1000
              interpretIO rstate $ RedditT $ wrap $ ReceiveRoute route n
            else return $ Left (err, Just $ RedditT $ wrap $ ReceiveRoute route n)
        Left err -> return $ Left (err, Just $ RedditT $ wrap $ ReceiveRoute route n)
        Right x -> interpretIO rstate $ RedditT $ n x

dropResume :: Either (APIError RedditError, Maybe (RedditT m a)) a -> Either (APIError RedditError) a
dropResume (Left (x, _)) = Left x
dropResume (Right x) = Right x

handleReceive :: (MonadIO m, Receivable a) => Route -> RedditState -> m (Either (APIError RedditError) a)
handleReceive r rstate = do
  (res, _, _) <- runAPI (builderFromState rstate) (connMgr rstate) () $
    API.runRoute r
  return res

builderFromState :: RedditState -> Builder
builderFromState (RedditState burl _ _ hdrs (Just (LoginDetails (Modhash mh) cj))) =
  Builder "Reddit" burl addAPIType $
    \req -> addHeaders (("X-Modhash", encodeUtf8 mh):hdrs) req { cookieJar = Just cj }
builderFromState (RedditState burl _ _ hdrs Nothing) =
  Builder "Reddit" burl addAPIType (addHeaders hdrs)

addHeaders :: [Header] -> Request -> Request
addHeaders xs req = req { requestHeaders = requestHeaders req ++ xs }

data RedditState =
  RedditState { currentBaseURL :: Text
              , rateLimit :: Bool
              , connMgr :: Manager
              , _extraHeaders :: [Header]
              , _creds :: Maybe LoginDetails }

customUAWarning :: MonadIO m => m ()
customUAWarning = liftIO $ do
  putStrLn "WARNING: You haven't specified a custom Reddit user agent!"
  putStrLn "           This is against Reddit's terms of service, and you should probably fix it."
