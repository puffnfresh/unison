-- | @pull@ input handler
module Unison.Codebase.Editor.HandleInput.Pull
  ( doPullRemoteBranch,
    importRemoteShareBranch,
    loadPropagateDiffDefaultPatch,
    mergeBranchAndPropagateDefaultPatch,
    propagatePatch,
  )
where

import Control.Concurrent.STM (atomically, modifyTVar', newTVarIO, readTVar, readTVarIO)
import Control.Lens
import Control.Monad.Reader (ask)
import qualified Data.List.NonEmpty as Nel
import qualified System.Console.Regions as Console.Regions
import Unison.Cli.Monad (Cli)
import qualified Unison.Cli.Monad as Cli
import qualified Unison.Cli.MonadUtils as Cli
import Unison.Cli.UnisonConfigUtils (resolveConfiguredUrl)
import Unison.Codebase (Preprocessing (..))
import qualified Unison.Codebase as Codebase
import Unison.Codebase.Branch (Branch (..))
import qualified Unison.Codebase.Branch as Branch
import qualified Unison.Codebase.Branch.Merge as Branch
import Unison.Codebase.Editor.HandleInput.AuthLogin (ensureAuthenticatedWithCodeserver)
import Unison.Codebase.Editor.HandleInput.NamespaceDiffUtils (diffHelper)
import Unison.Codebase.Editor.Input
import qualified Unison.Codebase.Editor.Input as Input
import Unison.Codebase.Editor.Output
import qualified Unison.Codebase.Editor.Output as Output
import Unison.Codebase.Editor.Output.PushPull (PushPull (Pull))
import qualified Unison.Codebase.Editor.Propagate as Propagate
import Unison.Codebase.Editor.RemoteRepo
  ( ReadRemoteNamespace (..),
    ReadShareRemoteNamespace (..),
    ShareUserHandle (..),
    writePathToRead,
  )
import qualified Unison.Codebase.Editor.RemoteRepo as RemoteRepo
import Unison.Codebase.Patch (Patch (..))
import Unison.Codebase.Path (Path' (..))
import qualified Unison.Codebase.Path as Path
import qualified Unison.Codebase.SyncMode as SyncMode
import qualified Unison.Codebase.Verbosity as Verbosity
import Unison.NameSegment (NameSegment (..))
import Unison.Prelude
import qualified Unison.Share.Codeserver as Codeserver
import qualified Unison.Share.Sync as Share
import qualified Unison.Share.Sync.Types as Share
import Unison.Share.Types (codeserverBaseURL)
import qualified Unison.Sync.Types as Share

doPullRemoteBranch ::
  Maybe ReadRemoteNamespace ->
  Path' ->
  SyncMode.SyncMode ->
  PullMode ->
  Verbosity.Verbosity ->
  Text ->
  Cli ()
doPullRemoteBranch mayRepo path syncMode pullMode verbosity description = do
  Cli.Env {codebase} <- ask
  let preprocess = case pullMode of
        Input.PullWithHistory -> Unmodified
        Input.PullWithoutHistory -> Preprocessed $ pure . Branch.discardHistory
  ns <- maybe (writePathToRead <$> resolveConfiguredUrl Pull path) pure mayRepo
  remoteBranch <- case ns of
    ReadRemoteNamespaceGit repo ->
      Cli.ioE (Codebase.importRemoteBranch codebase repo syncMode preprocess) \err ->
        Cli.returnEarly (Output.GitError err)
    ReadRemoteNamespaceShare repo -> importRemoteShareBranch repo
  when (Branch.isEmpty0 (Branch.head remoteBranch)) do
    Cli.respond (PulledEmptyBranch ns)
  let unchangedMsg = PullAlreadyUpToDate ns path
  destAbs <- Cli.resolvePath' path
  let printDiffPath = if Verbosity.isSilent verbosity then Nothing else Just path
  case pullMode of
    Input.PullWithHistory -> do
      destBranch <- Cli.getBranch0At destAbs
      if Branch.isEmpty0 destBranch
        then do
          void $ Cli.updateAtM description destAbs (const $ pure remoteBranch)
          Cli.respond $ MergeOverEmpty path
        else
          mergeBranchAndPropagateDefaultPatch
            Branch.RegularMerge
            description
            (Just unchangedMsg)
            remoteBranch
            printDiffPath
            destAbs
    Input.PullWithoutHistory -> do
      didUpdate <-
        Cli.updateAtM
          description
          destAbs
          (\destBranch -> pure $ remoteBranch `Branch.consBranchSnapshot` destBranch)
      Cli.respond
        if didUpdate
          then PullSuccessful ns path
          else unchangedMsg

importRemoteShareBranch :: ReadShareRemoteNamespace -> Cli (Branch IO)
importRemoteShareBranch rrn@(ReadShareRemoteNamespace {server, repo, path}) = do
  let codeserver = Codeserver.resolveCodeserver server
  let baseURL = codeserverBaseURL codeserver
  -- Auto-login to share if pulling from a non-public path
  when (not $ RemoteRepo.isPublic rrn) . void $ ensureAuthenticatedWithCodeserver codeserver
  let shareFlavoredPath = Share.Path (shareUserHandleToText repo Nel.:| coerce @[NameSegment] @[Text] (Path.toList path))
  Cli.Env {codebase} <- ask
  causalHash <-
    Cli.with withEntitiesDownloadedProgressCallback \downloadedCallback ->
      Share.pull baseURL shareFlavoredPath downloadedCallback & onLeftM \err0 ->
        (Cli.returnEarly . Output.ShareError) case err0 of
          Share.SyncError err -> Output.ShareErrorPull err
          Share.TransportError err -> Output.ShareErrorTransport err
  liftIO (Codebase.getBranchForHash codebase causalHash) & onNothingM do
    error $ reportBug "E412939" "`pull` \"succeeded\", but I can't find the result in the codebase. (This is a bug.)"
  where
    -- Provide the given action a callback that display to the terminal.
    withEntitiesDownloadedProgressCallback :: ((Int -> IO ()) -> IO a) -> IO a
    withEntitiesDownloadedProgressCallback action = do
      entitiesDownloadedVar <- newTVarIO 0
      Console.Regions.displayConsoleRegions do
        Console.Regions.withConsoleRegion Console.Regions.Linear \region -> do
          Console.Regions.setConsoleRegion region do
            entitiesDownloaded <- readTVar entitiesDownloadedVar
            pure $
              "\n  Downloaded "
                <> tShow entitiesDownloaded
                <> " entities...\n\n"
          result <- action (\n -> atomically (modifyTVar' entitiesDownloadedVar (+ n)))
          entitiesDownloaded <- readTVarIO entitiesDownloadedVar
          Console.Regions.finishConsoleRegion region $
            "\n  Downloaded " <> tShow entitiesDownloaded <> " entities."
          pure result

-- | supply `dest0` if you want to print diff messages
--   supply unchangedMessage if you want to display it if merge had no effect
mergeBranchAndPropagateDefaultPatch ::
  Branch.MergeMode ->
  Text ->
  Maybe Output ->
  Branch IO ->
  Maybe Path.Path' ->
  Path.Absolute ->
  Cli ()
mergeBranchAndPropagateDefaultPatch mode inputDescription unchangedMessage srcb maybeDest0 dest =
  ifM
    mergeBranch
    (loadPropagateDiffDefaultPatch inputDescription maybeDest0 dest)
    (for_ unchangedMessage Cli.respond)
  where
    mergeBranch :: Cli Bool
    mergeBranch =
      Cli.time "mergeBranch" do
        Cli.Env {codebase} <- ask
        destb <- Cli.getBranchAt dest
        merged <- liftIO (Branch.merge'' (Codebase.lca codebase) mode srcb destb)
        b <- Cli.updateAtM inputDescription dest (const $ pure merged)
        for_ maybeDest0 \dest0 -> do
          (ppe, diff) <- diffHelper (Branch.head destb) (Branch.head merged)
          Cli.respondNumbered (ShowDiffAfterMerge dest0 dest ppe diff)
        pure b

loadPropagateDiffDefaultPatch ::
  Text ->
  Maybe Path.Path' ->
  Path.Absolute ->
  Cli ()
loadPropagateDiffDefaultPatch inputDescription maybeDest0 dest = do
  Cli.time "loadPropagateDiffDefaultPatch" do
    original <- Cli.getBranch0At dest
    patch <- liftIO $ Branch.getPatch Cli.defaultPatchNameSegment original
    patchDidChange <- propagatePatch inputDescription patch dest
    when patchDidChange do
      whenJust maybeDest0 \dest0 -> do
        patched <- Cli.getBranchAt dest
        let patchPath = snoc dest0 Cli.defaultPatchNameSegment
        (ppe, diff) <- diffHelper original (Branch.head patched)
        Cli.respondNumbered (ShowDiffAfterMergePropagate dest0 dest patchPath ppe diff)

-- Returns True if the operation changed the namespace, False otherwise.
propagatePatch ::
  Text ->
  Patch ->
  Path.Absolute ->
  Cli Bool
propagatePatch inputDescription patch scopePath = do
  Cli.time "propagatePatch" do
    Cli.stepAt'
      (inputDescription <> " (applying patch)")
      (Path.unabsolute scopePath, Propagate.propagateAndApply patch)
