#!/usr/bin/env bash
# render.sh [stars]: rebuild beni-og.png, the repository's social preview (1200x600).
# The star count defaults to the repository's current one (gh). Chrome and Python come from the
# beni-website dev shell (its `browse`), so set SITE when that checkout is not beside this one.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
SITE=${SITE:-$(realpath "$HERE/../../../beni-website")}
STARS=${1:-$(gh repo view canassa/beni --json stargazerCount -q .stargazerCount)}
cd "$SITE"
nix develop -c python3 "$HERE/build.py" "$STARS"
nix develop -c browse --width 1200 --height 600 --dpr 1 --settle 0.5 --quiet \
  shot "file://$HERE/card.html" -o "$HERE/beni-og.png"
rm "$HERE/card.html"
