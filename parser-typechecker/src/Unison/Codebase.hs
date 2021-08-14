{-# LANGUAGE OverloadedStrings #-}

{-# LANGUAGE ViewPatterns #-}
module Unison.Codebase where

import Control.Lens ((%=), _1, _2)
import Control.Monad.Except (ExceptT (ExceptT), runExceptT)
import Control.Monad.State (State, evalState, get)
import Data.Bifunctor (bimap)
import Control.Error.Util (hush)
import Data.Maybe as Maybe
import Data.List as List
import qualified Data.Map as Map
import qualified Data.Set as Set
import qualified Unison.ABT as ABT
import qualified Unison.Builtin as Builtin
import qualified Unison.Builtin.Terms as Builtin
import Unison.Codebase.Branch (Branch)
import qualified Unison.Codebase.Branch as Branch
import qualified Unison.Codebase.CodeLookup as CL
import Unison.Codebase.Editor.Git (withStatus)
import Unison.Codebase.Editor.RemoteRepo (ReadRemoteNamespace, WriteRepo)
import Unison.Codebase.GitError (GitError)
import Unison.Codebase.Patch (Patch)
import qualified Unison.Codebase.Reflog as Reflog
import qualified U.Codebase.Reference as V2
import Unison.Codebase.ShortBranchHash (ShortBranchHash)
import qualified Unison.Codebase.SqliteCodebase.Conversions as Cv
import Unison.Codebase.SyncMode (SyncMode)
import Unison.DataDeclaration (Decl)
import qualified Unison.DataDeclaration as DD
import qualified Unison.Parser as Parser
import Unison.Prelude
import Unison.Reference (Reference)
import qualified Unison.Reference as Reference
import qualified Unison.Referent as Referent
import Unison.ShortHash (ShortHash)
import Unison.Symbol (Symbol)
import Unison.Term (Term)
import qualified Unison.Term as Term
import Unison.Type (Type)
import qualified Unison.Type as Type
import Unison.Typechecker.TypeLookup (TypeLookup (TypeLookup))
import qualified Unison.Typechecker.TypeLookup as TL
import qualified Unison.UnisonFile as UF
import qualified Unison.Util.Relation as Rel
import qualified Unison.Util.Set as Set
import U.Util.Timing (time)
import qualified U.Util.Type as TypeUtil
import Unison.Var (Var)
import qualified Unison.Var as Var
import UnliftIO.Directory (getHomeDirectory)
import qualified Unison.Codebase.GitError as GitError

type DataDeclaration v a = DD.DataDeclaration v a

type EffectDeclaration v a = DD.EffectDeclaration v a

-- | this FileCodebase detail lives here, because the interface depends on it 🙃
type CodebasePath = FilePath

type SyncToDir m =
  CodebasePath -> -- dest codebase
  SyncMode ->
  Branch m -> -- branch to sync to dest codebase
  m ()

-- | Abstract interface to a user's codebase.
--
-- One implementation is 'Unison.Codebase.FileCodebase' which uses the filesystem.
data Codebase m v a =
  Codebase { getTerm            :: Reference.Id -> m (Maybe (Term v a))
           , getTypeOfTermImpl  :: Reference.Id -> m (Maybe (Type v a))
           , getTypeDeclaration :: Reference.Id -> m (Maybe (Decl v a))

           , putTerm            :: Reference.Id -> Term v a -> Type v a -> m ()
           , putTypeDeclaration :: Reference.Id -> Decl v a -> m ()

           , getRootBranch      :: m (Either GetRootBranchError (Branch m))
           , putRootBranch        :: Branch m -> m ()
           , rootBranchUpdates    :: m (IO (), IO (Set Branch.Hash))
           , getBranchForHashImpl :: Branch.Hash -> m (Maybe (Branch m))
           , putBranch          :: Branch m -> m ()
           , branchExists       :: Branch.Hash -> m Bool

           , getPatch           :: Branch.EditHash -> m (Maybe Patch)
           , putPatch           :: Branch.EditHash -> Patch -> m ()
           , patchExists        :: Branch.EditHash -> m Bool

           , dependentsImpl     :: Reference -> m (Set Reference.Id)
           -- This copies all the dependencies of `b` from the specified Codebase into this one
           , syncFromDirectory  :: CodebasePath -> SyncMode -> Branch m -> m ()
           -- This copies all the dependencies of `b` from this Codebase
           , syncToDirectory    :: CodebasePath -> SyncMode -> Branch m -> m ()
           , viewRemoteBranch' :: ReadRemoteNamespace -> m (Either GitError (m (), Branch m, CodebasePath))
           , pushGitRootBranch :: Branch m -> WriteRepo -> SyncMode -> m (Either GitError ())

           -- Watch expressions are part of the codebase, the `Reference.Id` is
           -- the hash of the source of the watch expression, and the `Term v a`
           -- is the evaluated result of the expression, decompiled to a term.
           , watches            :: UF.WatchKind -> m [Reference.Id]
           , getWatch           :: UF.WatchKind -> Reference.Id -> m (Maybe (Term v a))
           , putWatch           :: UF.WatchKind -> Reference.Id -> Term v a -> m ()
           , clearWatches       :: m ()

           , getReflog          :: m [Reflog.Entry]
           , appendReflog       :: Text -> Branch m -> Branch m -> m ()

           -- list of terms of the given type
           , termsOfTypeImpl    :: Reference -> m (Set Referent.Id)
           -- list of terms that mention the given type anywhere in their signature
           , termsMentioningTypeImpl :: Reference -> m (Set Referent.Id)
           -- number of base58 characters needed to distinguish any two references in the codebase
           , hashLength         :: m Int
           , termReferencesByPrefix :: ShortHash -> m (Set Reference.Id)
           , typeReferencesByPrefix :: ShortHash -> m (Set Reference.Id)
           , termReferentsByPrefix :: ShortHash -> m (Set Referent.Id)

           , branchHashLength   :: m Int
           , branchHashesByPrefix :: ShortBranchHash -> m (Set Branch.Hash)

           -- returns `Nothing` to not implemented, fallback to in-memory
           --    also `Nothing` if no LCA
           -- The result is undefined if the two hashes are not in the codebase.
           -- Use `Codebase.lca` which wraps this in a nice API.
           , lcaImpl :: Maybe (Branch.Hash -> Branch.Hash -> m (Maybe Branch.Hash))

           -- `beforeImpl` returns `Nothing` if not implemented by the codebase
           -- `beforeImpl b1 b2` is undefined if `b2` not in the codebase
           --
           --  Use `Codebase.before` which wraps this in a nice API.
           , beforeImpl :: Maybe (Branch.Hash -> Branch.Hash -> m Bool)
           }

-- Attempt to find the Branch in the current codebase cache and root up to 3 levels deep
-- If not found, attempt to find it in the Codebase (sqlite)
getBranchForHash :: Monad m => Codebase m v a -> Branch.Hash -> m (Maybe (Branch m))
getBranchForHash codebase h = 
  let
    nestedChildrenForDepth depth b =
      if depth == 0 then []
      else
        b : (Map.elems (Branch._children (Branch.head b)) >>= nestedChildrenForDepth (depth - 1))

    headHashEq = (h ==) . Branch.headHash

    find rb = List.find headHashEq (nestedChildrenForDepth 3 rb)
  in do
  rootBranch <- hush <$> getRootBranch codebase
  case rootBranch of 
    Just rb -> maybe (getBranchForHashImpl codebase h) (pure . Just) (find rb)
    Nothing -> getBranchForHashImpl codebase h

lca :: Monad m => Codebase m v a -> Branch m -> Branch m -> m (Maybe (Branch m))
lca code b1@(Branch.headHash -> h1) b2@(Branch.headHash -> h2) = case lcaImpl code of
  Nothing -> Branch.lca b1 b2
  Just lca -> do
    eb1 <- branchExists code h1
    eb2 <- branchExists code h2
    if eb1 && eb2 then do
      lca h1 h2 >>= \case
        Just h -> getBranchForHash code h
        Nothing -> pure Nothing -- no common ancestor
    else Branch.lca b1 b2

before :: Monad m => Codebase m v a -> Branch m -> Branch m -> m Bool
before code b1 b2 = case beforeImpl code of
  Nothing -> Branch.before b1 b2
  Just before -> before' (branchExists code) before b1 b2

before' :: Monad m => (Branch.Hash -> m Bool) -> (Branch.Hash -> Branch.Hash -> m Bool) -> Branch m -> Branch m -> m Bool
before' branchExists before b1@(Branch.headHash -> h1) b2@(Branch.headHash -> h2) =
  ifM
    (branchExists h2)
    (ifM
      (branchExists h2)
      (before h1 h2)
      (pure False))
    (Branch.before b1 b2)


data GetRootBranchError
  = NoRootBranch
  | CouldntParseRootBranch String
  | CouldntLoadRootBranch Branch.Hash
  deriving Show

debug :: Bool
debug = False

data SyncFileCodebaseResult = SyncOk | UnknownDestinationRootBranch Branch.Hash | NotFastForward

getCodebaseDir :: MonadIO m => Maybe FilePath -> m FilePath
getCodebaseDir = maybe getHomeDirectory pure

-- | Write all of UCM's dependencies (builtins types and an empty namespace) into the codebase
installUcmDependencies :: forall m. Monad m => Codebase m Symbol Parser.Ann -> m ()
installUcmDependencies c = do
  let uf = (UF.typecheckedUnisonFile (Map.fromList Builtin.builtinDataDecls)
                                     (Map.fromList Builtin.builtinEffectDecls)
                                     [Builtin.builtinTermsSrc Parser.Intrinsic]
                                     mempty)
  addDefsToCodebase c uf

-- Feel free to refactor this to use some other type than TypecheckedUnisonFile
-- if it makes sense to later.
addDefsToCodebase :: forall m v a. (Monad m, Var v, Show a)
  => Codebase m v a -> UF.TypecheckedUnisonFile v a -> m ()
addDefsToCodebase c uf = do
  traverse_ (goType Right) (UF.dataDeclarationsId' uf)
  traverse_ (goType Left)  (UF.effectDeclarationsId' uf)
  -- put terms
  traverse_ goTerm (UF.hashTermsId uf)
  where
    goTerm t | debug && trace ("Codebase.addDefsToCodebase.goTerm " ++ show t) False = undefined
    goTerm (r, tm, tp) = putTerm c r tm tp
    goType :: Show t => (t -> Decl v a) -> (Reference.Id, t) -> m ()
    goType _f pair | debug && trace ("Codebase.addDefsToCodebase.goType " ++ show pair) False = undefined
    goType f (ref, decl) = putTypeDeclaration c ref (f decl)

getTypeOfConstructor ::
  (Monad m, Ord v) => Codebase m v a -> Reference -> Int -> m (Maybe (Type v a))
getTypeOfConstructor codebase (Reference.DerivedId r) cid = do
  maybeDecl <- getTypeDeclaration codebase r
  pure $ case maybeDecl of
    Nothing -> Nothing
    Just decl -> DD.typeOfConstructor (either DD.toDataDecl id decl) cid
getTypeOfConstructor _ r cid =
  error $ "Don't know how to getTypeOfConstructor " ++ show r ++ " " ++ show cid

lookupWatchCache :: (Monad m) => Codebase m v a -> Reference -> m (Maybe (Term v a))
lookupWatchCache codebase (Reference.DerivedId h) = do
  m1 <- getWatch codebase UF.RegularWatch h
  maybe (getWatch codebase UF.TestWatch h) (pure . Just) m1
lookupWatchCache _ Reference.Builtin{} = pure Nothing

typeLookupForDependencies
  :: (Monad m, Var v, BuiltinAnnotation a)
  => Codebase m v a -> Set Reference -> m (TL.TypeLookup v a)
typeLookupForDependencies codebase s = do
  when debug $ traceM $ "typeLookupForDependencies " ++ show s
  foldM go mempty s
 where
  go tl ref@(Reference.DerivedId id) = fmap (tl <>) $
    getTypeOfTerm codebase ref >>= \case
      Just typ -> pure $ TypeLookup (Map.singleton ref typ) mempty mempty
      Nothing  -> getTypeDeclaration codebase id >>= \case
        Just (Left ed) ->
          pure $ TypeLookup mempty mempty (Map.singleton ref ed)
        Just (Right dd) ->
          pure $ TypeLookup mempty (Map.singleton ref dd) mempty
        Nothing -> pure mempty
  go tl Reference.Builtin{} = pure tl -- codebase isn't consulted for builtins

-- todo: can this be implemented in terms of TransitiveClosure.transitiveClosure?
-- todo: add some tests on this guy?
transitiveDependencies
  :: (Monad m, Var v)
  => CL.CodeLookup v m a
  -> Set Reference.Id
  -> Reference.Id
  -> m (Set Reference.Id)
transitiveDependencies code seen0 rid = if Set.member rid seen0
  then pure seen0
  else
    let seen = Set.insert rid seen0
        getIds = Set.mapMaybe Reference.toId
    in CL.getTerm code rid >>= \case
      Just t ->
        foldM (transitiveDependencies code) seen (getIds $ Term.dependencies t)
      Nothing ->
        CL.getTypeDeclaration code rid >>= \case
          Nothing        -> pure seen
          Just (Left ed) -> foldM (transitiveDependencies code)
                                  seen
                                  (getIds $ DD.dependencies (DD.toDataDecl ed))
          Just (Right dd) -> foldM (transitiveDependencies code)
                                   seen
                                   (getIds $ DD.dependencies dd)

toCodeLookup :: Codebase m v a -> CL.CodeLookup v m a
toCodeLookup c = CL.CodeLookup (getTerm c) (getTypeDeclaration c)

-- Like the other `makeSelfContained`, but takes and returns a `UnisonFile`.
-- Any watches in the input `UnisonFile` will be watches in the returned
-- `UnisonFile`.
makeSelfContained'
  :: forall m v a . (Monad m, Monoid a, Var v)
  => CL.CodeLookup v m a
  -> UF.UnisonFile v a
  -> m (UF.UnisonFile v a)
makeSelfContained' code uf = do
  let UF.UnisonFileId ds0 es0 bs0 ws0 = uf
      deps0 = getIds . Term.dependencies . snd <$> (UF.allWatches uf <> bs0)
        where getIds = Set.mapMaybe Reference.toId
  -- transitive dependencies (from codebase) of all terms (including watches) in the UF
  deps <- foldM (transitiveDependencies code) Set.empty (Set.unions deps0)
  -- load all decls from deps list
  decls <- fmap catMaybes
         . forM (toList deps)
         $ \rid -> fmap (rid, ) <$> CL.getTypeDeclaration code rid
  -- partition the decls into effects and data
  let es1 :: [(Reference.Id, DD.EffectDeclaration v a)]
      ds1 :: [(Reference.Id, DD.DataDeclaration v a)]
      (es1, ds1) = partitionEithers [ bimap (r,) (r,) d | (r, d) <- decls ]
  -- load all terms from deps list
  bs1 <- fmap catMaybes
       . forM (toList deps)
       $ \rid -> fmap (rid, ) <$> CL.getTerm code rid
  let
    allVars :: Set v
    allVars = Set.unions
      [ UF.allVars uf
      , Set.unions [ DD.allVars dd | (_, dd) <- ds1 ]
      , Set.unions [ DD.allVars (DD.toDataDecl ed) | (_, ed) <- es1 ]
      , Set.unions [ Term.allVars tm | (_, tm) <- bs1 ]
      ]
    refVar :: Reference.Id -> State (Set v, Map Reference.Id v) v
    refVar r = do
      m <- snd <$> get
      case Map.lookup r m of
        Just v -> pure v
        Nothing -> do
          v <- ABT.freshenS' _1 (Var.refNamed (Reference.DerivedId r))
          _2 %=  Map.insert r v
          pure v
    assignVars :: [(Reference.Id, b)] -> State (Set v, Map Reference.Id v) [(v, (Reference.Id, b))]
    assignVars = traverse (\e@(r, _) -> (,e) <$> refVar r)
    unref :: Term v a -> State (Set v, Map Reference.Id v) (Term v a)
    unref = ABT.visit go where
      go t@(Term.Ref' (Reference.DerivedId r)) =
        Just (Term.var (ABT.annotation t) <$> refVar r)
      go _ = Nothing
    unrefb = traverse (\(v, tm) -> (v,) <$> unref tm)
    pair :: forall f a b. Applicative f => f a -> f b -> f (a,b)
    pair = liftA2 (,)
    uf' = flip evalState (allVars, Map.empty) $ do
      datas' <- Map.union ds0 . Map.fromList <$> assignVars ds1
      effects' <- Map.union es0 . Map.fromList <$> assignVars es1
      -- bs0 is terms from the input file
      bs0' <- unrefb bs0
      ws0' <- traverse unrefb ws0
      -- bs1 is dependency terms
      bs1' <- traverse (\(r, tm) -> refVar r `pair` unref tm) bs1
      pure $ UF.UnisonFileId datas' effects' (bs1' ++ bs0') ws0'
  pure uf'

getTypeOfTerm :: (Applicative m, Var v, BuiltinAnnotation a) =>
  Codebase m v a -> Reference -> m (Maybe (Type v a))
getTypeOfTerm _c r | debug && trace ("Codebase.getTypeOfTerm " ++ show r) False = undefined
getTypeOfTerm c r = case r of
  Reference.DerivedId h -> getTypeOfTermImpl c h
  r@Reference.Builtin{} ->
    pure $   fmap (const builtinAnnotation)
        <$> Map.lookup r Builtin.termRefTypes

getTypeOfReferent :: (BuiltinAnnotation a, Var v, Monad m)
                  => Codebase m v a -> Referent.Referent -> m (Maybe (Type v a))
getTypeOfReferent c (Referent.Ref r) = getTypeOfTerm c r
getTypeOfReferent c (Referent.Con r cid _) =
  getTypeOfConstructor c r cid

-- The dependents of a builtin type is the set of builtin terms which
-- mention that type.
dependents :: Functor m => Codebase m v a -> Reference -> m (Set Reference)
dependents c r
    = Set.union (Builtin.builtinTypeDependents r)
    . Set.map Reference.DerivedId
  <$> dependentsImpl c r

termsOfType :: (Var v, Monad m) => Codebase m v a -> Type v a -> m (Set Referent.Referent)
termsOfType c ty = do
  r <- Cv.reference2to1 (const (pure 0)) (TypeUtil.toReference (Cv.type1to2' Cv.reference1to2 ty))
  Set.union (Rel.lookupDom r Builtin.builtinTermsByType)
    . Set.map (fmap Reference.DerivedId)
    <$> termsOfTypeImpl c r

termsMentioningType :: (Var v, Functor m) => Codebase m v a -> Type v a -> m (Set Referent.Referent)
termsMentioningType c ty =
  Set.union (Rel.lookupDom r Builtin.builtinTermsByTypeMention)
    . Set.map (fmap Reference.DerivedId)
    <$> termsMentioningTypeImpl c r
  where
  r = Type.toReference ty

-- todo: could have a way to look this up just by checking for a file rather than loading it
isTerm :: (Applicative m, Var v, BuiltinAnnotation a)
       => Codebase m v a -> Reference -> m Bool
isTerm code = fmap isJust . getTypeOfTerm code

isType :: Applicative m => Codebase m v a -> Reference -> m Bool
isType c r = case r of
  Reference.Builtin{} -> pure $ Builtin.isBuiltinType r
  Reference.DerivedId r -> isJust <$> getTypeDeclaration c r

class BuiltinAnnotation a where
  builtinAnnotation :: a

instance BuiltinAnnotation Parser.Ann where
  builtinAnnotation = Parser.Intrinsic

-- * Git stuff

-- | Sync elements as needed from a remote codebase into the local one.
-- If `sbh` is supplied, we try to load the specified branch hash;
-- otherwise we try to load the root branch.
importRemoteBranch ::
  forall m v a.
  MonadIO m =>
  Codebase m v a ->
  ReadRemoteNamespace ->
  SyncMode ->
  m (Either GitError (Branch m))
importRemoteBranch codebase ns mode = runExceptT do
  (cleanup, branch, cacheDir) <- ExceptT $ viewRemoteBranch' codebase ns
  withStatus "Importing downloaded files into local codebase..." $
    time "SyncFromDirectory" $
      lift $ syncFromDirectory codebase cacheDir mode branch
  ExceptT
    let h = Branch.headHash branch
        err = Left $ GitError.CouldntLoadSyncedBranch h
    in time "load fresh local branch after sync" $
      (getBranchForHash codebase h <&> maybe err Right) <* cleanup

-- | Pull a git branch and view it from the cache, without syncing into the
-- local codebase.
viewRemoteBranch ::
  MonadIO m =>
  Codebase m v a ->
  ReadRemoteNamespace ->
  m (Either GitError (m (), Branch m))
viewRemoteBranch codebase ns = runExceptT do
  (cleanup, branch, _) <- ExceptT $ viewRemoteBranch' codebase ns
  pure (cleanup, branch)
