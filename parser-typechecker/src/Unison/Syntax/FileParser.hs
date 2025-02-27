module Unison.Syntax.FileParser
  ( file,
  )
where

import Control.Lens
import Control.Monad.Reader (asks, local)
import Data.List qualified as List
import Data.Map qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as Text
import Text.Megaparsec qualified as P
import Unison.ABT qualified as ABT
import Unison.DataDeclaration (DataDeclaration, EffectDeclaration)
import Unison.DataDeclaration qualified as DD
import Unison.DataDeclaration qualified as DataDeclaration
import Unison.DataDeclaration.Records (generateRecordAccessors)
import Unison.Name qualified as Name
import Unison.NameSegment qualified as NameSegment
import Unison.Names qualified as Names
import Unison.Names.ResolutionResult qualified as Names
import Unison.NamesWithHistory qualified as Names
import Unison.Parser.Ann (Ann)
import Unison.Parser.Ann qualified as Ann
import Unison.Prelude
import Unison.Reference (TypeReferenceId)
import Unison.Syntax.DeclParser (declarations)
import Unison.Syntax.Lexer qualified as L
import Unison.Syntax.Name qualified as Name (toText, toVar, unsafeParseVar)
import Unison.Syntax.Parser
import Unison.Syntax.TermParser qualified as TermParser
import Unison.Syntax.Var qualified as Var (namespaced, namespaced2)
import Unison.Term (Term, Term2)
import Unison.Term qualified as Term
import Unison.Type (Type)
import Unison.Type qualified as Type
import Unison.UnisonFile (UnisonFile (..))
import Unison.UnisonFile.Env qualified as UF
import Unison.UnisonFile.Names qualified as UFN
import Unison.Util.List qualified as List
import Unison.Var (Var)
import Unison.Var qualified as Var
import Unison.WatchKind (WatchKind)
import Unison.WatchKind qualified as UF
import Prelude hiding (readFile)

resolutionFailures :: (Ord v) => [Names.ResolutionFailure v Ann] -> P v m x
resolutionFailures es = P.customFailure (ResolutionFailures es)

