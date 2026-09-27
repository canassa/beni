{ name = "compare"
, dependencies =
  [ "console", "effect", "foldable-traversable", "lists", "prelude", "tuples" ]
, packages = ./packages.dhall
, sources = [ "src/**/*.purs" ]
}
