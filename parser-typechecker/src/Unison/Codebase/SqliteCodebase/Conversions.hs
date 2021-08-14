{-# LANGUAGE ViewPatterns #-}

module Unison.Codebase.SqliteCodebase.Conversions where

import Control.Monad (foldM)
import Data.Bifunctor (Bifunctor (bimap))
import Data.Bitraversable (Bitraversable (bitraverse))
import qualified Data.ByteString.Short as SBS
import Data.Either (fromRight)
import Data.Foldable (Foldable (toList))
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Set as Set
import Data.Text (Text, pack)
import qualified U.Codebase.Branch as V2.Branch
import qualified U.Codebase.Causal as V2
import qualified U.Codebase.Decl as V2.Decl
import qualified U.Codebase.HashTags as V2
import qualified U.Codebase.Kind as V2.Kind
import qualified U.Codebase.Reference as V2
import qualified U.Codebase.Reference as V2.Reference
import qualified U.Codebase.Referent as V2
import qualified U.Codebase.Referent as V2.Referent
import qualified U.Codebase.ShortHash as V2
import qualified U.Codebase.Sqlite.Symbol as V2
import qualified U.Codebase.Term as V2.Term
import qualified U.Codebase.TermEdit as V2.TermEdit
import qualified U.Codebase.Type as V2.Type
import qualified U.Codebase.TypeEdit as V2.TypeEdit
import qualified U.Codebase.WatchKind as V2
import qualified U.Codebase.WatchKind as V2.WatchKind
import qualified U.Core.ABT as V2.ABT
import qualified U.Util.Hash as V2
import qualified U.Util.Hash as V2.Hash
import qualified U.Util.Map as Map
import qualified U.Util.Set as Set
import qualified Unison.ABT as V1.ABT
import qualified Unison.Codebase.Branch as V1.Branch
import qualified Unison.Codebase.Causal as V1.Causal
import qualified Unison.Codebase.Metadata as V1.Metadata
import qualified Unison.Codebase.Patch as V1
import qualified Unison.Codebase.ShortBranchHash as V1
import qualified Unison.Codebase.TermEdit as V1.TermEdit
import qualified Unison.Codebase.TypeEdit as V1.TypeEdit
import qualified Unison.ConstructorType as CT
import qualified Unison.DataDeclaration as V1.Decl
import Unison.Hash (Hash)
import qualified Unison.Hash as V1
import qualified Unison.Kind as V1.Kind
import qualified Unison.NameSegment as V1
import Unison.Parser (Ann)
import qualified Unison.Parser as Ann
import qualified Unison.Pattern as V1.Pattern
import qualified Unison.Reference as V1
import qualified Unison.Reference as V1.Reference
import qualified Unison.Referent as V1
import qualified Unison.Referent as V1.Referent
import qualified Unison.Symbol as V1
import qualified Unison.Term as V1.Term
import qualified Unison.Type as V1.Type
import qualified Unison.Util.Relation as Relation
import qualified Unison.Util.Star3 as V1.Star3
import qualified Unison.Var as V1.Var
import qualified Unison.Var as Var

sbh1to2 :: V1.ShortBranchHash -> V2.ShortBranchHash
sbh1to2 (V1.ShortBranchHash b32) = V2.ShortBranchHash b32

decltype2to1 :: V2.Decl.DeclType -> CT.ConstructorType
decltype2to1 = \case
  V2.Decl.Data -> CT.Data
  V2.Decl.Effect -> CT.Effect

decltype1to2 :: CT.ConstructorType -> V2.Decl.DeclType
decltype1to2 = \case
  CT.Data -> V2.Decl.Data
  CT.Effect -> V2.Decl.Effect

watchKind1to2 :: V1.Var.WatchKind -> V2.WatchKind
watchKind1to2 = \case
  V1.Var.RegularWatch -> V2.WatchKind.RegularWatch
  V1.Var.TestWatch -> V2.WatchKind.TestWatch
  other -> error $ "What kind of watchkind is " ++ other ++ "?"

watchKind2to1 :: V2.WatchKind -> V1.Var.WatchKind
watchKind2to1 = \case
  V2.WatchKind.RegularWatch -> V1.Var.RegularWatch
  V2.WatchKind.TestWatch -> V1.Var.TestWatch

term1to2 :: Hash -> V1.Term.Term V1.Symbol Ann -> V2.Term.Term V2.Symbol
term1to2 h =
  V2.ABT.transform termF1to2
    . V2.ABT.vmap symbol1to2
    . V2.ABT.amap (const ())
    . abt1to2
  where
    termF1to2 :: V1.Term.F V1.Symbol Ann Ann a -> V2.Term.F V2.Symbol a
    termF1to2 = go
    go = \case
      V1.Term.Int i -> V2.Term.Int i
      V1.Term.Nat n -> V2.Term.Nat n
      V1.Term.Float f -> V2.Term.Float f
      V1.Term.Boolean b -> V2.Term.Boolean b
      V1.Term.Text t -> V2.Term.Text t
      V1.Term.Char c -> V2.Term.Char c
      V1.Term.Ref r -> V2.Term.Ref (rreference1to2 h r)
      V1.Term.Constructor r i -> V2.Term.Constructor (reference1to2 r) (fromIntegral i)
      V1.Term.Request r i -> V2.Term.Request (reference1to2 r) (fromIntegral i)
      V1.Term.Handle b h -> V2.Term.Handle b h
      V1.Term.App f a -> V2.Term.App f a
      V1.Term.Ann e t -> V2.Term.Ann e (ttype1to2 t)
      V1.Term.List as -> V2.Term.List as
      V1.Term.If c t f -> V2.Term.If c t f
      V1.Term.And a b -> V2.Term.And a b
      V1.Term.Or a b -> V2.Term.Or a b
      V1.Term.Lam a -> V2.Term.Lam a
      V1.Term.LetRec _ bs body -> V2.Term.LetRec bs body
      V1.Term.Let _ b body -> V2.Term.Let b body
      V1.Term.Match e cases -> V2.Term.Match e (goCase <$> cases)
      V1.Term.TermLink r -> V2.Term.TermLink (rreferent1to2 h r)
      V1.Term.TypeLink r -> V2.Term.TypeLink (reference1to2 r)
      V1.Term.Blank _ -> error "can't serialize term with blanks"
    goCase (V1.Term.MatchCase p g b) =
      V2.Term.MatchCase (goPat p) g b
    goPat :: V1.Pattern.Pattern a -> V2.Term.Pattern Text V2.Reference
    goPat = \case
      V1.Pattern.Unbound _ -> V2.Term.PUnbound
      V1.Pattern.Var _ -> V2.Term.PVar
      V1.Pattern.Boolean _ b -> V2.Term.PBoolean b
      V1.Pattern.Int _ i -> V2.Term.PInt i
      V1.Pattern.Nat _ n -> V2.Term.PNat n
      V1.Pattern.Float _ d -> V2.Term.PFloat d
      V1.Pattern.Text _ t -> V2.Term.PText t
      V1.Pattern.Char _ c -> V2.Term.PChar c
      V1.Pattern.Constructor _ r i ps ->
        V2.Term.PConstructor (reference1to2 r) i (goPat <$> ps)
      V1.Pattern.As _ p -> V2.Term.PAs (goPat p)
      V1.Pattern.EffectPure _ p -> V2.Term.PEffectPure (goPat p)
      V1.Pattern.EffectBind _ r i ps k ->
        V2.Term.PEffectBind (reference1to2 r) i (goPat <$> ps) (goPat k)
      V1.Pattern.SequenceLiteral _ ps -> V2.Term.PSequenceLiteral (goPat <$> ps)
      V1.Pattern.SequenceOp _ p op p2 ->
        V2.Term.PSequenceOp (goPat p) (goSeqOp op) (goPat p2)
    goSeqOp = \case
      V1.Pattern.Cons -> V2.Term.PCons
      V1.Pattern.Snoc -> V2.Term.PSnoc
      V1.Pattern.Concat -> V2.Term.PConcat

term2to1 :: forall m. Monad m => Hash -> (Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Term.Term V2.Symbol -> m (V1.Term.Term V1.Symbol Ann)
term2to1 h lookupSize lookupCT tm =
  V1.ABT.transformM (termF2to1 h lookupSize lookupCT)
    . V1.ABT.vmap symbol2to1
    . V1.ABT.amap (const Ann.External)
    $ abt2to1 tm
  where
    termF2to1 :: forall m a. Monad m => Hash -> (Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Term.F V2.Symbol a -> m (V1.Term.F V1.Symbol Ann Ann a)
    termF2to1 h lookupSize lookupCT = go
      where
        go :: V2.Term.F V2.Symbol a -> m (V1.Term.F V1.Symbol Ann Ann a)
        go = \case
          V2.Term.Int i -> pure $ V1.Term.Int i
          V2.Term.Nat n -> pure $ V1.Term.Nat n
          V2.Term.Float d -> pure $ V1.Term.Float d
          V2.Term.Boolean b -> pure $ V1.Term.Boolean b
          V2.Term.Text t -> pure $ V1.Term.Text t
          V2.Term.Char c -> pure $ V1.Term.Char c
          V2.Term.Ref r -> V1.Term.Ref <$> rreference2to1 h lookupSize r
          V2.Term.Constructor r i ->
            V1.Term.Constructor <$> reference2to1 lookupSize r <*> pure (fromIntegral i)
          V2.Term.Request r i ->
            V1.Term.Request <$> reference2to1 lookupSize r <*> pure (fromIntegral i)
          V2.Term.Handle a a4 -> pure $ V1.Term.Handle a a4
          V2.Term.App a a4 -> pure $ V1.Term.App a a4
          V2.Term.Ann a t2 -> V1.Term.Ann a <$> ttype2to1 lookupSize t2
          V2.Term.List sa -> pure $ V1.Term.List sa
          V2.Term.If a a4 a5 -> pure $ V1.Term.If a a4 a5
          V2.Term.And a a4 -> pure $ V1.Term.And a a4
          V2.Term.Or a a4 -> pure $ V1.Term.Or a a4
          V2.Term.Lam a -> pure $ V1.Term.Lam a
          V2.Term.LetRec as a -> pure $ V1.Term.LetRec False as a
          V2.Term.Let a a4 -> pure $ V1.Term.Let False a a4
          V2.Term.Match a cases -> V1.Term.Match a <$> traverse goCase cases
          V2.Term.TermLink rr -> V1.Term.TermLink <$> rreferent2to1 h lookupSize lookupCT rr
          V2.Term.TypeLink r -> V1.Term.TypeLink <$> reference2to1 lookupSize r
        goCase = \case
          V2.Term.MatchCase pat cond body ->
            V1.Term.MatchCase <$> (goPat pat) <*> pure cond <*> pure body
        goPat = \case
          V2.Term.PUnbound -> pure $ V1.Pattern.Unbound a
          V2.Term.PVar -> pure $ V1.Pattern.Var a
          V2.Term.PBoolean b -> pure $ V1.Pattern.Boolean a b
          V2.Term.PInt i -> pure $ V1.Pattern.Int a i
          V2.Term.PNat n -> pure $ V1.Pattern.Nat a n
          V2.Term.PFloat d -> pure $ V1.Pattern.Float a d
          V2.Term.PText t -> pure $ V1.Pattern.Text a t
          V2.Term.PChar c -> pure $ V1.Pattern.Char a c
          V2.Term.PConstructor r i ps ->
            V1.Pattern.Constructor a <$> reference2to1 lookupSize r <*> pure i <*> (traverse goPat ps)
          V2.Term.PAs p -> V1.Pattern.As a <$> goPat p
          V2.Term.PEffectPure p -> V1.Pattern.EffectPure a <$> goPat p
          V2.Term.PEffectBind r i ps p -> V1.Pattern.EffectBind a <$> reference2to1 lookupSize r <*> pure i <*> traverse goPat ps <*> goPat p
          V2.Term.PSequenceLiteral ps -> V1.Pattern.SequenceLiteral a <$> traverse goPat ps
          V2.Term.PSequenceOp p1 op p2 -> V1.Pattern.SequenceOp a <$> goPat p1 <*> pure (goOp op) <*> goPat p2
        goOp = \case
          V2.Term.PCons -> V1.Pattern.Cons
          V2.Term.PSnoc -> V1.Pattern.Snoc
          V2.Term.PConcat -> V1.Pattern.Concat
        a = Ann.External

decl2to1 :: Monad m => Hash -> (Hash -> m V1.Reference.Size) -> V2.Decl.Decl V2.Symbol -> m (V1.Decl.Decl V1.Symbol Ann)
decl2to1 h lookupSize (V2.Decl.DataDeclaration dt m bound cts) =
  goCT dt
    <$> V1.Decl.DataDeclaration (goMod m) Ann.External (symbol2to1 <$> bound)
    <$> cts'
  where
    goMod = \case
      V2.Decl.Structural -> V1.Decl.Structural
      V2.Decl.Unique t -> V1.Decl.Unique t
    goCT = \case
      V2.Decl.Data -> Right
      V2.Decl.Effect -> Left . V1.Decl.EffectDeclaration
    cts' = traverse mkCtor (zip cts [0 ..])
    mkCtor (type1, i) = do
      type2 <- dtype2to1 h lookupSize type1
      pure $ (Ann.External, V1.symbol . pack $ "Constructor" ++ show i, type2)

decl1to2 :: Hash -> V1.Decl.Decl V1.Symbol a -> V2.Decl.Decl V2.Symbol
decl1to2 h decl1 = case V1.Decl.asDataDecl decl1 of
  V1.Decl.DataDeclaration m _ann bound cts ->
    V2.Decl.DataDeclaration
      (decltype1to2 $ V1.Decl.constructorType decl1)
      (goMod m)
      (symbol1to2 <$> bound)
      cts'
    where
      goMod = \case
        V1.Decl.Structural -> V2.Decl.Structural
        V1.Decl.Unique t -> V2.Decl.Unique t
      cts' = [dtype1to2 h t | (_, _, t) <- cts]

symbol2to1 :: V2.Symbol -> V1.Symbol
symbol2to1 (V2.Symbol i t) = V1.Symbol i (Var.User t)

symbol1to2 :: V1.Symbol -> V2.Symbol
symbol1to2 (V1.Symbol i varType) = V2.Symbol i (Var.rawName varType)

shortHashSuffix1to2 :: Text -> V1.Reference.Pos
shortHashSuffix1to2 =
  fst
    . fromRight (error "todo: move suffix parsing to frontend")
    . V1.Reference.readSuffix

abt2to1 :: Functor f => V2.ABT.Term f v a -> V1.ABT.Term f v a
abt2to1 (V2.ABT.Term fv a out) = V1.ABT.Term fv a (go out)
  where
    go = \case
      V2.ABT.Cycle body -> V1.ABT.Cycle (abt2to1 body)
      V2.ABT.Abs v body -> V1.ABT.Abs v (abt2to1 body)
      V2.ABT.Var v -> V1.ABT.Var v
      V2.ABT.Tm tm -> V1.ABT.Tm (abt2to1 <$> tm)

abt1to2 :: Functor f => V1.ABT.Term f v a -> V2.ABT.Term f v a
abt1to2 (V1.ABT.Term fv a out) = V2.ABT.Term fv a (go out)
  where
    go = \case
      V1.ABT.Cycle body -> V2.ABT.Cycle (abt1to2 body)
      V1.ABT.Abs v body -> V2.ABT.Abs v (abt1to2 body)
      V1.ABT.Var v -> V2.ABT.Var v
      V1.ABT.Tm tm -> V2.ABT.Tm (abt1to2 <$> tm)

rreference2to1 :: Applicative m => Hash -> (Hash -> m V1.Reference.Size) -> V2.Reference' Text (Maybe V2.Hash) -> m V1.Reference
rreference2to1 h lookupSize = \case
  V2.ReferenceBuiltin t -> pure $ V1.Reference.Builtin t
  V2.ReferenceDerived i -> V1.Reference.DerivedId <$> rreferenceid2to1 h lookupSize i

rreference1to2 :: Hash -> V1.Reference -> V2.Reference' Text (Maybe V2.Hash)
rreference1to2 h = \case
  V1.Reference.Builtin t -> V2.ReferenceBuiltin t
  V1.Reference.DerivedId i -> V2.ReferenceDerived (rreferenceid1to2 h i)

rreferenceid2to1 :: Functor m => Hash -> (Hash -> m V1.Reference.Size) -> V2.Reference.Id' (Maybe V2.Hash) -> m V1.Reference.Id
rreferenceid2to1 h lookupSize (V2.Reference.Id oh i) =
  V1.Reference.Id h' i <$> lookupSize h'
  where
    h' = maybe h hash2to1 oh

rreferenceid1to2 :: Hash -> V1.Reference.Id -> V2.Reference.Id' (Maybe V2.Hash)
rreferenceid1to2 h (V1.Reference.Id h' i _n) = V2.Reference.Id oh i
  where
    oh = if h == h' then Nothing else Just (hash1to2 h')

hash1to2 :: Hash -> V2.Hash
hash1to2 (V1.Hash bs) = V2.Hash.Hash (SBS.toShort bs)

branchHash1to2 :: V1.Branch.Hash -> V2.CausalHash
branchHash1to2 = V2.CausalHash . hash1to2 . V1.Causal.unRawHash

branchHash2to1 :: V2.CausalHash -> V1.Branch.Hash
branchHash2to1 = V1.Causal.RawHash . hash2to1 . V2.unCausalHash

patchHash1to2 :: V1.Branch.EditHash -> V2.PatchHash
patchHash1to2 = V2.PatchHash . hash1to2

reference2to1 :: Applicative m => (Hash -> m V1.Reference.Size) -> V2.Reference -> m V1.Reference
reference2to1 lookupSize = \case
  V2.ReferenceBuiltin t -> pure $ V1.Reference.Builtin t
  V2.ReferenceDerived i -> V1.Reference.DerivedId <$> referenceid2to1 lookupSize i

reference1to2 :: V1.Reference -> V2.Reference
reference1to2 = \case
  V1.Reference.Builtin t -> V2.ReferenceBuiltin t
  V1.Reference.DerivedId i -> V2.ReferenceDerived (referenceid1to2 i)

referenceid1to2 :: V1.Reference.Id -> V2.Reference.Id
referenceid1to2 (V1.Reference.Id h i _n) = V2.Reference.Id (hash1to2 h) i

referenceid2to1 :: Functor m => (Hash -> m V1.Reference.Size) -> V2.Reference.Id -> m V1.Reference.Id
referenceid2to1 lookupSize (V2.Reference.Id h i) =
  V1.Reference.Id sh i <$> lookupSize sh
  where
    sh = hash2to1 h

rreferent2to1 :: Applicative m => Hash -> (Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.ReferentH -> m V1.Referent
rreferent2to1 h lookupSize lookupCT = \case
  V2.Ref r -> V1.Ref <$> rreference2to1 h lookupSize r
  V2.Con r i -> V1.Con <$> reference2to1 lookupSize r <*> pure (fromIntegral i) <*> lookupCT r

rreferent1to2 :: Hash -> V1.Referent -> V2.ReferentH
rreferent1to2 h = \case
  V1.Ref r -> V2.Ref (rreference1to2 h r)
  V1.Con r i _ct -> V2.Con (reference1to2 r) (fromIntegral i)

referent2to1 :: Applicative m => (Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Referent -> m V1.Referent
referent2to1 lookupSize lookupCT = \case
  V2.Ref r -> V1.Ref <$> reference2to1 lookupSize r
  V2.Con r i -> V1.Con <$> reference2to1 lookupSize r <*> pure (fromIntegral i) <*> lookupCT r

referent1to2 :: V1.Referent -> V2.Referent
referent1to2 = \case
  V1.Ref r -> V2.Ref $ reference1to2 r
  V1.Con r i _ct -> V2.Con (reference1to2 r) (fromIntegral i)

referentid2to1 :: Applicative m => (Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Referent.Id -> m V1.Referent.Id
referentid2to1 lookupSize lookupCT = \case
  V2.RefId r -> V1.Ref' <$> referenceid2to1 lookupSize r
  V2.ConId r i ->
    V1.Con' <$> referenceid2to1 lookupSize r
      <*> pure (fromIntegral i)
      <*> lookupCT (V2.ReferenceDerived r)

hash2to1 :: V2.Hash.Hash -> Hash
hash2to1 (V2.Hash.Hash sbs) = V1.Hash (SBS.fromShort sbs)

causalHash2to1 :: V2.CausalHash -> V1.Causal.RawHash V1.Branch.Raw
causalHash2to1 = V1.Causal.RawHash . hash2to1 . V2.unCausalHash

causalHash1to2 :: V1.Causal.RawHash V1.Branch.Raw -> V2.CausalHash
causalHash1to2 =  V2.CausalHash . hash1to2 . V1.Causal.unRawHash

ttype2to1 :: Monad m => (Hash -> m V1.Reference.Size) -> V2.Term.Type V2.Symbol -> m (V1.Type.Type V1.Symbol Ann)
ttype2to1 lookupSize = type2to1' (reference2to1 lookupSize)

dtype2to1 :: Monad m => Hash -> (Hash -> m V1.Reference.Size) -> V2.Decl.Type V2.Symbol -> m (V1.Type.Type V1.Symbol Ann)
dtype2to1 h lookupSize = type2to1' (rreference2to1 h lookupSize)

type2to1' :: Monad m => (r -> m V1.Reference) -> V2.Type.TypeR r V2.Symbol -> m (V1.Type.Type V1.Symbol Ann)
type2to1' convertRef =
  V1.ABT.transformM (typeF2to1 convertRef)
    . V1.ABT.vmap symbol2to1
    . V1.ABT.amap (const Ann.External)
    . abt2to1
  where
    typeF2to1 :: Applicative m => (r -> m V1.Reference) -> V2.Type.F' r a -> m (V1.Type.F a)
    typeF2to1 convertRef = \case
      V2.Type.Ref r -> V1.Type.Ref <$> convertRef r
      V2.Type.Arrow i o -> pure $ V1.Type.Arrow i o
      V2.Type.Ann a k -> pure $ V1.Type.Ann a (convertKind k)
      V2.Type.App f x -> pure $ V1.Type.App f x
      V2.Type.Effect e b -> pure $ V1.Type.Effect e b
      V2.Type.Effects as -> pure $ V1.Type.Effects as
      V2.Type.Forall a -> pure $ V1.Type.Forall a
      V2.Type.IntroOuter a -> pure $ V1.Type.IntroOuter a
      where
        convertKind = \case
          V2.Kind.Star -> V1.Kind.Star
          V2.Kind.Arrow i o -> V1.Kind.Arrow (convertKind i) (convertKind o)

dtype1to2 :: Hash -> V1.Type.Type V1.Symbol a -> V2.Type.TypeD V2.Symbol
dtype1to2 h = V2.ABT.vmap symbol1to2 . type1to2' (rreference1to2 h)

ttype1to2 :: V1.Type.Type V1.Symbol a -> V2.Type.TypeT V2.Symbol
ttype1to2 = V2.ABT.vmap symbol1to2 . type1to2' reference1to2

type1to2' :: Ord v => (V1.Reference -> r) -> V1.Type.Type v a -> V2.Type.TypeR r v
type1to2' convertRef =
  V2.ABT.transform (typeF1to2' convertRef)
    . V2.ABT.amap (const ())
    . abt1to2
  where
    typeF1to2' :: (V1.Reference -> r) -> V1.Type.F a -> V2.Type.F' r a
    typeF1to2' convertRef = \case
      V1.Type.Ref r -> V2.Type.Ref (convertRef r)
      V1.Type.Arrow i o -> V2.Type.Arrow i o
      V1.Type.Ann a k -> V2.Type.Ann a (convertKind k)
      V1.Type.App f x -> V2.Type.App f x
      V1.Type.Effect e b -> V2.Type.Effect e b
      V1.Type.Effects as -> V2.Type.Effects as
      V1.Type.Forall a -> V2.Type.Forall a
      V1.Type.IntroOuter a -> V2.Type.IntroOuter a
      where
        convertKind = \case
          V1.Kind.Star -> V2.Kind.Star
          V1.Kind.Arrow i o -> V2.Kind.Arrow (convertKind i) (convertKind o)

-- | forces loading v1 branches even if they may not exist
causalbranch2to1 :: Monad m => (String -> Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Branch.Causal m -> m (V1.Branch.Branch m)
causalbranch2to1 lookupSize lookupCT = fmap V1.Branch.Branch . causalbranch2to1' lookupSize lookupCT

causalbranch2to1' :: Monad m => (String -> Hash -> m V1.Reference.Size) -> (V2.Reference -> m CT.ConstructorType) -> V2.Branch.Causal m -> m (V1.Branch.UnwrappedBranch m)
causalbranch2to1' lookupSize lookupCT (V2.Causal hc _he (Map.toList -> parents) me) = do
  let currentHash = causalHash2to1 hc
  case parents of
    [] -> V1.Causal.One currentHash <$> (me >>= branch2to1 lookupSize lookupCT)
    [(hp, mp)] -> do
      let parentHash = causalHash2to1 hp
      V1.Causal.Cons currentHash
        <$> (me >>= branch2to1 lookupSize lookupCT)
        <*> pure (parentHash, causalbranch2to1' lookupSize lookupCT =<< mp)
    merge -> do
      let tailsList = map (bimap causalHash2to1 (causalbranch2to1' lookupSize lookupCT =<<)) merge
      e <- me
      V1.Causal.Merge currentHash <$> branch2to1 lookupSize lookupCT e <*> pure (Map.fromList tailsList)

causalbranch1to2 :: forall m. Monad m => V1.Branch.Branch m -> V2.Branch.Causal m
causalbranch1to2 (V1.Branch.Branch c) = causal1to2' hash1to2cb hash1to2c branch1to2 c
  where
    hash1to2cb :: V1.Branch.Hash -> (V2.CausalHash, V2.BranchHash)
    hash1to2cb (V1.Causal.RawHash h) = (hc, hb)
      where
        h2 = hash1to2 h
        hc = V2.CausalHash h2
        hb = V2.BranchHash h2

    hash1to2c :: V1.Branch.Hash -> V2.CausalHash
    hash1to2c = V2.CausalHash . hash1to2 . V1.Causal.unRawHash

    causal1to2' = causal1to2 @m @V1.Branch.Raw @V2.CausalHash @V2.BranchHash @(V1.Branch.Branch0 m) @(V2.Branch.Branch m)

    causal1to2 :: forall m h h2c h2e e e2. (Monad m, Ord h2c) => (V1.Causal.RawHash h -> (h2c, h2e)) -> (V1.Causal.RawHash h -> h2c) -> (e -> m e2) -> V1.Causal.Causal m h e -> V2.Causal m h2c h2e e2
    causal1to2 h1to22 h1to2 e1to2 = \case
      V1.Causal.One (h1to22 -> (hc, hb)) e -> V2.Causal hc hb Map.empty (e1to2 e)
      V1.Causal.Cons (h1to22 -> (hc, hb)) e (ht, mt) -> V2.Causal hc hb (Map.singleton (h1to2 ht) (causal1to2 h1to22 h1to2 e1to2 <$> mt)) (e1to2 e)
      V1.Causal.Merge (h1to22 -> (hc, hb)) e parents -> V2.Causal hc hb (Map.bimap h1to2 (causal1to2 h1to22 h1to2 e1to2 <$>) parents) (e1to2 e)

    branch1to2 :: forall m. Monad m => V1.Branch.Branch0 m -> m (V2.Branch.Branch m)
    branch1to2 b = do
      terms <- pure $ doTerms (V1.Branch._terms b)
      types <- pure $ doTypes (V1.Branch._types b)
      patches <- pure $ doPatches (V1.Branch._edits b)
      children <- pure $ doChildren (V1.Branch._children b)
      pure $ V2.Branch.Branch terms types patches children
      where
        -- is there a more readable way to structure these that's also linear?
        doTerms :: V1.Branch.Star V1.Referent.Referent V1.NameSegment -> Map V2.Branch.NameSegment (Map V2.Referent.Referent (m V2.Branch.MdValues))
        doTerms s =
          Map.fromList
            [ (namesegment1to2 ns, m2)
              | ns <- toList . Relation.ran $ V1.Star3.d1 s
              , let m2 =
                      Map.fromList
                        [ (referent1to2 r, pure md)
                          | r <- toList . Relation.lookupRan ns $ V1.Star3.d1 s
                          , let
                              mdrefs1to2 (typeR1, valR1) = (reference1to2 valR1, reference1to2 typeR1)
                              md = V2.Branch.MdValues . Map.fromList . map mdrefs1to2 . toList . Relation.lookupDom r $ V1.Star3.d3 s
                        ]
            ]

        doTypes :: V1.Branch.Star V1.Reference.Reference V1.NameSegment -> Map V2.Branch.NameSegment (Map V2.Reference.Reference (m V2.Branch.MdValues))
        doTypes s =
          Map.fromList
            [ (namesegment1to2 ns, m2)
              | ns <- toList . Relation.ran $ V1.Star3.d1 s
              , let m2 =
                      Map.fromList
                        [ (reference1to2 r, pure md)
                          | r <- toList . Relation.lookupRan ns $ V1.Star3.d1 s
                          , let
                              mdrefs1to2 (typeR1, valR1) = (reference1to2 valR1, reference1to2 typeR1)
                              md = V2.Branch.MdValues . Map.fromList . map mdrefs1to2 . toList . Relation.lookupDom r $ V1.Star3.d3 s
                        ]
            ]

        doPatches :: Map V1.NameSegment (V1.Branch.EditHash, m V1.Patch) -> Map V2.Branch.NameSegment (V2.PatchHash, m V2.Branch.Patch)
        doPatches = Map.bimap namesegment1to2 (bimap edithash1to2 (fmap patch1to2))

        doChildren :: Map V1.NameSegment (V1.Branch.Branch m) -> Map V2.Branch.NameSegment (V2.Branch.Causal m)
        doChildren = Map.bimap namesegment1to2 causalbranch1to2

patch2to1 ::
  forall m.
  Monad m =>
  (String -> Hash -> m V1.Reference.Size) ->
  V2.Branch.Patch ->
  m V1.Patch
patch2to1 lookupSize (V2.Branch.Patch v2termedits v2typeedits) = do
  termEdits <- Map.bitraverse referent2to1' (Set.traverse termedit2to1) v2termedits
  typeEdits <- Map.bitraverse (reference2to1 (lookupSize "patch->old type")) (Set.traverse typeedit2to1) v2typeedits
  pure $ V1.Patch (Relation.fromMultimap termEdits) (Relation.fromMultimap typeEdits)
  where
    referent2to1' :: V2.Referent -> m V1.Reference
    referent2to1' = \case
      V2.Referent.Ref r -> reference2to1 (lookupSize "patch->old term") r
      V2.Referent.Con {} -> error "found referent on LHS when converting patch2to1"
    termedit2to1 :: V2.TermEdit.TermEdit -> m V1.TermEdit.TermEdit
    termedit2to1 = \case
      V2.TermEdit.Replace (V2.Referent.Ref r) t ->
        V1.TermEdit.Replace <$> reference2to1 (lookupSize "patch->new term") r <*> typing2to1 t
      V2.TermEdit.Replace {} -> error "found referent on RHS when converting patch2to1"
      V2.TermEdit.Deprecate -> pure V1.TermEdit.Deprecate
    typeedit2to1 :: V2.TypeEdit.TypeEdit -> m V1.TypeEdit.TypeEdit
    typeedit2to1 = \case
      V2.TypeEdit.Replace r -> V1.TypeEdit.Replace <$> reference2to1 (lookupSize "patch->new type") r
      V2.TypeEdit.Deprecate -> pure V1.TypeEdit.Deprecate
    typing2to1 t = pure $ case t of
      V2.TermEdit.Same -> V1.TermEdit.Same
      V2.TermEdit.Subtype -> V1.TermEdit.Subtype
      V2.TermEdit.Different -> V1.TermEdit.Different

patch1to2 :: V1.Patch -> V2.Branch.Patch
patch1to2 (V1.Patch v1termedits v1typeedits) = V2.Branch.Patch v2termedits v2typeedits
  where
    v2termedits = Map.bimap (V2.Referent.Ref . reference1to2) (Set.map termedit1to2) $ Relation.domain v1termedits
    v2typeedits = Map.bimap reference1to2 (Set.map typeedit1to2) $ Relation.domain v1typeedits
    termedit1to2 :: V1.TermEdit.TermEdit -> V2.TermEdit.TermEdit
    termedit1to2 = \case
      V1.TermEdit.Replace r t -> V2.TermEdit.Replace (V2.Referent.Ref (reference1to2 r)) (typing1to2 t)
      V1.TermEdit.Deprecate -> V2.TermEdit.Deprecate
    typeedit1to2 :: V1.TypeEdit.TypeEdit -> V2.TypeEdit.TypeEdit
    typeedit1to2 = \case
      V1.TypeEdit.Replace r -> V2.TypeEdit.Replace (reference1to2 r)
      V1.TypeEdit.Deprecate -> V2.TypeEdit.Deprecate
    typing1to2 = \case
      V1.TermEdit.Same -> V2.TermEdit.Same
      V1.TermEdit.Subtype -> V2.TermEdit.Subtype
      V1.TermEdit.Different -> V2.TermEdit.Different

edithash2to1 :: V2.PatchHash -> V1.Branch.EditHash
edithash2to1 = hash2to1 . V2.unPatchHash

edithash1to2 :: V1.Branch.EditHash -> V2.PatchHash
edithash1to2 = V2.PatchHash . hash1to2

namesegment2to1 :: V2.Branch.NameSegment -> V1.NameSegment
namesegment2to1 (V2.Branch.NameSegment t) = V1.NameSegment t

namesegment1to2 :: V1.NameSegment -> V2.Branch.NameSegment
namesegment1to2 (V1.NameSegment t) = V2.Branch.NameSegment t

branch2to1 ::
  Monad m =>
  (String -> Hash -> m V1.Reference.Size) ->
  (V2.Reference -> m CT.ConstructorType) ->
  V2.Branch.Branch m ->
  m (V1.Branch.Branch0 m)
branch2to1 lookupSize lookupCT (V2.Branch.Branch v2terms v2types v2patches v2children) = do
  v1terms <- toStar (reference2to1 $ lookupSize "term metadata") =<< Map.bitraverse (pure . namesegment2to1) (Map.bitraverse (referent2to1 (lookupSize "term") lookupCT) id) v2terms
  v1types <- toStar (reference2to1 $ lookupSize "type metadata") =<< Map.bitraverse (pure . namesegment2to1) (Map.bitraverse (reference2to1 (lookupSize "type")) id) v2types
  v1patches <- Map.bitraverse (pure . namesegment2to1) (bitraverse (pure . edithash2to1) (fmap (patch2to1 lookupSize))) v2patches
  v1children <- Map.bitraverse (pure . namesegment2to1) (causalbranch2to1 lookupSize lookupCT) v2children
  pure $ V1.Branch.branch0 v1terms v1types v1children v1patches
  where
    toStar :: forall m name ref. (Monad m, Ord name, Ord ref) => (V2.Reference -> m V1.Reference) -> Map name (Map ref V2.Branch.MdValues) -> m (V1.Metadata.Star ref name)
    toStar mdref2to1 m = foldM insert mempty (Map.toList m)
      where
        insert star (name, m) = foldM (insert' name) star (Map.toList m)
        insert' :: name -> V1.Metadata.Star ref name -> (ref, V2.Branch.MdValues) -> m (V1.Metadata.Star ref name)
        insert' name star (ref, V2.Branch.MdValues mdvals) = do
          let facts = Set.singleton ref
              names = Relation.singleton ref name
          types :: Relation.Relation ref V1.Metadata.Type <-
            Relation.insertManyRan ref <$> traverse mdref2to1 (Map.elems mdvals) <*> pure mempty
          vals :: Relation.Relation ref (V1.Metadata.Type, V1.Metadata.Value) <-
            Relation.insertManyRan ref <$> (traverse (\(t, v) -> (,) <$> mdref2to1 v <*> mdref2to1 t) (Map.toList mdvals)) <*> pure mempty
          pure $ star <> V1.Star3.Star3 facts names types vals

-- V2.Branch0 should have the metadata types, could bulk load with relational operations
-- type Star a n = Star3 a n Type (Type, Value)
-- type Star a n = Star3 a n Type (Reference, Reference)
-- MdValues is a Set V2.Reference

-- (Name, TermRef, Metadata Type, Metadata Value)  <-- decided not this (because name was too long/repetitive?)
-- (BranchId/Hash, TermRef, Metadata Type, Metadata Value) <-- what about this

-- data V2.Branch m = Branch
--   { terms :: Map NameSegment (Map Referent (m MdValues)),
--     types :: Map NameSegment (Map Reference (m MdValues)),
--     patches :: Map NameSegment (PatchHash, m Patch),
--     children :: Map NameSegment (Causal m)
--   }
-- branch0 :: Metadata.Star Referent NameSegment
--         -> Metadata.Star Reference NameSegment
--         -> Map NameSegment (Branch m)
--         -> Map NameSegment (EditHash, m Patch)
--         -> Branch0 m

-- type Metadata.Star a n = Star3 a n Type (Type, Value)

-- data Star3 fact d1 d2 d3
--   = Star3 { fact :: Set fact
--           , d1 :: Relation fact d1
--           , d2 :: Relation fact d2
--           , d3 :: Relation fact d3 } deriving (Eq,Ord,Show)
