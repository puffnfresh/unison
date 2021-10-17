{-# Language OverloadedStrings #-}

module Unison.PrettyPrintEnvDecl.Names where

import Unison.Names3 (NamesWithHistory)
import Unison.PrettyPrintEnvDecl (PrettyPrintEnvDecl (PrettyPrintEnvDecl))
import Unison.PrettyPrintEnv.Names (fromNames, fromSuffixNames)

fromNamesDecl :: Int -> NamesWithHistory -> PrettyPrintEnvDecl
fromNamesDecl hashLength names =
  PrettyPrintEnvDecl (fromNames hashLength names) (fromSuffixNames hashLength names)
