#!/usr/bin/env bash
# Black-box refusal checks; run from proofs/ownership in the ownership shell.
set -euo pipefail
bin=$(pwd)/.lake/build/bin/ownership
audit=$(pwd)/.lake/build/bin/audit
for input in 'enumrate 3' 'ci --mutant=disjoint' 'falsify 0' 'falsify 00' 'verdict-diff' 'oracle --wat' 'oracle nope' 'enumerate --count-only --mutant=dead'; do
  read -r -a args <<< "$input"
  if "$bin" "${args[@]}" > /dev/null 2>&1; then echo "incorrect success: $input"; exit 1; fi
done
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R Ownership "$work/Ownership"
cp Ownership.lean Main.lean Audit.lean Axioms.lean "$work/"
for payload in \
  'open Ownership in #eval (IO.FS.writeFile "executed" "bad")' \
  'set_option maxRecDepth 1000 in run_cmd (IO.FS.writeFile "executed" "bad")' \
  'example : True := by run_tac (IO.FS.writeFile "executed" "bad"); exact True.intro'; do
  printf '%s\n' "$payload" > "$work/Ownership/Attack.lean"
  if (cd "$work" && "$audit" sources) > "$work/refusal.log" 2>&1; then
    echo "audit accepted executable syntax: $payload"; exit 1
  fi
  grep -Eq 'nested command|executable syntax' "$work/refusal.log"
  [ ! -e "$work/executed" ]
done
[ "$(node scripts/mutate.mjs --canonical nofix1 oncethroughcall)" = oncethroughcall ]
echo 'CLI refusals, nested audit refusals before execution, and mutant alias deduplication passed'