file :: forall m v. (Monad m, Var v) => P v m (UnisonFile v Ann)
file = do
  _ <- openBlock

  -- Parse an optional directive like "namespace foo.bar"
  maybeNamespace :: Maybe v <-
    optional (reserved "namespace") >>= \case
      Nothing -> pure Nothing
      Just _ -> Just . Name.toVar . L.payload <$> (importWordyId <|> importSymbolyId)

  -- The file may optionally contain top-level imports,
  -- which are parsed and applied to the type decls and term stanzas
  (namesStart, imports) <- TermParser.imports <* optional semi
  (dataDecls, effectDecls, parsedAccessors) <- declarations

  env <-
    let applyNamespaceToDecls :: forall decl. Iso' decl (DataDeclaration v Ann) -> Map v decl -> Map v decl
        applyNamespaceToDecls dataDeclL =
          case maybeNamespace of
            Nothing -> id
            Just namespace -> Map.fromList . map f . Map.toList
              where
                f :: (v, decl) -> (v, decl)
                f (declName, decl) =
                  ( Var.namespaced2 namespace declName,
                    review dataDeclL (applyNamespaceToDataDecl namespace unNamespacedTypeNames (view dataDeclL decl))
                  )

                unNamespacedTypeNames :: Set v
                unNamespacedTypeNames =
                  Set.union (Map.keysSet dataDecls) (Map.keysSet effectDecls)

        dataDecls1 = applyNamespaceToDecls id dataDecls
        effectDecls1 = applyNamespaceToDecls DataDeclaration.asDataDecl_ effectDecls
     in case UFN.environmentFor namesStart dataDecls1 effectDecls1 of
          Right (Right env) -> pure env
          Right (Left es) -> P.customFailure $ TypeDeclarationErrors es
          Left es -> resolutionFailures (toList es)
  let unNamespacedAccessors :: [(v, Ann, Term v Ann)]
      unNamespacedAccessors = do
        (typ, fields) <- parsedAccessors
        -- The parsed accessor has an un-namespaced type, so apply the namespace directive (if necessary) before
        -- looking up in the environment computed by `environmentFor`.
        let typ1 = maybe id Var.namespaced2 maybeNamespace (L.payload typ)
        Just (r, _) <- [Map.lookup typ1 (UF.datas env)]
        -- Generate the record accessors with *un-namespaced* names (passing `typ` rather than `typ1`) below, because we
        -- need to know these names in order to perform rewriting. As an example,
        --
        --   namespace foo
        --   type Bar = { baz : Nat }
        --   term = ... Bar.baz ...
        --
        -- we want to rename `Bar.baz` to `foo.Bar.baz`, and it seems easier to first generate un-namespaced accessors
        -- like `Bar.baz`, rather than rip off the namespace from accessors like `foo.Bar.baz` (though not by much).
        generateRecordAccessors Var.namespaced Ann.GeneratedFrom (toPair <$> fields) (L.payload typ) r
        where
          toPair (tok, typ) = (L.payload tok, ann tok <> ann typ)
  let accessors :: [(v, Ann, Term v Ann)]
      accessors =
        unNamespacedAccessors
          & case maybeNamespace of
            Nothing -> id
            Just namespace -> over (mapped . _1) (Var.namespaced2 namespace)
  let importNames = [(Name.unsafeParseVar v, Name.unsafeParseVar v2) | (v, v2) <- imports]
  let locals = Names.importing importNames (UF.names env)
  -- At this stage of the file parser, we've parsed all the type and ability
  -- declarations. The `push locals` here has the effect
  -- of making suffix-based name resolution prefer type and constructor names coming
  -- from the local file.
  --
  -- There's some more complicated logic below to have suffix-based name resolution
  -- make use of _terms_ from the local file.
  local (\e -> e {names = Names.push locals namesStart}) do
    names <- asks names
    stanzas <- do
      unNamespacedStanzas0 <- sepBy semi stanza
      let unNamespacedStanzas = fmap (TermParser.substImports names imports) <$> unNamespacedStanzas0
      pure $
        unNamespacedStanzas
          & case maybeNamespace of
            Nothing -> id
            Just namespace ->
              let unNamespacedTermNamespaceNames :: Set v
                  unNamespacedTermNamespaceNames =
                    Set.unions
                      [ -- The vars parsed from the stanzas themselves (before applying namespace directive)
                        Set.fromList (unNamespacedStanzas >>= getVars),
                        -- The un-namespaced constructor names (from the *originally-parsed* data and effect decls)
                        foldMap (Set.fromList . DataDeclaration.constructorVars) dataDecls,
                        foldMap (Set.fromList . DataDeclaration.constructorVars . DataDeclaration.toDataDecl) effectDecls,
                        -- The un-namespaced accessors
                        Set.fromList (map (view _1) unNamespacedAccessors)
                      ]
               in map (applyNamespaceToStanza namespace unNamespacedTermNamespaceNames)
    _ <- closeBlock
    let (termsr, watchesr) = foldl' go ([], []) stanzas
        go (terms, watches) s = case s of
          WatchBinding kind spanningAnn ((_, v), at) ->
            (terms, (kind, (v, spanningAnn, Term.generalizeTypeSignatures at)) : watches)
          WatchExpression kind guid spanningAnn at ->
            (terms, (kind, (Var.unnamedTest guid, spanningAnn, Term.generalizeTypeSignatures at)) : watches)
          Binding ((spanningAnn, v), at) -> ((v, spanningAnn, Term.generalizeTypeSignatures at) : terms, watches)
          Bindings bs -> ([(v, spanningAnn, Term.generalizeTypeSignatures at) | ((spanningAnn, v), at) <- bs] ++ terms, watches)
    let (terms, watches) = (reverse termsr, reverse watchesr)
        -- All locally declared term variables, running example:
        --   [foo.alice, bar.alice, zonk.bob]
        fqLocalTerms :: [v]
        fqLocalTerms = (stanzas >>= getVars) <> (view _1 <$> accessors)
    -- suffixified local term bindings shadow any same-named thing from the outer codebase scope
    -- example: `foo.bar` in local file scope will shadow `foo.bar` and `bar` in codebase scope
    let (curNames, resolveLocals) =
          ( Names.shadowTerms locals names,
            resolveLocals
          )
          where
            -- Each unique suffix mapped to its fully qualified name
            canonicalVars :: Map v v
            canonicalVars = UFN.variableCanonicalizer fqLocalTerms

            -- All unique local term name suffixes - these we want to
            -- avoid resolving to a term that's in the codebase
            locals :: [Name.Name]
            locals = (Name.unsafeParseVar <$> Map.keys canonicalVars)

            -- A function to replace unique local term suffixes with their
            -- fully qualified name
            replacements = [(v, Term.var () v2) | (v, v2) <- Map.toList canonicalVars, v /= v2]
            resolveLocals = ABT.substsInheritAnnotation replacements
    let bindNames = Term.bindSomeNames Name.unsafeParseVar (Set.fromList fqLocalTerms) curNames . resolveLocals
    terms <- case List.validate (traverseOf _3 bindNames) terms of
      Left es -> resolutionFailures (toList es)
      Right terms -> pure terms
    watches <- case List.validate (traverseOf (traversed . _3) bindNames) watches of
      Left es -> resolutionFailures (toList es)
      Right ws -> pure ws
    validateUnisonFile
      (UF.datasId env)
      (UF.effectsId env)
      (terms <> accessors)
      (List.multimap watches)

