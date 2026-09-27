{ name = "compare"
, dependencies =
  [ "arrays"
  , "console"
  , "either"
  , "effect"
  , "foldable-traversable"
  , "lists"
  , "maybe"
  , "prelude"
  , "strings"
  , "tuples"
  ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs" ]
}
