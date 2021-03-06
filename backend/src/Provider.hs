{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# OPTIONS_GHC -fno-warn-warnings-deprecations #-}

module Provider
  (
    readListAids,
    readAlbum,
    readAlbums,
    readDiscogsAlbums,
    readAlbumsCache,
    readDiscogsLists,
    readListsCache,
    readFolders,
    readDiscogsFolders,
    readFoldersCache,
    readFolderAids,
    readLists,
    readTidalAlbums,
    updateTidalFolderAids,
  )
where

-- import Data.Text.Encoding ( decodeUtf8 )
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Data.Vector (Vector)
import qualified Data.Vector as V
import qualified FromDiscogs as FD
  ( readDiscogsFolders,
    readDiscogsFoldersCache,
    readDiscogsListsCache,
    readDiscogsRelease,
    readReleases,
    readDiscogsReleases,
    readDiscogsReleasesCache,
    readListAids,
    readLists,
  )
import qualified FromTidal as FT (readTidalReleases, readTidalReleasesCache)
import Relude
import Types
  ( Album (..),
    Discogs (..),
    DiscogsInfo (..),
    Release (..),
    TagFolder (..),
    Tidal (..),
    TidalInfo (..),
    AppM,
    envGetDiscogs,
    getDiscogs,
    getTidal,
  )
-- import Relude.Debug ( trace )
debug :: a -> Text -> a
debug a b = trace (toString b) a

dToAlbum :: Release -> Album
dToAlbum r =
  Album
    (daid r)
    (dtitle r)
    (T.intercalate ", " $ dartists r)
    (dreleased r)
    (dcover r)
    (dadded r)
    (dfolder r)
    (makeDiscogsURL (daid r))
    (dformat r)
    (dtidalid r)
    (damid r)
    (dlocation r)
    (dtags r)
    (drating r)
    (dplays r)
  where
    makeDiscogsURL a = T.pack $ "https://www.discogs.com/release/" ++ show a

readLists :: AppM (Map Text (Int, Vector Int))
readLists = do
  p <- envGetDiscogs
  case getDiscogs p of
    DiscogsFile fn -> error $ "Bug: Provider Discogs does not read lists from files " <> toText fn
    _ -> liftIO $ FD.readLists (getDiscogs p)

readDiscogsLists = FD.readLists

readListsCache :: DiscogsInfo -> IO (Map Text (Int, Vector Int))
readListsCache di = do
  case di of
    DiscogsFile fn -> FD.readDiscogsListsCache fn
    _ -> error "readListsCache no file"

readAlbum :: Int -> AppM (Maybe Album)
readAlbum aid = do
  p <- envGetDiscogs
  d <- case getDiscogs p of
    DiscogsSession _ _ -> FD.readDiscogsRelease (getDiscogs p) aid
    _ -> pure Nothing
  let a = dToAlbum <$> d
  putTextLn $ "Retrieved Discogs Album " <> show (albumTitle <$> a)
  pure a

readAlbums :: Int -> AppM (Vector Album)
readAlbums nreleases = do
    ds <- FD.readReleases nreleases
    let as = dToAlbum <$> ds
    putTextLn $ "Total # Discogs Albums read: " <> show (length as)
    pure $ V.fromList as

readDiscogsAlbums :: DiscogsInfo -> Map Text Int -> IO (Vector Album)
readDiscogsAlbums di lns = do
    ds <- FD.readDiscogsReleases di lns
    let as = dToAlbum <$> ds
    putTextLn $ "Total # Discogs Albums read: " <> show (length as)
    pure $ V.fromList as

readAlbumsCache :: DiscogsInfo -> Map Text Int -> IO (Vector Album)
readAlbumsCache di lns = do
-- need to pass down Map of list/folder names for decoding when we fill Albums
    ds <- case di of
      DiscogsFile fn -> FD.readDiscogsReleasesCache fn lns
      _ -> error "readAlbumsCache no file"
    let as = dToAlbum <$> ds

    putTextLn $ "Total # Discogs Albums: " <> show (length as)

    pure $ V.fromList as

readListAids :: Int -> AppM (Vector Int)
readListAids i = do
  p <- envGetDiscogs
  case getDiscogs p of
        DiscogsFile _ -> pure V.empty -- maybe not ok
        _ -> FD.readListAids i

readFolders :: AppM (Map Text Int)
readFolders = do
  p <- envGetDiscogs
  case getDiscogs p of
    DiscogsFile fn -> liftIO $ FD.readDiscogsFoldersCache fn
    _ -> liftIO $ FD.readDiscogsFolders (getDiscogs p)

readDiscogsFolders = FD.readDiscogsFolders

readFoldersCache :: DiscogsInfo -> IO (Map Text Int)
readFoldersCache di = do
  case di of
    DiscogsFile fn -> FD.readDiscogsFoldersCache fn
    _ -> error "readFoldersCache no file"

-- populate the aids for folders from the folder+id in each Album
-- special treatment for Tidal, Discogs, and All folders
updateTidalFolderAids :: Map Int Album -> Map Text (Int, Vector Int) -> Map Text (Int, Vector Int)
updateTidalFolderAids am = M.insert "Tidal" (fromEnum TTidal, allTidal) where
    -- for Tidal folder, replace anything that's also on Discogs
    xxx :: [(Int, Int)]
    xxx = mapMaybe (\a -> case readMaybe . toString =<< albumTidal a of
                            Just i -> if i == albumID a then Nothing else Just (i , albumID a)
                            Nothing -> Nothing
                   )
        $ M.elems am
    tidalToDiscogs = M.fromList xxx `debug` show xxx
    allTidal  = V.map (\i -> fromMaybe i (i `M.lookup` tidalToDiscogs))
              . sAdded
              .  V.map fst
              . V.filter (\(_, f) -> f == fromEnum TTidal)
              . V.map (\a -> (albumID a, albumFolder a))
              .  V.fromList $ M.elems am
    sAdded :: Vector Int -> Vector Int
    sAdded aids = V.fromList (fst <$> sortBy (\(_, a) (_, b) -> comparing (fmap albumAdded) b a) asi)
      where
        asi :: [(Int, Maybe Album)]
        asi = map (\aid -> (aid, M.lookup aid am)) $ V.toList aids


readFolderAids :: Map Text Int -> Map Int Album -> Map Text (Int, Vector Int)
readFolderAids fm am = fam
  where
    fam' = M.map getFolder fm
    fam = updateTidalFolderAids am
        . M.insert "Discogs" (fromEnum TDiscogs, allDiscogs)
        . M.insert "All" (fromEnum TAll, allAlbums)
        $ fam'
    allAlbums = sAdded
              . V.map albumID
              . V.fromList $ M.elems am
    allDiscogs  = sAdded
                . V.map fst
                . V.filter (\(_, f) -> f /= fromEnum TTidal)
                . V.map (\a -> (albumID a, albumFolder a))
                . V.fromList $ M.elems am
    getFolder :: Int -> (Int, Vector Int)
    getFolder i = (i, filtFolder i)
    filtFolder :: Int -> Vector Int
    filtFolder fid  = sAdded
                    . V.map fst
                    . V.filter (\(_, f) -> f == fid)
                    . V.map (\a -> (albumID a, albumFolder a))
                    . V.fromList $ M.elems am
    sAdded :: Vector Int -> Vector Int
    sAdded aids = V.fromList (fst <$> sortBy (\(_, a) (_, b) -> comparing (fmap albumAdded) b a) asi)
      where
        asi :: [(Int, Maybe Album)]
        asi = map (\aid -> (aid, M.lookup aid am)) $ V.toList aids

-- items[].item.type
-- "SINGLE"
-- "ALBUM"
-- "EP"

-- link : http://www.tidal.com/album/aid
--             https://listen.tidal.com/album/
--             https://www.discogs.com/release/

-- items[].item.audioQuality
-- LOSSLESS
-- HI_RES
-- HIGH


readTidalAlbums :: Tidal -> IO (Vector Album)
readTidalAlbums p = do
    let ttoCoverURL r =
          T.concat
            [ T.pack "https://resources.tidal.com/images/",
              T.intercalate "/" $ T.splitOn "-" (dcover r),
              T.pack "/320x320.jpg"
            ]
        -- tgetAlbumURL :: Album -> Text
        -- tgetAlbumURL a = makeTidalURL (albumID a)
        makeTidalURL :: Int -> Text
        makeTidalURL tid =
          T.pack $ "https://listen.tidal.com/album/" ++ show tid

    ds <- case getTidal p of
      TidalFile fn -> FT.readTidalReleasesCache fn
      _ -> FT.readTidalReleases (getTidal p)
    let as = toAlbum <$> ds
        toAlbum r =
          Album
            (daid r)
            (dtitle r)
            (T.intercalate ", " $ dartists r)
            (dreleased r)
            (ttoCoverURL r)
            (dadded r)
            (fromEnum TTidal)
            (makeTidalURL (daid r))
            "Tidal"
            (Just (show (daid r)))
            Nothing
            Nothing
            (dtags r)
            0
            0

    putTextLn $ "Total # Tidal Albums: " <> show (length as)
    -- print $ drop (length as - 4) as

    pure $ V.fromList as
