#!/usr/bin/env bash
# Check that every edit of scripts/mutate.mjs still applies to the current
# sources (exactly once), without building anything. Run from proofs/ownership.
set -u
scratch=$(mktemp -d "${HOME}/.cache/mutcheck.XXXXXX")
bad=0
for m in $(node scripts/mutate.mjs --list); do
  rm -rf "$scratch/Ownership"; cp -r Ownership "$scratch/"
  if ! node scripts/mutate.mjs "$m" "$scratch" > /dev/null; then echo "PATCH FAILED: $m"; bad=1; fi
done
rm -rf "$scratch"
[ $bad -eq 0 ] && echo "every mutant edit applies"
exit $bad
