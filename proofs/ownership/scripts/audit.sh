#!/usr/bin/env bash
# The audit as its own process over a clean checkout of HEAD, independent of
# anything the audited code could rewrite while it is built:
#   1. export the committed proofs/ownership into a fresh directory;
#   2. hash every file;
#   3. build only the `audit` executable (it imports Lean and Std, no
#      Ownership module, so no audited code runs) and run `audit sources`,
#      which parses every source with Lean's parser;
#   4. build everything (the audited code's elaboration runs here);
#   5. check no file changed, the audit binary included;
#   6. run `audit env` on the built environment;
#   7. with a second argument, move the export's `.lake` there, only after
#      every check above passed. CI gives it the checkout's `.lake`, so the
#      checkout's `lake build` checks the same sources against this build
#      instead of building them a second time. The audit itself never reads
#      a `.lake` it did not build.
# Run inside `nix develop .#ownership`. Usage: scripts/audit.sh [rev [lake-out]]
set -euo pipefail
rev=${1:-HEAD}
lake_out=${2:-}
if [ -n "$lake_out" ]; then
  if [ -e "$lake_out" ]; then
    echo "audit: $lake_out exists already; the audit does not overwrite it" >&2; exit 1
  fi
  lake_out=$(realpath -m "$lake_out")
fi
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/ownership-audit.XXXXXX")
audit_passed=false
cleanup() {
  if [ "$audit_passed" = true ]; then
    rm -rf "$work"
  else
    echo "audit incomplete; retained work and logs: $work" >&2
  fi
}
trap cleanup EXIT
git -C "$repo" archive "$rev" proofs/ownership | tar -x -C "$work"
cd "$work/proofs/ownership"
hashes() { find . -path ./.lake -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum; }
hashes > "$work/sources.sha"
lake build audit > "$work/build-audit.log" 2>&1 || { tail -20 "$work/build-audit.log"; exit 1; }
sha256sum .lake/build/bin/audit > "$work/audit.sha"
./.lake/build/bin/audit sources > "$work/source-check.log" 2>&1 || { cat "$work/source-check.log"; exit 1; }
cat "$work/source-check.log"
lake build > "$work/build.log" 2>&1 || { tail -20 "$work/build.log"; exit 1; }
if ! hashes | diff -q "$work/sources.sha" - > /dev/null; then
  echo "AUDIT FAILED: the build changed a source file"; hashes | diff "$work/sources.sha" - || true; exit 1
fi
if ! sha256sum -c --quiet "$work/audit.sha"; then
  echo "AUDIT FAILED: the build changed the audit executable"; exit 1
fi
lake env ./.lake/build/bin/audit env
if [ -n "$lake_out" ]; then
  mkdir -p "$(dirname "$lake_out")"
  mv .lake "$lake_out"
fi
echo "audit passed: $rev"
audit_passed=true
