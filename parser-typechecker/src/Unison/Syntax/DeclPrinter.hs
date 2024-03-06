module Unison.Syntax.DeclPrinter (prettyDecl, prettyDeclW, prettyDeclHeader, prettyDeclOrBuiltinHeader, AccessorName) where

import Control.Monad.Writer (Writer, runWriter, tell)
import Data.List.NonEmpty (pattern (:|))
import Data.Map qualified as Map
import Data.Text qualified as Text
import Unison.ConstructorReference (ConstructorReference, GConstructorReference (..))
import Unison.ConstructorType qualified as CT
import Unison.DataDeclaration (DataDeclaration, EffectDeclaration, toDataDecl)
import Unison.DataDeclaration qualified as DD
import Unison.DataDeclaration.Dependencies qualified as DD
import Unison.HashQualified qualified as HQ
import Unison.Name (Name)
import Unison.Name qualified as Name
import Unison.PrettyPrintEnv (PrettyPrintEnv)
import Unison.PrettyPrintEnv qualified as PPE
import Unison.PrettyPrintEnvDecl (PrettyPrintEnvDecl (..))
import Unison.PrettyPrintEnvDecl qualified as PPED
import Unison.Reference (Reference, Reference' (DerivedId))
import Unison.Referent qualified as Referent
import Unison.Syntax.HashQualified qualified as HQ (toText, toVar, unsafeParseText)
import Unison.Syntax.NamePrinter (styleHashQualified'')
import Unison.Syntax.TypePrinter (runPretty)
import Unison.Syntax.TypePrinter qualified as TypePrinter
import Unison.Syntax.Var qualified as Var (namespaced)
import Unison.Type qualified as Type
import Unison.Util.Pretty (Pretty)
import Unison.Util.Pretty qualified as P
import Unison.Util.SyntaxText qualified as S
import Unison.Var (Var)
import Unison.Var qualified as Var (freshenId, name, named)

type SyntaxText = S.SyntaxText' Reference

type AccessorName = HQ.HashQualified Name

prettyDeclW ::
  (Var v) =>
  PrettyPrintEnvDecl ->
  Reference ->
  HQ.HashQualified Name ->
  DD.Decl v a ->
  Writer [AccessorName] (Pretty SyntaxText)
prettyDeclW ppe r hq d = case d of
  Left e -> pure $ prettyEffectDecl ppe r hq e
  Right dd -> prettyDataDecl ppe r hq dd

prettyDecl ::
  (Var v) =>
  PrettyPrintEnvDecl ->
  Reference ->
  HQ.HashQualified Name ->
  DD.Decl v a ->
  Pretty SyntaxText
prettyDecl ppe r hq d = fst . runWriter $ prettyDeclW ppe r hq d

prettyEffectDecl ::
  (Var v) =>
  PrettyPrintEnvDecl ->
  Reference ->
  HQ.HashQualified Name ->
  EffectDeclaration v a ->
  Pretty SyntaxText
prettyEffectDecl ppe r name = prettyGADT ppe CT.Effect r name . toDataDecl

prettyGADT ::
  (Var v) =>
  PrettyPrintEnvDecl ->
  CT.ConstructorType ->
  Reference ->
  HQ.HashQualified Name ->
  DataDeclaration v a ->
  Pretty SyntaxText
prettyGADT env ctorType r name dd =
  P.hang header . P.lines $
    constructor
      <$> zip
        [0 ..]
        (DD.constructors' dd)
  where
    constructor (n, (_, _, t)) =
      prettyPattern (PPED.unsuffixifiedPPE env) ctorType name (ConstructorReference r n)
        <> fmt S.TypeAscriptionColon " :"
          `P.hang` TypePrinter.prettySyntax (PPED.suffixifiedPPE env) t
    header = prettyEffectHeader name (DD.EffectDeclaration dd) <> fmt S.ControlKeyword " where"

prettyPattern ::
  PrettyPrintEnv ->
  CT.ConstructorType ->
  HQ.HashQualified Name ->
  ConstructorReference ->
  Pretty SyntaxText
prettyPattern env ctorType namespace ref =
  styleHashQualified''
    (fmt (S.TermReference conRef))
    ( let strip =
            case HQ.toName namespace of
              Nothing -> id
              Just name -> HQ.stripNamespace name
       in strip (PPE.termName env conRef)
    )
  where
    conRef = Referent.Con ref ctorType

prettyDataDecl ::
  (Var v) =>
  PrettyPrintEnvDecl ->
  Reference ->
  HQ.HashQualified Name ->
  DataDeclaration v a ->
  Writer [AccessorName] (Pretty SyntaxText)
prettyDataDecl (PrettyPrintEnvDecl unsuffixifiedPPE suffixifiedPPE) r name dd =
  (header <>)
    . P.sep (fmt S.DelimiterChar (" | " `P.orElse` "\n  | "))
    <$> constructor
      `traverse` zip
        [0 ..]
        (DD.constructors' dd)
  where
    constructor (n, (_, _, Type.ForallsNamed' _ t)) = constructor' n t
    constructor (n, (_, _, t)) = constructor' n t
    constructor' n t = case Type.unArrows t of
      Nothing -> pure $ prettyPattern unsuffixifiedPPE CT.Data name (ConstructorReference r n)
      Just ts -> case fieldNames unsuffixifiedPPE r name dd of
        Nothing ->
          pure
            . P.group
            . P.hang' (prettyPattern unsuffixifiedPPE CT.Data name (ConstructorReference r n)) "      "
            $ P.spaced (runPretty suffixifiedPPE (traverse (TypePrinter.prettyRaw Map.empty 10) (init ts)))
        Just fs -> do
          tell
            [ case accessor of
                Nothing -> HQ.NameOnly $ declName `Name.joinDot` fieldName
                Just accessor -> HQ.NameOnly $ declName `Name.joinDot` fieldName `Name.joinDot` accessor
              | HQ.NameOnly declName <- [name],
                HQ.NameOnly fieldName <- fs,
                accessor <- [Nothing, Just (Name.fromSegment "set"), Just (Name.fromSegment "modify")]
            ]
          pure . P.group $
            fmt S.DelimiterChar "{ "
              <> P.sep
                (fmt S.DelimiterChar "," <> " " `P.orElse` "\n      ")
                (field <$> zip fs (init ts))
              <> fmt S.DelimiterChar " }"
    field (fname, typ) =
      P.group $
        styleHashQualified'' (fmt (S.TypeReference r)) fname
          <> fmt S.TypeAscriptionColon " :"
            `P.hang` runPretty suffixifiedPPE (TypePrinter.prettyRaw Map.empty (-1) typ)
    header = prettyDataHeader name dd <> fmt S.DelimiterChar (" = " `P.orElse` "\n  = ")

-- Comes up with field names for a data declaration which has the form of a
-- record, like `type Pt = { x : Int, y : Int }`. Works by generating the
-- record accessor terms for the data type, hashing these terms, and then
-- checking the `PrettyPrintEnv` for the names of those hashes. If the names for
-- these hashes are:
--
--   `Pt.x`, `Pt.x.set`, `Pt.x.modify`, `Pt.y`, `Pt.y.set`, `Pt.y.modify`
--
-- then this matches the naming convention generated by the parser, and we
-- return `x` and `y` as the field names.
--
-- This function bails with `Nothing` if the names aren't an exact match for
-- the expected record naming convention.
fieldNames ::
  forall v a.
  (Var v) =>
  PrettyPrintEnv ->
  Reference ->
  HQ.HashQualified Name ->
  DataDeclaration v a ->
  Maybe [HQ.HashQualified Name]
fieldNames env r name dd = do
  typ <- case DD.constructors dd of
    [(_, typ)] -> Just typ
    _ -> Nothing
  let vars :: [v]
      -- We add `n` to the end of the variable name as a quick fix to #4752, but we suspect there's a more
      -- fundamental fix to be made somewhere in the term printer to automatically suffix a var name with its
      -- freshened id if it would be ambiguous otherwise.
      vars = [Var.freshenId (fromIntegral n) (Var.named ("_" <> Text.pack (show n))) | n <- [0 .. Type.arity typ - 1]]
  hashes <- DD.hashFieldAccessors env (HQ.toVar name) vars r dd
  let names =
        [ (r, HQ.toText . PPE.termName env . Referent.Ref $ DerivedId r)
          | r <- (\(refId, _trm, _typ) -> refId) <$> Map.elems hashes
        ]
  let fieldNames =
        Map.fromList
          [ (r, f)
            | (r, n) <- names,
              typename <- pure (HQ.toText name),
              typename `Text.isPrefixOf` n,
              rest <- pure $ Text.drop (Text.length typename + 1) n,
              (f, rest) <- pure $ Text.span (/= '.') rest,
              rest `elem` ["", ".set", ".modify"]
          ]

  if Map.size fieldNames == length names
    then
      Just
        [ HQ.unsafeParseText name
          | v <- vars,
            Just (ref, _, _) <- [Map.lookup (Var.namespaced (HQ.toVar name :| [v])) hashes],
            Just name <- [Map.lookup ref fieldNames]
        ]
    else Nothing

prettyModifier :: DD.Modifier -> Pretty SyntaxText
prettyModifier DD.Structural = fmt S.DataTypeModifier "structural"
prettyModifier (DD.Unique _uid) = mempty -- don't print anything since 'unique' is the default
-- leaving this comment for the historical record so the syntax for uid is not forgotten
-- fmt S.DataTypeModifier "unique" -- <> ("[" <> P.text uid <> "] ")

prettyDataHeader ::
  (Var v) => HQ.HashQualified Name -> DD.DataDeclaration v a -> Pretty SyntaxText
prettyDataHeader name dd =
  P.sepNonEmpty
    " "
    [ prettyModifier (DD.modifier dd),
      fmt S.DataTypeKeyword "type",
      styleHashQualified'' (fmt $ S.HashQualifier name) name,
      P.sep " " (fmt S.DataTypeParams . P.text . Var.name <$> DD.bound dd)
    ]

prettyEffectHeader ::
  (Var v) =>
  HQ.HashQualified Name ->
  DD.EffectDeclaration v a ->
  Pretty SyntaxText
prettyEffectHeader name ed =
  P.sepNonEmpty
    " "
    [ prettyModifier (DD.modifier (DD.toDataDecl ed)),
      fmt S.DataTypeKeyword "ability",
      styleHashQualified'' (fmt $ S.HashQualifier name) name,
      P.sep
        " "
        (fmt S.DataTypeParams . P.text . Var.name <$> DD.bound (DD.toDataDecl ed))
    ]

prettyDeclHeader ::
  (Var v) =>
  HQ.HashQualified Name ->
  Either (DD.EffectDeclaration v a) (DD.DataDeclaration v a) ->
  Pretty SyntaxText
prettyDeclHeader name (Left e) = prettyEffectHeader name e
prettyDeclHeader name (Right d) = prettyDataHeader name d

prettyDeclOrBuiltinHeader ::
  (Var v) =>
  HQ.HashQualified Name ->
  DD.DeclOrBuiltin v a ->
  Pretty SyntaxText
prettyDeclOrBuiltinHeader name (DD.Builtin ctype) = case ctype of
  CT.Data -> fmt S.DataTypeKeyword "builtin type " <> styleHashQualified'' (fmt $ S.HashQualifier name) name
  CT.Effect -> fmt S.DataTypeKeyword "builtin ability " <> styleHashQualified'' (fmt $ S.HashQualifier name) name
prettyDeclOrBuiltinHeader name (DD.Decl e) = prettyDeclHeader name e

fmt :: S.Element r -> Pretty (S.SyntaxText' r) -> Pretty (S.SyntaxText' r)
fmt = P.withSyntax
