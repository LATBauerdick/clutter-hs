{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -Wno-missing-fields #-}

module Env
  ( envUpdate,
    envInit,
    envUpdateAlbum,
    envTidalConnect,
    envGetTag,
    envUpdateSort,
  )
where


import qualified Data.Map.Strict as M
import Data.Vector (Vector)
import qualified Data.List as L
  ( union
  )
import qualified Data.Vector as V
  ( empty,
    fromList,
    null,
    reverse,
    toList,
  )
import Provider
  ( readAlbum,
    readAlbumsCache,
    readAlbums,
    readDiscogsAlbums,
    readTidalAlbums,
    readFolderAids,
    readFolders,
    readDiscogsFolders,
    readFoldersCache,
    readListAids,
    readDiscogsLists,
    readListsCache,
    readLists,
    updateTidalFolderAids,
  )

import Relude
import Types
  ( Album (..),
    Discogs (..),
    DiscogsInfo (..),
    AppM,
    Env (..),
    EnvR (..),
    SortOrder (..),
    Tidal (..),
    TidalInfo (..),
    pLocList,
  )


envTidalConnect :: Int -> AppM Env
envTidalConnect _nalbums = do
  t <- readFileText "data/tok.dat" -- for debug, get from file with authentication data
  let [t0, t1, t2, t3, t4, t5] = words t
      countryCode = t4
      sessionId = t3
      userId = fromMaybe 0 $ readMaybe (toString t2) :: Int
      accessToken = t5
  let tidal = Tidal $ TidalSession userId sessionId countryCode accessToken

  env <- ask
  oldAlbums <- readIORef $ albumsR env
  vta <- liftIO $ readTidalAlbums tidal
  newFolders <- readFolders -- readDiscogsFolders
  let tidalAlbums = M.fromList $ (\a -> (albumID a, a)) <$> V.toList vta
  let allAlbums = oldAlbums <> tidalAlbums
  _ <- liftIO $ writeIORef (albumsR env) allAlbums

  -- create the Tags index
  putTextLn "-------------- Updating Tags index"
  let tagsMap :: Map Text [Int]
      tagsMap = foldr updateTags M.empty (M.elems allAlbums)
  putTextLn "---------------------- list of Tags found: "
  print (M.keys tagsMap)

  -- reread Discogs lists info
  lm <- readLists
  -- reread folder album ids
  let fm :: Map Text (Int, Vector Int)
      fm = readFolderAids newFolders allAlbums
  let allLists = lm <> fm
  _ <- M.traverseWithKey (\n (i, vi) -> putTextLn $ show n <> "--" <> show i <> ": " <> show (length vi)) allLists

  _ <- writeIORef (listsR env) allLists
  _ <- writeIORef (listNamesR env) $ M.fromList . map (\(ln, (lid, _)) -> (ln, lid)) $ M.toList allLists
  _ <- writeIORef (sortNameR env) "Default"
  _ <- writeIORef (sortOrderR env) Asc

  pure env

-- get laters n releases from Discogs
-- also update folders and lists, update other metadata
envUpdate :: Text -> Text -> Int -> AppM ()
envUpdate tok un nreleases = do
  env <- ask
  let discogs' = Discogs $ DiscogsSession tok un
  putTextLn $ "-----------------Updating from " <> show discogs'

  -- save tidal albums map
  oldAlbums <- readIORef $ albumsR env
  oldLists <- readIORef $ listsR env
  let (_, tl) = fromMaybe (0, V.empty) $ M.lookup "Tidal" oldLists
      vta :: Vector Album
      vta = V.fromList $ mapMaybe (`M.lookup` oldAlbums) $ V.toList tl
      tidalAlbums = M.fromList $ (\a -> (albumID a, a)) <$> V.toList vta

  -- update with the new discogs info
  _ <- writeIORef (discogsR env) discogs'

  -- reread Discogs folders info
  newFolders <- readFolders

  -- reread Discogs albums info, overwriting with changes
  -- newAlbums <- if nreleases == 0
  --                   then
  --                     M.fromList . map (\a -> (albumID a, a)) . V.toList
  --                       <$> readAlbums env
  --                   else
  --                     M.fromList . map (\a -> (albumID a, a)) . V.toList
  --                       <$> readAlbums env nreleases
  newAlbums <- M.fromList . map (\a -> (albumID a, a)) . V.toList
                          <$> readAlbums nreleases
  let allAlbums = newAlbums <> oldAlbums <> tidalAlbums
  _ <- writeIORef (albumsR env) allAlbums

  -- create the Tags index
  putTextLn "-------------- Updating Tags index"
  let tagsMap :: Map Text [Int]
      tagsMap = foldr updateTags M.empty (M.elems allAlbums)
  putTextLn "---------------------- list of Tags found: "
  print (M.keys tagsMap)

  -- reread Discogs lists info
  lm <- readLists
  -- reread folder album ids
  let fm :: Map Text (Int, Vector Int)
      fm = readFolderAids newFolders allAlbums
  let allLists = lm <> fm
  _ <- M.traverseWithKey (\n (i, vi) -> putTextLn $ show n <> "--" <> show i <> ": " <> show (length vi)) allLists

  _ <- writeIORef (listsR env) allLists
  _ <- writeIORef (listNamesR env) $ M.fromList . map (\(ln, (lid, _)) -> (ln, lid)) $ M.toList allLists
  _ <- writeIORef (sortNameR env) "Default"
  _ <- writeIORef (sortOrderR env) Asc
  pure ()

fromListMap :: (Text, (Int, Vector Int)) -> [(Int, (Text, Int))]
fromListMap (ln, (_, aids)) = zipWith (\idx aid -> (aid, (ln, idx))) [1 ..] (V.toList aids)

updateTags :: Album -> Map Text [Int] -> Map Text [Int]
updateTags a m = foldr
            (\k mm -> M.insertWith L.union k (one (albumID a)) mm)
            m
            (albumTags a)

-- initialize Env
-- get info from Tidal
-- get tolder and list info from Discogs, read release info from cached JSON
--

initInit :: Bool -> IO (Discogs, Map Int Album, Map Text Int, Map Text (Int, Vector Int))
initInit c = do
  t <- readFileText "data/tok.dat" -- for debug, get from file with authentication data
  let [t0, t1, t2, t3, t4, t5] = words t
      countryCode = t4
      sessionId = t3
      userId = fromMaybe 0 $ readMaybe (toString t2) :: Int
      discogsToken = t0
      discogsUser = t1
      accessToken = t5

  -- from cache file or from Tidal API
  -- let _tidal = Tidal $ TidalFile "data/traw2.json"
  let tidal = Tidal $ TidalSession userId sessionId countryCode accessToken

  -- from cache file or from Discogs API
  let dci_ = Discogs $ DiscogsFile "data/"
  let dci = Discogs $ DiscogsSession discogsToken discogsUser

  -- read the map of Discogs folder names and ids
  -- fns :: Map Text Int
  -- fns <- liftIO $ readFoldersCache (getDiscogs dci_)
  fns <- liftIO $ readDiscogsFolders (getDiscogs dci)

  -- vda/vta :: Vector of Album
  vta <- liftIO $ readTidalAlbums tidal
  vda <- if c
            then liftIO $ readAlbumsCache (getDiscogs dci_) fns -- from cache
            else liftIO $ readDiscogsAlbums (getDiscogs dci) fns -- Discogs query, long
    -- then putTextLn "-----------------using cached Discogs collection info"
    -- else putTextLn "-----------------reading Discogs collection info from the web"

  let albums' :: Map Int Album
      albums' =
        M.fromList $
          (\a -> (albumID a, a)) <$> V.toList (vda <> vta)

  -- create the Tags index
  putTextLn "-------------- Updating Tags index"
  let tagsMap :: Map Text [Int]
      tagsMap = foldr updateTags M.empty (M.elems albums')
  putTextLn "---------------------- list of Tags found: "
  print (M.keys tagsMap)

  -- read the map of Discogs lists (still empty album ids)
  -- lm <- liftIO $ readListsCache (getDiscogs dci_)
  lm <- liftIO $ readDiscogsLists (getDiscogs dci)

  pure (dci, albums', fns, lm)


envInit :: Bool -> IO Env
envInit c = do
  -- set up the sort functions
  -- and populate the initial env maps from cache files
  --
  -- get Map of all albums from Providers:
  -- retrieve database from files
  --
  -- get initial database info from providers and/or cached JSON
  --  dc :: Discogs                     -- discogs credentials
  --  albums' :: Map Int Album          -- map of Albums indexed with their IDs
  --  fns :: Map Text Int               -- map of folder names with their IDs
  --  lm :: Map Text (Int, Vector Int)  -- map of list names with IDs and contents
  (dc,albums',fns,lm) <- initInit c

  -- create the Tags index
  putTextLn "-------------- Updating Tags index"
  let tagsMap :: Map Text [Int]
      tagsMap = foldr updateTags M.empty (M.elems albums')

  let fm :: Map Text (Int, Vector Int)
      fm = readFolderAids fns albums'

  let lists' = lm <> fm
  let listNames' :: Map Text Int
      listNames' =  M.fromList . map (\(ln, (lid, _)) -> (ln, lid)) $ M.toList lists'
  _ <- M.traverseWithKey (\n (i, vi) -> putTextLn $ show n <> "--" <> show i <> ": " <> show (length vi)) lists'
  let allLocs = M.fromList . concatMap fromListMap . filter (pLocList . fst) . M.toList $ lm

  dr <- newIORef dc
  ar <- newIORef albums'
  lr <- newIORef lists'
  lo <- newIORef allLocs
  lnr <- newIORef listNames'
  sr <- newIORef "Default"
  so <- newIORef Asc
  tr <- newIORef tagsMap
  fr <- newIORef []
  -- define sort functions and map to names
  let sDef :: Map Int Album -> SortOrder -> Vector Int -> Vector Int
      sDef _ s l = case s of
        Asc -> l
        _ -> V.reverse l
  let sortAsi :: Map Int Album -> Vector Int -> [(Int, Maybe Album)]
      sortAsi am = map (\aid -> (aid, M.lookup aid am)) . V.toList
      compareAsc f (_, a) (_, b) = comparing f a b
      compareDesc f (_, a) (_, b) = comparing f b a
  let sTitle :: Map Int Album -> SortOrder -> Vector Int -> Vector Int
      sTitle am s aids = V.fromList (fst <$> sortBy (comp s) (sortAsi am aids))
        where
          comp o = case o of
            Asc -> compareAsc (fmap albumTitle)
            Desc -> compareDesc (fmap albumTitle)
  let sArtist :: Map Int Album -> SortOrder -> Vector Int -> Vector Int
      sArtist am s aids = V.fromList (fst <$> sortBy (comp s) (sortAsi am aids))
        where
          comp o = case o of
            Asc -> compareAsc (fmap albumArtist)
            Desc -> compareDesc (fmap albumArtist)
  let sAdded :: Map Int Album -> SortOrder -> Vector Int -> Vector Int
      sAdded am s aids = V.fromList (fst <$> sortBy (comp s) (sortAsi am aids))
        where
          comp o = case o of
            Asc -> compareDesc (fmap albumAdded)
            Desc -> compareAsc (fmap albumAdded)
  let sfs :: Map Text (Map Int Album -> SortOrder -> Vector Int -> Vector Int) -- sort functions
      sfs =
        M.fromList
          [ ("Default", sDef),
            ("Artist", sArtist),
            ("Title", sTitle),
            ("Added", sAdded)
          ]
  pure
    Env
      { discogsR = dr,
        albumsR = ar,
        listsR = lr,
        locsR = lo,
        listNamesR = lnr,
        tagsR = tr,
        focusR = fr,
        sortNameR = sr,
        sortOrderR = so,
        url = "/",
        getList = getList',
        sorts = V.fromList $ M.keys sfs,
        getSort = \ am sn -> fromMaybe sDef (M.lookup sn sfs) am
      }
--
-- define the function for (env getList) :: Text -> AppM ( Vector Int )
-- that will evaluate the list of Album IDs for List name
--  if list in Env is empty, try to get from provider
getList' :: Text -> AppM (Vector Int)
getList' ln = do
  env <- ask
  ls' <- readIORef (listsR env)
  let (lid, aids') = fromMaybe (0, V.empty) (M.lookup ln ls')
  if V.null aids'
    then do
      aids <- readListAids lid
      -- update location info in albums
      --   go through this list and update location in albums
      -- am <- liftIO ( readIORef (albumsR env) )
      -- am' <- updateLocations lists ln am aids -- not yet implemented
      -- _ <- writeIORef (albumsR env) am'
      if pLocList ln
        then do
          lcs <- readIORef (locsR env)
          let lcs' = M.union (M.fromList (fromListMap (ln, (lid, aids)))) lcs
          _ <- writeIORef (locsR env) lcs'
          pure ()
        else pure ()
      -- write back modified lists
      _ <- writeIORef (listsR env) $ M.insert ln (lid, aids) ls'
      pure aids
    else pure aids'

envUpdateAlbum :: Int -> AppM ( Maybe Album )
envUpdateAlbum aid = do
  env <- ask
  di <- readIORef (discogsR env)
  am' <- readIORef (albumsR env)
  ls <- readIORef (listsR env)
  -- check if this release id is already known / in the Map
  let ma' :: Maybe Album
      ma' = M.lookup aid am'
  -- if it's not a Tidal album, update album info from Discogs
  ma <- case fmap albumFormat ma' of
    Just "Tidal" -> pure ma'
    -- Just _ -> pure ma' -- already known, nothing do add
    _ -> case getDiscogs di of
              DiscogsSession _ _ -> readAlbum aid
              _ -> liftIO (pure Nothing) -- we only have the caching files
  _ <- case ma of
    Just a -> do
      -- insert updated album and put in album map
      let am = M.insert aid a am'
      liftIO $ writeIORef (albumsR env) am
      -- insert aid into its folder
      -- let folder = albumFolder a
      -- update folder "lists" and invalidate lists
  -- also update Tidal "special" list
      liftIO $ writeIORef (listsR env) (updateTidalFolderAids am ls)

-- update the tags map with tags from this album
      tm <- readIORef (tagsR env)
      _ <- writeIORef (tagsR env) (updateTags a tm)

  -- update lists and folders
      newFolders <- readFolders
      -- reread Discogs lists info
      lm <- readLists
      -- reread folder album ids
      let fm :: Map Text (Int, Vector Int)
          fm = readFolderAids newFolders am
      let allLists = lm <> fm
      -- _ <- M.traverseWithKey (\n (i, vi) -> putTextLn $ show n <> "--" <> show i <> ": " <> show (length vi)) allLists

      _ <- writeIORef (listsR env) allLists
      _ <- writeIORef (listNamesR env) $ M.fromList . map (\(ln, (lid, _)) -> (ln, lid)) $ M.toList allLists
      pure ()
    Nothing -> pure ()
  -- let mAlbum = M.lookup aid am
  print ma
  pure ma

envGetTag :: Text -> AppM [Int]
envGetTag t = do
  tm <- asks tagsR >>= readIORef
  pure $ fromMaybe [] (M.lookup t tm)

envUpdateSort :: Maybe Text -> Maybe Text -> AppM EnvR
envUpdateSort msb mso = do
  env <- ask
  am  <- readIORef (albumsR env)
  lns <- readIORef (listNamesR env)
  lm  <- readIORef (listsR env)
  lcs <- readIORef (locsR env)
  di  <- readIORef (discogsR env)
  tm  <- readIORef (tagsR env)
  fs  <- readIORef (focusR env)
  sn <- case msb of
    Nothing -> readIORef (sortNameR env)
    Just sb -> do
      _ <- writeIORef (sortNameR env) sb
      pure sb
  so <- case mso of
    Nothing -> readIORef (sortOrderR env)
    Just sot -> do
      let so = case sot of
            "Desc" -> Desc
            _ -> Asc
      _ <- writeIORef (sortOrderR env) so
      pure so
  pure $ EnvR am lm lcs lns sn so di tm fs

