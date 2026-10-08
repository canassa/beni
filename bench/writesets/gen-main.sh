#!/usr/bin/env bash
# Write a Main.beni into a corpus `zig build bench -- --generate=<n>` made
# (copied out of .zig-cache/bench-gen and run through `beni fmt
# --migrate-names`), mounting one Tea.sandbox per Gen.Data.Store module, so
# the write-set pass analyses every store's `update` (research 63 §4).
#   bench/writesets/gen-main.sh <corpus-dir>
set -euo pipefail
cd "$1"
ids=$(ls Gen/Data | sed -n 's/^Store\([0-9]*\)\.beni$/\1/p' | sort -n)
{
  echo "import Browser"
  echo "import Html exposing (Html)"
  echo "import Tea"
  for i in $ids; do echo "import Gen.Data.Store$i"; done
  echo ""
  echo ""
  for i in $ids; do
    echo "p$i : Browser.Program"
    echo "p$i = Tea.sandbox { init = Gen.Data.Store$i.init$i, update = Gen.Data.Store$i.update$i, view = λm → <p>{m.count}</p> }"
    echo ""
    echo ""
  done
  echo "main : Browser.Program"
  printf "main = Browser.programs [ "
  first=1
  for i in $ids; do
    if [ $first = 1 ]; then printf "p%s" "$i"; first=0; else printf ", p%s" "$i"; fi
  done
  echo " ]"
} > Main.beni