applyNamespaceToDataDecl :: forall a v. (Var v) => v -> Set v -> DataDeclaration v a -> DataDeclaration v a
applyNamespaceToDataDecl namespace locallyBoundTypes =
  over (DataDeclaration.constructors_ . mapped) \(ann, conName, conTy) ->
    (ann, Var.namespaced2 namespace conName, ABT.substsInheritAnnotation replacements conTy)
  where
    -- Replace var "Foo" with var "namespace.Foo"
    replacements :: [(v, Type v ())]
    replacements =
      locallyBoundTypes
        & Set.toList
        & map (\v -> (v, Type.var () (Var.namespaced2 namespace v)))

applyNamespaceToStanza ::
  forall a v.
  (Var v) =>
  v ->
  Set v ->
  Stanza v (Term v a) ->
  Stanza v (Term v a)
applyNamespaceToStanza namespace locallyBoundTerms = \case
  Binding x -> Binding (goBinding x)
  Bindings xs -> Bindings (map goBinding xs)
  WatchBinding wk ann x -> WatchBinding wk ann (goBinding x)
  WatchExpression wk guid ann term -> WatchExpression wk guid ann (goTerm term)
  where
    goBinding :: ((Ann, v), Term v a) -> ((Ann, v), Term v a)
    goBinding ((ann, name), term) =
      ((ann, Var.namespaced2 namespace name), goTerm term)

    goTerm :: Term v a -> Term v a
    goTerm =
      ABT.substsInheritAnnotation replacements

    replacements :: [(v, Term2 v a a v ())]
    replacements =
      locallyBoundTerms
        & Set.toList
        & map (\v -> (v, Term.var () (Var.namespaced2 namespace v)))

-- | Final validations and sanity checks to perform before finishing parsing.
validateUnisonFile ::
  (Ord v) =>
  Map v (TypeReferenceId, DataDeclaration v Ann) ->
  Map v (TypeReferenceId, EffectDeclaration v Ann) ->
  [(v, Ann, Term v Ann)] ->
  Map WatchKind [(v, Ann, Term v Ann)] ->
  P v m (UnisonFile v Ann)
validateUnisonFile datas effects terms watches =
  checkForDuplicateTermsAndConstructors datas effects terms watches

-- | Because types and abilities can introduce their own constructors and fields it's difficult
-- to detect all duplicate terms during parsing itself. Here we collect all terms and
-- constructors and verify that no duplicates exist in the file, triggering an error if needed.
checkForDuplicateTermsAndConstructors ::
  forall m v.
  (Ord v) =>
  Map v (TypeReferenceId, DataDeclaration v Ann) ->
  Map v (TypeReferenceId, EffectDeclaration v Ann) ->
  [(v, Ann, Term v Ann)] ->
  Map WatchKind [(v, Ann, Term v Ann)] ->
  P v m (UnisonFile v Ann)
