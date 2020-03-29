{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ViewPatterns #-}

module Unison.Codebase.FileCodebase
( getRootBranch        -- used by Git module
, branchHashesByPrefix -- used by Git module
, branchFromFiles      -- used by Git module
, codebase1  -- used by Main
, exists     -- used by Main
, initialize -- used by Main
-- todo: where are these used?
, decodeFileName
, encodeFileName
, codebasePath
, initCodebaseAndExit
, initCodebase
, getCodebaseOrExit
, getCodebaseDir
) where

import Unison.Prelude

import           UnliftIO                       ( MonadUnliftIO )
import           UnliftIO.Exception             ( catchIO )
import           UnliftIO.Concurrent            ( forkIO
                                                , killThread
                                                )
import           UnliftIO.STM                   ( atomically )
import qualified Data.Char                     as Char
import qualified Data.Hex                      as Hex
import           Data.List                      ( isSuffixOf, isPrefixOf )
import qualified Data.Set                      as Set
import qualified Data.Text                     as Text
import qualified Data.Text.IO                  as TextIO
import           Data.Text.Encoding             ( encodeUtf8
                                                , decodeUtf8
                                                )
import           UnliftIO.Directory             ( createDirectoryIfMissing
                                                , doesFileExist
                                                , doesDirectoryExist
                                                , listDirectory
                                                , removeFile
                                                , doesPathExist
                                                )
import           System.FilePath                ( FilePath
                                                , takeBaseName
                                                , takeFileName
                                                , takeDirectory
                                                , (</>)
                                                )
import           System.Directory               ( copyFile
                                                , getHomeDirectory
                                                , canonicalizePath
                                                )
import           System.Path                    ( replaceRoot
                                                , createDir
                                                , subDirs
                                                , files
                                                , dirPath
                                                )
import           System.Exit                    ( exitFailure, exitSuccess )
import qualified Unison.Codebase               as Codebase
import           Unison.Codebase                ( Codebase(Codebase)
                                                , BuiltinAnnotation
                                                )
import           Unison.Codebase.Causal         ( Causal
                                                , RawHash(..)
                                                )
import qualified Unison.Codebase.Causal        as Causal
import           Unison.Codebase.Branch         ( Branch(Branch) )
import qualified Unison.Codebase.Branch        as Branch
import qualified Unison.Codebase.Reflog        as Reflog
import qualified Unison.Codebase.Serialization as S
import qualified Unison.Codebase.Serialization.V1
                                               as V1

import           Unison.Codebase.Patch          ( Patch(..) )
import qualified Unison.Codebase.Watch         as Watch
import qualified Unison.DataDeclaration        as DD
import qualified Unison.Hash                   as Hash
import           Unison.Parser                  ( Ann(External) )
import           Unison.Reference               ( Reference )
import qualified Unison.Reference              as Reference
import           Unison.Referent                ( Referent
                                                , pattern Ref
                                                , pattern Con
                                                )
import qualified Unison.Referent               as Referent
import           Unison.Term                    ( Term )
import qualified Unison.Term                   as Term
import           Unison.Type                    ( Type )
import qualified Unison.Type                   as Type
import qualified Unison.Util.TQueue            as TQueue
import           Unison.Var                     ( Var )
import qualified Unison.UnisonFile             as UF
import qualified Unison.Util.Star3             as Star3
import qualified Unison.Util.Pretty            as P
import qualified Unison.Util.Relation          as Relation
import qualified Unison.PrettyTerminal         as PT
import           Unison.Symbol                  ( Symbol )
import Unison.Codebase.ShortBranchHash (ShortBranchHash(..))
import qualified Unison.Codebase.ShortBranchHash as SBH
import Unison.ShortHash (ShortHash)
import qualified Unison.ShortHash as SH
import qualified Unison.ConstructorType as CT
import Unison.Util.Monoid (foldMapM)
import Control.Error (rightMay, runExceptT, ExceptT(..))
import Control.Monad.State (StateT, MonadState)
import qualified Control.Monad.State           as State
import Control.Lens
import Unison.Util.Relation (Relation)
import qualified Unison.Util.Monoid as Monoid
import Data.Monoid.Generic -- (GenericSemigroup, GenericMonoid)

type CodebasePath = FilePath

data SyncedEntities = SyncedEntities
  { _syncedTerms    :: Set Reference.Id
  , _syncedDecls    :: Set Reference.Id
  , _syncedReferents :: Set Referent
  , _syncedEdits    :: Set Branch.EditHash
  , _syncDestExists :: Set FilePath
  } deriving Generic
  deriving Semigroup via GenericSemigroup SyncedEntities
  deriving Monoid via GenericMonoid SyncedEntities

makeLenses ''SyncedEntities

data Err
  = InvalidBranchFile FilePath String
  | InvalidEditsFile FilePath String
  | NoBranchHead FilePath
  | CantParseBranchHead FilePath
  | AmbiguouslyTypeAndTerm Reference.Id
  | UnknownTypeOrTerm Reference
  deriving Show

codebasePath :: FilePath
codebasePath = ".unison" </> "v1"

formatAnn :: S.Format Ann
formatAnn = S.Format (pure External) (\_ -> pure ())

initCodebaseAndExit :: Maybe FilePath -> IO ()
initCodebaseAndExit mdir = do
  dir <- getCodebaseDir mdir
  _ <- initCodebase dir
  exitSuccess

-- initializes a new codebase here (i.e. `ucm -codebase dir init`)
initCodebase :: FilePath -> IO (Codebase IO Symbol Ann)
initCodebase dir = do
  let path = dir </> codebasePath
  let theCodebase = codebase1 V1.formatSymbol formatAnn path
  prettyDir <- P.string <$> canonicalizePath dir

  whenM (exists path) $
    do PT.putPrettyLn'
         .  P.wrap
         $  "It looks like there's already a codebase in: "
         <> prettyDir
       exitFailure

  PT.putPrettyLn'
    .  P.wrap
    $  "Initializing a new codebase in: "
    <> prettyDir
  initialize path
  Codebase.initializeCodebase theCodebase
  pure theCodebase

-- get the codebase in dir, or in the home directory if not provided.
getCodebaseOrExit :: Maybe FilePath -> IO (Codebase IO Symbol Ann)
getCodebaseOrExit mdir = do
  dir <- getCodebaseDir mdir
  prettyDir <- P.string <$> canonicalizePath dir
  let errMsg = P.lines
        [ "No codebase exists in " <> prettyDir
        , "Run `ucm -codebase " <> prettyDir
          <> " init` to create one, then try again!"]
  let path = dir </> codebasePath
  let theCodebase = codebase1 V1.formatSymbol formatAnn path
  Codebase.initializeBuiltinCode theCodebase
  unlessM (exists path) $ do
    PT.putPrettyLn' errMsg
    exitFailure
  pure theCodebase

getCodebaseDir :: Maybe FilePath -> IO FilePath
getCodebaseDir mdir =
  case mdir of Just dir -> pure dir
               Nothing  -> getHomeDirectory

termsDir, typesDir, branchesDir, branchHeadDir, editsDir
  :: CodebasePath -> FilePath
termsDir root = root </> "terms"
typesDir root = root </> "types"
branchesDir root = root </> "paths"
branchHeadDir root = branchesDir root </> "_head"
editsDir root = root </> "patches"

termDir, declDir :: CodebasePath -> Reference.Id -> FilePath
termDir root r = termsDir root </> componentIdToString r
declDir root r = typesDir root </> componentIdToString r

referenceToDir :: Reference -> FilePath
referenceToDir r = case r of
  Reference.Builtin name -> "_builtin" </> encodeFileName (Text.unpack name)
  Reference.DerivedId hash -> componentIdToString hash

dependentsDir', typeIndexDir', typeMentionsIndexDir' :: FilePath -> FilePath

dependentsDir :: CodebasePath -> Reference -> FilePath
dependentsDir root r = dependentsDir' root </> referenceToDir r
dependentsDir' root = root </> "dependents"

watchesDir :: CodebasePath -> Text -> FilePath
watchesDir root UF.RegularWatch = root </> "watches" </> "_cache"
watchesDir root kind = root </> "watches" </> encodeFileName (Text.unpack kind)
watchPath :: CodebasePath -> UF.WatchKind -> Reference.Id -> FilePath
watchPath root kind id =
  watchesDir root (Text.pack kind) </> componentIdToString id <> ".ub"

typeIndexDir :: CodebasePath -> Reference -> FilePath
typeIndexDir root r = typeIndexDir' root </> referenceToDir r
typeIndexDir' root = root </> "type-index"

typeMentionsIndexDir :: CodebasePath -> Reference -> FilePath
typeMentionsIndexDir root r = typeMentionsIndexDir' root </> referenceToDir r
typeMentionsIndexDir' root = root </> "type-mentions-index"

-- todo: decodeFileName & encodeFileName shouldn't use base58; recommend $xFF$
decodeFileName :: FilePath -> String
decodeFileName = go where
  go ('$':tl) = case span (/= '$') tl of
    ("forward-slash", _:tl) -> '/' : go tl
    ("back-slash", _:tl) ->  '\\' : go tl
    ("colon", _:tl) -> ':' : go tl
    ("star", _:tl) -> '*' : go tl
    ("question-mark", _:tl) -> '?' : go tl
    ("double-quote", _:tl) -> '\"' : go tl
    ("less-than", _:tl) -> '<' : go tl
    ("greater-than", _:tl) -> '>' : go tl
    ("pipe", _:tl) -> '|' : go tl
    ('x':hex, _:tl) -> decodeHex hex ++ go tl
    ("",_:tl) -> '$' : go tl
    (s,_:tl) -> s ++ go tl
    (s,[]) -> s
  go (hd:tl) = hd : tl
  go [] = []
  decodeHex :: String -> String
  decodeHex s = maybe s (Text.unpack . decodeUtf8)
              . Hex.unhex . encodeUtf8 . Text.pack $ s

-- https://superuser.com/questions/358855/what-characters-are-safe-in-cross-platform-file-names-for-linux-windows-and-os
encodeFileName :: String -> FilePath
encodeFileName t = let
  go ('/' : rem) = "$forward-slash$" <> go rem
  go ('\\' : rem) = "$back-slash$" <> go rem
  go (':' : rem) = "$colon$" <> go rem
  go ('*' : rem) = "$star$" <> go rem
  go ('?' : rem) = "$question-mark$" <> go rem
  go ('"' : rem) = "$double-quote$" <> go rem
  go ('<' : rem) = "$less-than$" <> go rem
  go ('>' : rem) = "$greater-than$" <> go rem
  go ('|' : rem) = "$pipe$" <> go rem
  go ('$' : rem) = "$$" <> go rem
  go (c : rem) | not (Char.isPrint c && Char.isAscii c)
                 = "$x" <> encodeHex [c] <> "$" <> go rem
               | otherwise = c : go rem
  go [] = []
  encodeHex = Text.unpack . decodeUtf8 . Hex.hex . encodeUtf8 . Text.pack
  in if t == "." then "$dot$"
     else if t == ".." then "$dotdot$"
     else go t

termPath, typePath, declPath :: CodebasePath -> Reference.Id -> FilePath
termPath path r = termDir path r </> "compiled.ub"
typePath path r = termDir path r </> "type.ub"
declPath path r = declDir path r </> "compiled.ub"

branchPath :: CodebasePath -> Hash.Hash -> FilePath
branchPath root h = branchesDir root </> hashToString h ++ ".ub"

editsPath :: CodebasePath -> Hash.Hash -> FilePath
editsPath root h = editsDir root </> hashToString h ++ ".up"

reflogPath :: CodebasePath -> FilePath
reflogPath root = root </> "reflog"

touchIdFile :: MonadIO m => Reference.Id -> FilePath -> m ()
touchIdFile id fp =
  touchFile (fp </> encodeFileName (componentIdToString id))

touchReferentFile :: MonadIO m => Referent -> FilePath -> m ()
touchReferentFile id fp =
  touchFile (fp </> encodeFileName (referentToString id))

touchFile :: MonadIO m => FilePath -> m ()
touchFile fp = do
  createDirectoryIfMissing True (takeDirectory fp)
  liftIO $ writeFile fp ""

-- Relation Dependency Dependent, e.g. [(List.foldLeft, List.reverse)]
-- root / "dependents" / "_builtin" / Nat / yourFunction
loadDependentsDir ::
  MonadIO m => CodebasePath -> m (Relation Reference Reference.Id)
loadDependentsDir =
  loadIndex (Reference.idFromText . Text.pack) . dependentsDir'

-- todo: delete Show constraint
loadIndex :: forall m k. (MonadIO m, Ord k) => Show k
           => (String -> Maybe k) -> FilePath -> m (Relation Reference k)
loadIndex parseKey indexDir =
  listDirectory indexDir >>= Monoid.foldMapM loadDependency
  where
  loadDependency :: FilePath -> m (Relation Reference k)
  loadDependency b@"_builtin" = do
    listDirectory (indexDir </> b) >>= Monoid.foldMapM loadBuiltinDependency
    where
    loadBuiltinDependency :: FilePath -> m (Relation Reference k)
    loadBuiltinDependency path =
      loadDependentsOf
        (Reference.Builtin (Text.pack path))
        (indexDir </> b </> path)

  loadDependency path = case componentIdFromString path of
    Nothing -> pure mempty
    Just r ->
      loadDependentsOf (Reference.DerivedId r) (indexDir </> path)

  loadDependentsOf :: Reference -> FilePath -> m (Relation Reference k)
  loadDependentsOf r path = do
    listDirectory path <&>
      Relation.fromList . fmap (r,) . catMaybes . fmap parseKey

-- Relation Dependency Dependent, e.g. [(Set a -> List a, Set.toList)]
loadTypeIndexDir :: MonadIO m => CodebasePath -> m (Relation Reference Referent)
loadTypeIndexDir =
  loadIndex (Referent.fromText . Text.pack) . typeIndexDir'

-- Relation Dependency Dependent, e.g. [(Set, Set.toList), (List, Set.toList)]
loadTypeMentionsDir :: MonadIO m => CodebasePath -> m (Relation Reference Referent)
loadTypeMentionsDir =
  loadIndex (Referent.fromText . Text.pack) . typeMentionsIndexDir'

-- checks if `path` looks like a unison codebase
minimalCodebaseStructure :: CodebasePath -> [FilePath]
minimalCodebaseStructure root = [ branchHeadDir root ]

-- checks if a minimal codebase structure exists at `path`
exists :: MonadIO m => CodebasePath -> m Bool
exists root =
  and <$> traverse doesDirectoryExist (minimalCodebaseStructure root)

-- creates a minimal codebase structure at `path`
initialize :: CodebasePath -> IO ()
initialize path =
  traverse_ (createDirectoryIfMissing True) (minimalCodebaseStructure path)

branchFromFiles :: MonadIO m => FilePath -> Branch.Hash -> m (Maybe (Branch m))
branchFromFiles rootDir h@(RawHash h') = do
  fileExists <- doesFileExist (branchPath rootDir h')
  if fileExists then Just <$>
    Branch.read (deserializeRawBranch rootDir)
                (deserializeEdits rootDir)
                h
  else
    pure Nothing
 where
  deserializeRawBranch
    :: MonadIO m => CodebasePath -> Causal.Deserialize m Branch.Raw Branch.Raw
  deserializeRawBranch root (RawHash h) = do
    let ubf = branchPath root h
    liftIO (S.getFromFile' (V1.getCausal0 V1.getRawBranch) ubf) >>= \case
      Left  err -> failWith $ InvalidBranchFile ubf err
      Right c0  -> pure c0
  deserializeEdits :: MonadIO m => CodebasePath -> Branch.EditHash -> m Patch
  deserializeEdits root h =
    let file = editsPath root h
    in  liftIO (S.getFromFile' V1.getEdits file) >>= \case
          Left  err   -> failWith $ InvalidEditsFile file err
          Right edits -> pure edits

-- returns Nothing if `root` has no root branch (in `branchHeadDir root`)
getRootBranch :: forall m.
  MonadIO m => CodebasePath -> m (Either Codebase.GetRootBranchError (Branch m))
getRootBranch root =
  ifM (exists root)
    (liftIO (listDirectory $ branchHeadDir root) >>= go')
    (pure $ Left Codebase.NoRootBranch)
 where
  go' :: [String] -> m (Either Codebase.GetRootBranchError (Branch m))
  go' = \case
              []       -> pure $ Left Codebase.NoRootBranch
              [single] -> runExceptT $ go single
              conflict -> runExceptT (traverse go conflict) >>= \case
                Right (x : xs) -> Right <$> foldM Branch.merge x xs
                Right _ -> error "FileCodebase.getRootBranch.conflict can't be empty."
                Left e -> Left <$> pure e

  go :: String -> ExceptT Codebase.GetRootBranchError m (Branch m)
  go single = case hashFromString single of
    Nothing -> failWith $ CantParseBranchHead single
    Just (Branch.Hash -> h)  -> ExceptT $ branchFromFiles root h <&> \case
      Just b -> Right b
      Nothing -> Left $ Codebase.CouldntLoadRootBranch h

putRootBranch :: MonadIO m => CodebasePath -> Branch m -> m ()
putRootBranch root b = do
  Branch.sync (hashExists root)
              (serializeRawBranch root)
              (serializeEdits root)
              b
  updateCausalHead (branchHeadDir root) (Branch._history b)

hashExists :: MonadIO m => CodebasePath -> Branch.Hash -> m Bool
hashExists root (RawHash h) = liftIO $ doesFileExist (branchPath root h)

serializeRawBranch
  :: (MonadIO m) => CodebasePath -> Causal.Serialize m Branch.Raw Branch.Raw
serializeRawBranch root (RawHash h) = liftIO
  . S.putWithParentDirs (V1.putRawCausal V1.putRawBranch) (branchPath root h)

serializeEdits
  :: MonadIO m => CodebasePath -> Branch.EditHash -> m Patch -> m ()
serializeEdits root h medits =
  unlessM (liftIO $ doesFileExist (editsPath root h)) $ do
    edits <- medits
    liftIO $ S.putWithParentDirs V1.putEdits (editsPath root h) edits

-- `headDir` is like ".unison/branches/head", or ".unison/edits/head";
-- not ".unison"
updateCausalHead :: MonadIO m => FilePath -> Causal n h e -> m ()
updateCausalHead headDir c = do
  let (RawHash h) = Causal.currentHash c
      hs = hashToString h
  -- write new head
  touchFile (headDir </> hs)
  -- delete existing heads
  liftIO $ fmap (filter (/= hs)) (listDirectory headDir)
       >>= traverse_ (removeFile . (headDir </>))

-- here
hashFromString :: String -> Maybe Hash.Hash
hashFromString = Hash.fromBase32Hex . Text.pack

-- here
hashToString :: Hash.Hash -> String
hashToString = Hash.base32Hexs

hashFromFilePath :: FilePath -> Maybe Hash.Hash
hashFromFilePath = hashFromString . takeBaseName

-- here
componentIdToString :: Reference.Id -> String
componentIdToString = Text.unpack . Reference.toText . Reference.DerivedId

-- here
componentIdFromString :: String -> Maybe Reference.Id
componentIdFromString = Reference.idFromText . Text.pack

-- here
referentFromString :: String -> Maybe Referent
referentFromString = Referent.fromText . Text.pack

referentIdFromString :: String -> Maybe Referent.Id
referentIdFromString s = referentFromString s >>= \case
  Referent.Ref (Reference.DerivedId r) -> Just $ Referent.Ref' r
  Referent.Con (Reference.DerivedId r) i t -> Just $ Referent.Con' r i t
  _ -> Nothing

-- here
referentToString :: Referent -> String
referentToString = Text.unpack . Referent.toText

-- Adapted from
-- http://hackage.haskell.org/package/fsutils-0.1.2/docs/src/System-Path.html
copyDir :: (FilePath -> Bool) -> FilePath -> FilePath -> IO ()
copyDir predicate from to = do
  createDirectoryIfMissing True to
  -- createDir doesn't create a new directory on disk,
  -- it creates a description of an existing directory,
  -- and it crashes if `from` doesn't exist.
  d <- createDir from
  when (predicate $ dirPath d) $ do
    forM_ (subDirs d)
      $ \path -> copyDir predicate path (replaceRoot from to path)
    forM_ (files d) $ \path -> do
      exists <- doesFileExist to
      unless exists . copyFile path $ replaceRoot from to path

copyFromGit :: MonadIO m => FilePath -> FilePath -> m ()
copyFromGit to from = liftIO . whenM (doesDirectoryExist from) $
  copyDir (\x -> not ((".git" `isSuffixOf` x) || ("_head" `isSuffixOf` x)))
          from to

copyFileWithParents :: MonadIO m => FilePath -> FilePath -> m ()
copyFileWithParents src dest = liftIO $
  unlessM (doesFileExist dest) $ do
    createDirectoryIfMissing True (takeDirectory dest)
    copyFile src dest

type SimpleLens s a = Lens s s a a
copySyncToDirectory :: forall m
  . MonadUnliftIO m
  => FilePath
  -> FilePath
  -> Branch m
  -> m (Branch m)
copySyncToDirectory srcPath destPath branch =
  (`State.evalStateT` mempty) $ do
    b <- (liftIO . exists) destPath
    newRemoteRoot@(Branch c) <- lift $
      if b then
        -- we are merging the specified branch with the destination root;
        -- alternatives would be to replace the root, or leave it untouched,
        -- meaning this new data could be garbage-colleged
        getRootBranch destPath >>= \case
          -- todo: `fail` isn't great.
          Left Codebase.NoRootBranch ->
            fail $ "No root branch found in " ++ destPath
          Left (Codebase.CouldntLoadRootBranch h) ->
            fail $ "Couldn't find root branch " ++ show h ++ " in " ++ destPath
          Right existingDestRoot ->
            Branch.merge branch existingDestRoot
      else pure branch
    Branch.sync
      (hashExists destPath)
      serialize
      (\h _me -> copyEdits h)
      (Branch.transform lift newRemoteRoot)
    copyDependents @m <$> use syncedTerms <*> use syncedDecls
    copyTypeIndex @m <$> use syncedReferents
    copyTypeMentionsIndex @m <$> use syncedReferents
    updateCausalHead (branchHeadDir destPath) c
    pure branch
  where
  -- the terms and types we copied, we should transfer info about their dependencies
  copyDependents :: forall m. MonadIO m => Set Reference.Id -> Set Reference.Id -> m ()
  copyDependents terms types =
    copyIndexHelper
      loadDependentsDir
      (\k v -> touchIdFile v (dependentsDir destPath k))
      (terms <> types)
  copyTypeIndex :: forall m. MonadIO m => Set Referent -> m ()
  copyTypeIndex =
    copyIndexHelper
      loadTypeIndexDir
      (\k v -> touchReferentFile v (typeIndexDir destPath k))
  copyTypeMentionsIndex :: forall m. MonadIO m => Set Referent -> m ()
  copyTypeMentionsIndex =
    copyIndexHelper
      loadTypeMentionsDir
      (\k v -> touchReferentFile v (typeMentionsIndexDir destPath k))
  copyIndexHelper :: forall m d r. MonadIO m
                  => (Ord d, Ord r)
                  => (CodebasePath -> m (Relation d r))
                  -> (d -> r -> m ())
                  -> Set r
                  -> m ()
  copyIndexHelper loadIndex touchIndexFile neededSet = do
    available <- loadIndex srcPath
    let needed = Relation.restrictRan available neededSet
    traverse_ @[] @m (uncurry touchIndexFile) (Relation.toList needed)

  serialize :: Causal.Serialize (StateT SyncedEntities m) Branch.Raw Branch.Raw
  serialize rh rawBranch = unlessM (lift $ hashExists destPath rh) $ do
    writeBranch $ Causal.rawHead rawBranch
    lift $ serializeRawBranch destPath rh rawBranch
    where
    writeBranch :: Branch.Raw -> StateT SyncedEntities m ()
    writeBranch (Branch.Raw terms types _ _) = do
      -- Copy decls and enqueue Ids for dependents indexing
      for_ (toList $ Star3.fact types) $ \case
        Reference.DerivedId i -> copyDecl i
        Reference.Builtin{} -> pure ()
      -- Copy term definitions,
      -- enqueue term `Reference.Id`s for dependents indexing,
      -- and enqueue all referents for indexing
      for_ (toList $ Star3.fact terms) $ \r -> do
        case r of
          Ref (Reference.DerivedId i) -> copyTerm i
          Ref Reference.Builtin{} -> pure ()
          Con{} -> pure ()
        syncedReferents %= Set.insert r
    copyDecl :: Reference.Id -> StateT SyncedEntities m ()
    copyDecl = copyHelper syncedDecls declPath $
      \i -> copyFileWithParents (declPath srcPath i) (declPath destPath i)
    copyTerm :: Reference.Id -> StateT SyncedEntities m ()
    copyTerm = copyHelper syncedTerms termPath $
      \i -> do
        copyFileWithParents (termPath srcPath i) (termPath destPath i) -- compiled.ub
        copyFileWithParents (typePath srcPath i) (typePath destPath i) -- type.ub
        whenM (doesFileExist $ watchPath srcPath UF.TestWatch i) $
          copyFileWithParents (watchPath srcPath UF.TestWatch i)
                              (watchPath destPath UF.TestWatch i)
  copyEdits :: Branch.EditHash -> StateT SyncedEntities m ()
  copyEdits = copyHelper syncedEdits editsPath $
    \h -> copyFileWithParents (editsPath srcPath h) (editsPath destPath h)
  -- half-generic function to eliminate duplicated logic above
  copyHelper :: forall m h. (MonadIO m, MonadState SyncedEntities m, Ord h)
             => SimpleLens SyncedEntities (Set h)
             -> (FilePath -> h -> FilePath)
             -> (h -> m ())
             -> h
             -> m ()
  copyHelper l getFilename f h =
    let filePath = getFilename destPath h in
    unlessM (use (syncDestExists . to (Set.member filePath))) $
      ifM (doesFileExist (getFilename destPath h))
        (syncDestExists %= Set.insert filePath)
        (do f h; l %= Set.insert h; syncDestExists %= Set.insert filePath)


-- Create a codebase structure at `localPath` if none exists, and
-- copy (merge) all codebase elements from the current codebase into it.
_syncToDirectory
  :: forall m v a
   . (MonadUnliftIO m)
  => Var v
  => Codebase.BuiltinAnnotation a
  => S.Format v
  -> S.Format a
  -> Codebase m v a
  -> FilePath
  -> Branch m
  -> m (Branch m)
_syncToDirectory fmtV fmtA codebase localPath branch = do
  b <- (liftIO . exists) localPath
  if b then do
    let code = codebase1 fmtV fmtA localPath
    remoteRoot <- fromMaybe Branch.empty . rightMay <$> Codebase.getRootBranch code
    Branch.sync (hashExists localPath) serialize (serializeEdits localPath) branch
    merged <- Branch.merge branch remoteRoot
    Codebase.putRootBranch code merged
    pure merged
  else do
    Branch.sync (hashExists localPath) serialize (serializeEdits localPath) branch
    updateCausalHead (branchHeadDir localPath) $ Branch._history branch
    pure branch
 where
  serialize :: Causal.Serialize m Branch.Raw Branch.Raw
  serialize rh rawBranch = do
    writeBranch $ Causal.rawHead rawBranch
    serializeRawBranch localPath rh rawBranch
  calamity i =
    error
      $  "Calamity! Somebody deleted "
      <> show i
      <> " from the codebase while I wasn't looking."
  writeBranch :: Branch.Raw -> m ()
  writeBranch (Branch.Raw terms types _ _) = do
    for_ (toList $ Star3.fact types) $ \case
      Reference.DerivedId i -> do
        alreadyExists <- liftIO . doesPathExist $ declPath localPath i
        unless alreadyExists $ do
          mayDecl <- Codebase.getTypeDeclaration codebase i
          maybe (calamity i) (putDecl (S.put fmtV) (S.put fmtA) localPath i) mayDecl
      Reference.Builtin{} -> pure ()
    -- Write all terms
    for_ (toList $ Star3.fact terms) $ \case
      Ref r@(Reference.DerivedId i) -> do
        alreadyExists <- liftIO . doesPathExist $ termPath localPath i
        unless alreadyExists $ do
          mayTerm <- Codebase.getTerm codebase i
          mayType <- Codebase.getTypeOfTerm codebase r
          fromMaybe (calamity i)
                    (putTerm (S.put fmtV) (S.put fmtA) localPath i <$> mayTerm <*> mayType)
          -- If the term is a test, write the cached value too.
          mayTest <- Codebase.getWatch codebase UF.TestWatch i
          maybe (pure ()) (putWatch (S.put fmtV) (S.put fmtA) localPath UF.TestWatch i) mayTest
      Ref Reference.Builtin{} -> pure ()
      Con{} -> pure ()

putTerm
  :: MonadIO m
  => Var v
  => S.Put v
  -> S.Put a
  -> FilePath
  -> Reference.Id
  -> Term v a
  -> Type v a
  -> m ()
putTerm putV putA path h e typ = liftIO $ do
  let typeForIndexing = Type.removeAllEffectVars typ
      rootTypeHash = Type.toReference typeForIndexing
      typeMentions = Type.toReferenceMentions typeForIndexing
  S.putWithParentDirs (V1.putTerm putV putA) (termPath path h) e
  S.putWithParentDirs (V1.putType putV putA) (typePath path h) typ
  -- Add the term as a dependent of its dependencies
  let r = Referent.Ref (Reference.DerivedId h)
  let deps = deleteComponent h $ Term.dependencies e <> Type.dependencies typ
  traverse_ (touchIdFile h . dependentsDir path) deps
  traverse_ (touchReferentFile r . typeMentionsIndexDir path) typeMentions
  touchReferentFile r (typeIndexDir path rootTypeHash)

getDecl :: (MonadIO m, Ord v)
  => S.Get v -> S.Get a -> CodebasePath -> Reference.Id -> m (Maybe (DD.Decl v a))
getDecl getV getA root h = liftIO $
  S.getFromFile
    (V1.getEither (V1.getEffectDeclaration getV getA) (V1.getDataDeclaration getV getA))
    (declPath root h)

putDecl
  :: MonadIO m
  => Var v
  => S.Put v
  -> S.Put a
  -> FilePath
  -> Reference.Id
  -> DD.Decl v a
  -> m ()
putDecl putV putA path h decl = liftIO $ do
  S.putWithParentDirs
    (V1.putEither (V1.putEffectDeclaration putV putA)
                  (V1.putDataDeclaration putV putA)
    )
    (declPath path h)
    decl
  traverse_ (touchIdFile h . dependentsDir path) deps
  traverse_ addCtorToTypeIndex ctors
 where
  deps = deleteComponent h . DD.dependencies $ either DD.toDataDecl id decl
  r = Reference.DerivedId h
  decl' = either DD.toDataDecl id decl
  addCtorToTypeIndex (r, typ) = do
    let rootHash     = Type.toReference typ
        typeMentions = Type.toReferenceMentions typ
    touchReferentFile r (typeIndexDir path rootHash)
    traverse_ (touchReferentFile r . typeMentionsIndexDir path) typeMentions
  ct = DD.constructorType decl
  ctors =
    [ (Referent.Con r i ct, Type.removeAllEffectVars t)
    | (t,i) <- DD.constructorTypes decl' `zip` [0..] ]

putWatch
  :: MonadIO m
  => Var v
  => S.Put v
  -> S.Put a
  -> CodebasePath
  -> UF.WatchKind
  -> Reference.Id
  -> Term v a
  -> m ()
putWatch putV putA root k id e = liftIO $ S.putWithParentDirs
  (V1.putTerm putV putA)
  (watchPath root k id)
  e

loadReferencesByPrefix
  :: MonadIO m => FilePath -> ShortHash -> m (Set Reference.Id)
loadReferencesByPrefix dir sh = liftIO $ do
    refs <- mapMaybe Reference.fromShortHash
             . filter (SH.isPrefixOf sh)
             . mapMaybe SH.fromString
            <$> listDirectory dir
    pure $ Set.fromList [ i | Reference.DerivedId i <- refs]

termReferencesByPrefix, typeReferencesByPrefix
  :: MonadIO m => CodebasePath -> ShortHash -> m (Set Reference.Id)
termReferencesByPrefix root = loadReferencesByPrefix (termsDir root)
typeReferencesByPrefix root = loadReferencesByPrefix (typesDir root)

-- returns all the derived terms and derived constructors
termReferentsByPrefix :: MonadIO m
  => (CodebasePath -> Reference.Id -> m (Maybe (DD.Decl v a)))
  -> CodebasePath
  -> ShortHash
  -> m (Set Referent.Id)
termReferentsByPrefix getDecl root sh = do
  terms <- termReferencesByPrefix root sh
  ctors <- do
    types <- typeReferencesByPrefix root sh
    foldMapM collectCtors types
  pure (Set.map Referent.Ref' terms <> ctors)
  where
  -- load up the Decl for `ref` to see how many constructors it has,
  -- and what constructor type
  collectCtors ref = getDecl root ref <&> \case
    Nothing -> mempty
    Just decl ->
      Set.fromList [ Referent.Con' ref i ct
                   | i <- [0 .. ctorCount-1]]
      where ct = either (const CT.Effect) (const CT.Data) decl
            ctorCount = length . DD.constructors' $ DD.asDataDecl decl

branchHashesByPrefix :: MonadIO m => CodebasePath -> ShortBranchHash -> m (Set Branch.Hash)
branchHashesByPrefix codebasePath p =
  liftIO $ fmap (Set.fromList . join) . for [branchesDir] $ \f -> do
    let dir = f codebasePath
    paths <- filter (isPrefixOf . Text.unpack . SBH.toText $ p) <$> listDirectory dir
    let refs = paths >>= (toList . filenameToHash)
    pure refs
  where
    filenameToHash :: String -> Maybe Branch.Hash
    filenameToHash f = case Text.splitOn "." $ Text.pack f of
      [h, "ub"] -> Causal.RawHash <$> Hash.fromBase32Hex h
      _ -> Nothing

-- builds a `Codebase IO v a`, given serializers for `v` and `a`
codebase1
  :: forall m v a
   . MonadUnliftIO m
  => Var v
  => BuiltinAnnotation a
  => S.Format v -> S.Format a -> CodebasePath -> Codebase m v a
codebase1 _fmtV@(S.Format getV putV) _fmtA@(S.Format getA putA) path =
  let c =
        Codebase
          getTerm
          getTypeOfTerm
          (getDecl getV getA path)
          (putTerm putV putA path)
          (putDecl putV putA path)
          (getRootBranch path)
          (putRootBranch path)
          (branchHeadUpdates path)
          (branchFromFiles path)
          dependents
          -- Just copies all the files from a to-be-supplied path to `path`.
          (copyFromGit path)
--          (_syncToDirectory _fmtV _fmtA c)
          (copySyncToDirectory path)
          watches
          getWatch
          (putWatch putV putA path)
          getReflog
          appendReflog
          getTermsOfType
          getTermsMentioningType
   -- todo: maintain a trie of references to come up with this number
          (pure 10)
   -- The same trie can be used to make this lookup fast:
          (termReferencesByPrefix path)
          (typeReferencesByPrefix path)
          (termReferentsByPrefix (getDecl getV getA) path)
          (pure 10)
          (branchHashesByPrefix path)
   in c
  where
    getTerm h = liftIO $ S.getFromFile (V1.getTerm getV getA) (termPath path h)
    getTypeOfTerm h = liftIO $ S.getFromFile (V1.getType getV getA) (typePath path h)
    dependents :: Reference -> m (Set Reference.Id)
    dependents r = listDirAsIds (dependentsDir path r)
    getTermsOfType :: Reference -> m (Set Referent.Id)
    getTermsOfType r = listDirAsReferents (typeIndexDir path r)
    getTermsMentioningType :: Reference -> m (Set Referent.Id)
    getTermsMentioningType r = listDirAsReferents (typeMentionsIndexDir path r)
  -- todo: revisit these
    listDirAsIds :: FilePath -> m (Set Reference.Id)
    listDirAsIds d = do
      e <- doesDirectoryExist d
      if e
        then do
          ls <- fmap decodeFileName <$> listDirectory d
          pure . Set.fromList $ ls >>= (toList . componentIdFromString)
        else pure Set.empty
    listDirAsReferents :: FilePath -> m (Set Referent.Id)
    listDirAsReferents d = do
      e <- doesDirectoryExist d
      if e
        then do
          ls <- fmap decodeFileName <$> listDirectory d
          pure . Set.fromList $ ls >>= (toList . referentIdFromString)
        else pure Set.empty
    watches :: UF.WatchKind -> m [Reference.Id]
    watches k =
      liftIO $ do
        let wp = watchesDir path (Text.pack k)
        createDirectoryIfMissing True wp
        ls <- listDirectory wp
        pure $ ls >>= (toList . componentIdFromString . takeFileName)
    getWatch :: UF.WatchKind -> Reference.Id -> m (Maybe (Term v a))
    getWatch k id =
      liftIO $ do
        let wp = watchesDir path (Text.pack k)
        createDirectoryIfMissing True wp
        S.getFromFile (V1.getTerm getV getA) (wp </> componentIdToString id <> ".ub")
    getReflog :: m [Reflog.Entry]
    getReflog =
      liftIO
        (do contents <- TextIO.readFile (reflogPath path)
            let lines = Text.lines contents
            let entries = parseEntry <$> lines
            pure entries) `catchIO`
      const (pure [])
      where
        parseEntry t = fromMaybe (err t) (Reflog.fromText t)
        err t = error $
          "I couldn't understand this line in " ++ reflogPath path ++ "\n\n" ++
          Text.unpack t
    appendReflog :: Text -> Branch m -> Branch m -> m ()
    appendReflog reason old new =
      let
        t = Reflog.toText $
          Reflog.Entry (Branch.headHash old) (Branch.headHash new) reason
      in liftIO $ TextIO.appendFile (reflogPath path) (t <> "\n")

-- watches in `branchHeadDir root` for externally deposited heads;
-- parse them, and return them
branchHeadUpdates
  :: MonadUnliftIO m => CodebasePath -> m (m (), m (Set Branch.Hash))
branchHeadUpdates root = do
  branchHeadChanges      <- TQueue.newIO
  (cancelWatch, watcher) <- Watch.watchDirectory' (branchHeadDir root)
--  -- add .ubf file changes to intermediate queue
  watcher1               <-
    forkIO
    $ forever
    $ do
      -- Q: what does watcher return on a file deletion?
      -- A: nothing
        (filePath, _) <- watcher
        case hashFromFilePath filePath of
          Nothing -> failWith $ CantParseBranchHead filePath
          Just h ->
            atomically . TQueue.enqueue branchHeadChanges $ Branch.Hash h
  -- smooth out intermediate queue
  pure
    ( cancelWatch >> killThread watcher1
    , Set.fromList <$> Watch.collectUntilPause branchHeadChanges 400000
    )

failWith :: MonadIO m => Err -> m a
failWith = fail . show

deleteComponent :: Reference.Id -> Set Reference -> Set Reference
deleteComponent r rs = Set.difference rs
  (Reference.members . Reference.componentFor . Reference.DerivedId $ r)
