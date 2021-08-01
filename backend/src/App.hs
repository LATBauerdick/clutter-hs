{-# LANGUAGE DataKinds #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE NoImplicitPrelude #-}

module App
  ( startApp,
    app,
    initEnv,
  )
where

import qualified Data.ByteString.Lazy as BL
import qualified Data.Map.Strict as M
import Data.Time (getZonedTime)

import Env
  ( initEnv,
    refreshEnv,
  )
import qualified Lucid as L
import Network.HTTP.Media ((//), (/:))
import Network.Wai
import Network.Wai.Handler.Warp
import Provider ( readAlbum
                , updateTidalFolderAids
                )
import Relude
import Render
  ( renderAlbum,
    renderAlbums,
  )
import Servant
import Types (DiscogsInfo (..), Env (..), EnvR (..), SortOrder (..), getDiscogs, Album (..))

data HTML = HTML

newtype RawHtml = RawHtml {unRaw :: BL.ByteString}

instance Accept HTML where
  contentType _ = "text" // "html" /: ("charset", "utf-8")

instance MimeRender HTML RawHtml where
  mimeRender _ = unRaw

------------------ Servant Stuff

type API0 =
  "album"
    :> Capture "aid" Int
    :> Get '[HTML] RawHtml

type API1 =
  "albums"
    :> Capture "list" Text
    :> QueryParam "sortBy" Text
    :> QueryParam "sortOrder" Text
    :> Get '[HTML] RawHtml

type API2 =
  "add"
    :> Capture "releaseid" Int
    :> Get '[HTML] RawHtml

type API3 =
  "provider"
    :> "discogs"
    :> Capture "token" Text
    :> Capture "username" Text
    :> Get '[HTML] RawHtml

type API4 =
  "provider"
    :> "tidal"
    :> Capture "token" Text
    :> Capture "username" Text
    :> Get '[HTML] RawHtml

type API = API0 :<|> API1 :<|> API2 :<|> API3 :<|> API4 :<|> Raw

api :: Proxy API
api = Proxy

server :: Env -> Server API
server env =
  serveAlbum
    :<|> serveAlbums
    :<|> serveAdd
    :<|> serveDiscogs
    :<|> serveTidal
    :<|> serveDirectoryFileServer "static"
  where
    serveAlbum :: Int -> Handler RawHtml
    serveAlbum aid = do
      di <- liftIO (readIORef (discogsR env))
      am <- liftIO (readIORef (albumsR env))
      ls <- liftIO (readIORef (listsR env))
      -- check if this aid is already known / in the Map
      let mam = M.lookup aid am
      -- if it's not a Tidal album, update album info from Discogs
      ma <- case fmap albumFormat mam of
        Just "Tidal" -> pure mam
        _ -> case getDiscogs di of
                  DiscogsSession _ _ -> liftIO (readAlbum di aid)
                  _ -> liftIO (pure Nothing)
      _ <- case ma of
        Just a -> do
      -- insert updated album and put in album map
          liftIO $ writeIORef (albumsR env) (M.insert aid a am)
      -- also update Tidal "special" list
          liftIO $ writeIORef (listsR env) (updateTidalFolderAids am ls)
        Nothing -> pure ()

      -- let mAlbum = M.lookup aid am
      _ <- liftIO $ print ma

      now <- liftIO getZonedTime -- `debugId`
      pure . RawHtml $ L.renderBS (renderAlbum ma now)

    serveAlbums :: Text -> Maybe Text -> Maybe Text -> Handler RawHtml
    serveAlbums listName msb mso = do
      aids' <- liftIO (getList env env listName)
      am <- liftIO (readIORef (albumsR env))
      lns <- liftIO (readIORef (listNamesR env))
      sn <- case msb of
        Nothing -> liftIO (readIORef (sortNameR env))
        Just sb -> do
          _ <- writeIORef (sortNameR env) sb
          pure sb
      so <- case mso of
        Nothing -> liftIO (readIORef (sortOrderR env))
        Just sot -> do
          let so = case sot of
                "Desc" -> Desc
                _ -> Asc
          _ <- writeIORef (sortOrderR env) so
          pure so

      let doSort = getSort env am sn
      let aids = doSort so aids'
      lm <- liftIO (readIORef (listsR env))
      lcs <- liftIO (readIORef (locsR env))
      di <- liftIO (readIORef (discogsR env))
      let envr = EnvR am lm lcs lns sn so di
      pure . RawHtml $
        L.renderBS (renderAlbums env envr listName aids)
    -- serveJSON :: Server API2
    -- serveJSON = do
    --   pure $ M.elems ( albums env )

    serveAdd :: Int -> Handler RawHtml
    serveAdd rid = do
      di <- liftIO (readIORef (discogsR env))
      am <- liftIO (readIORef (albumsR env))
      ls <- liftIO (readIORef (listsR env))
      -- check if this release id is already known / in the Map
      let mam = M.lookup rid am
      -- if it's not a Tidal album, update album info from Discogs
      -- here we need to add it to the album map and to all lists it is on XXXX TO BE DONE
      ma <- case fmap albumFormat mam of
        Just "Tidal" -> pure mam
        Just _ -> pure mam -- already known, nothing do add
        _ -> case getDiscogs di of
                  DiscogsSession _ _ -> liftIO (readAlbum di rid)
                  _ -> liftIO (pure Nothing)
      _ <- case ma of
        Just a -> do
      -- insert updated album and put in album map
          liftIO $ writeIORef (albumsR env) (M.insert rid a am)
      -- also update Tidal "special" list
          liftIO $ writeIORef (listsR env) (updateTidalFolderAids am ls)
        Nothing -> pure ()

      -- let mAlbum = M.lookup aid am
      _ <- liftIO $ print ma

      now <- liftIO getZonedTime -- `debugId`
      pure . RawHtml $ L.renderBS (renderAlbum ma now)

    serveDiscogs :: Text -> Text -> Handler RawHtml
    serveDiscogs token username = do
      _ <- liftIO (refreshEnv env token username)
      am <- liftIO (readIORef (albumsR env))
      lm <- liftIO (readIORef (listsR env))
      lcs <- liftIO (readIORef (locsR env))
      lns <- liftIO (readIORef (listNamesR env))
      sn <- liftIO (readIORef (sortNameR env))
      so <- liftIO (readIORef (sortOrderR env))
      di <- liftIO (readIORef (discogsR env))
      let ln = "Discogs"
      aids <- liftIO (getList env env ln)
      let envr = EnvR am lm lcs lns sn so di
      pure . RawHtml $ L.renderBS (renderAlbums env envr ln aids)

    serveTidal :: Text -> Text -> Handler RawHtml
    serveTidal token username = do
      _ <- liftIO (refreshEnv env token username)
      am <- liftIO (readIORef (albumsR env))
      lm <- liftIO (readIORef (listsR env))
      lcs <- liftIO (readIORef (locsR env))
      lns <- liftIO (readIORef (listNamesR env))
      sn <- liftIO (readIORef (sortNameR env))
      so <- liftIO (readIORef (sortOrderR env))
      di <- liftIO (readIORef (discogsR env))
      let ln = "Tidal"
      aids <- liftIO (getList env env ln)
      let envr = EnvR am lm lcs lns sn so di
      pure . RawHtml $ L.renderBS (renderAlbums env envr ln aids)

startApp :: IO ()
startApp = initEnv >>= (run 8080 . app)

app :: Env -> Application
app env = serve api $ server env
