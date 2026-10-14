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
#   6. run `audit env` on the built environment.
# Run inside `nix develop .#ownership`. Usage: scripts/audit.sh [rev]
set -euo pipefail
rev=${1:-HEAD}
repo=$(git rev-parse --show-toplevel)
work=$(mktemp -d "${XDG_CACHE_HOME:-$HOME/.cache}/ownership-audit.XXXXXX")
cleanup() {
  status=$?
  if [ "$status" -eq 0 ]; then
    rm -rf "$work"
  else
    echo "audit failed; retained work and logs: $work" >&2
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
echo "audit passed: $rev"
