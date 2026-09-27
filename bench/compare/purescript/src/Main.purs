module Main (main) where

import Prelude

import Data.Array as Array
import Data.String (joinWith)
import Effect (Effect)
import Effect.Console (log)
import Data as Data
import Interp as Interp
import Tree as Tree

main :: Effect Unit
main = log (joinWith "\n" (Array.fromFoldable (Interp.run <> Tree.run <> Data.run)))