checkForDuplicateTermsAndConstructors datas effects terms watches = do
  when (not . null $ duplicates) $ do
    let dupeList :: [(v, [Ann])]
        dupeList =
          duplicates
            & fmap Set.toList
            & Map.toList
    P.customFailure (DuplicateTermNames dupeList)
  pure
    UnisonFileId
      { dataDeclarationsId = datas,
        effectDeclarationsId = effects,
        terms = List.foldl (\acc (v, ann, term) -> Map.insert v (ann, term) acc) Map.empty terms,
        watches
      }
  where
    effectDecls :: [DataDeclaration v Ann]
    effectDecls = Map.elems . fmap (DD.toDataDecl . snd) $ effects
    dataDecls :: [DataDeclaration v Ann]
    dataDecls = fmap snd $ Map.elems datas
    allConstructors :: [(v, Ann)]
    allConstructors =
      (dataDecls <> effectDecls)
        & foldMap DD.constructors'
        & fmap (\(ann, v, _typ) -> (v, ann))
    allTerms :: [(v, Ann)]
    allTerms =
      map (\(v, ann, _term) -> (v, ann)) terms

    mergedTerms :: Map v (Set Ann)
    mergedTerms =
      (allConstructors <> allTerms)
        & (fmap . fmap) Set.singleton
        & Map.fromListWith Set.union
    duplicates :: Map v (Set Ann)
    duplicates =
      -- Any vars with multiple annotations are duplicates.
      Map.filter ((> 1) . Set.size) mergedTerms

-- A stanza is either a watch expression like:
--   > 1 + x
--   > z = x + 1
-- Or it is a binding like:
--   foo : Nat -> Nat
--   foo x = x + 42

data Stanza v term
  = WatchBinding UF.WatchKind Ann ((Ann, v), term)
  | WatchExpression UF.WatchKind Text Ann term
  | Binding ((Ann, v), term)
  | Bindings [((Ann, v), term)]
  deriving (Foldable, Traversable, Functor)

getVars :: (Var v) => Stanza v term -> [v]
getVars = \case
  WatchBinding _ _ ((_, v), _) -> [v]
  WatchExpression _ guid _ _ -> [Var.unnamedTest guid]
  Binding ((_, v), _) -> [v]
  Bindings bs -> [v | ((_, v), _) <- bs]

stanza :: (Monad m, Var v) => P v m (Stanza v (Term v Ann))
stanza = watchExpression <|> unexpectedAction <|> binding
  where
    unexpectedAction = failureIf (TermParser.blockTerm $> getErr) binding
    getErr = do
      t <- anyToken
      t2 <- optional anyToken
      P.customFailure $ DidntExpectExpression t t2
    watchExpression = do
      (kind, guid, ann) <- watched
      _ <- guardEmptyWatch ann
      msum
        [ TermParser.binding <&> (\trm@(((trmSpanAnn, _), _)) -> WatchBinding kind (ann <> trmSpanAnn) trm),
          TermParser.blockTerm <&> (\trm -> WatchExpression kind guid (ann <> ABT.annotation trm) trm)
        ]

    guardEmptyWatch ann =
      P.try $ do
        op <- optional (L.payload <$> P.lookAhead closeBlock)
        case op of
          Just () -> P.customFailure (EmptyWatch ann)
          _ -> pure ()

    -- binding :: forall v. Var v => P v ((Ann, v), Term v Ann)
    binding = do
      -- this logic converts
      --   {{ A doc }}  to   foo.doc = {{ A doc }}
      --   foo = 42          foo = 42
      doc <- P.optional (TermParser.doc2Block <* semi)
      binding@((_, v), _) <- TermParser.binding
      pure $ case doc of
        Nothing -> Binding binding
        Just (spanAnn, doc) -> Bindings [((spanAnn, Var.namespaced2 v (Var.named "doc")), doc), binding]

watched :: (Monad m, Var v) => P v m (UF.WatchKind, Text, Ann)
watched = P.try do
  kind <- (fmap . fmap . fmap) (Text.unpack . Name.toText) (optional importWordyId)
  guid <- uniqueName 10
  op <- optional (L.payload <$> P.lookAhead importSymbolyId)
  guard (op == Just (Name.fromSegment NameSegment.watchSegment))
  tok <- anyToken
  guard $ maybe True (`L.touches` tok) kind
  pure (maybe UF.RegularWatch L.payload kind, guid, maybe mempty ann kind <> ann tok)
