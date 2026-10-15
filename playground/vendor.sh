#!/usr/bin/env bash
# Regenerates playground/vendor/: the modules of CodeMirror 6 the
# playground's editor and its view of the emitted JavaScript load
# (docs/design/playground.md §4.2), each the ES module its npm package ships,
# unmodified, at the version pinned below.
# Jayson Reis decided on 2026-10-15 (dashboard question `wasm-playground-q6`)
# that the page loads them from its own site and not from a CDN: the page
# runs in the `canassa.github.io` origin, which every Pages site of that user
# shares, so code from a third party there could read their storage.
#
# The only step here that needs the network. Run it by hand to move a pin,
# then run `zig build test-blackbox-playground-page`, which checks every
# file against `SHA256SUMS` and the import map in `index.html` against the
# files, and commit the files, `SHA256SUMS` and `LICENSES.txt` together.
# npm's tarballs do not change, so running it without changing a pin
# reproduces the checked-in files exactly.
set -euo pipefail

# Each package, its version, the file of its tarball that is its ES module
# (its `exports` or `module` entry, or the one mode of `legacy-modes` the
# beni grammar extends), and the file's name here when the package's name
# does not give it.
PACKAGES="
@codemirror/state 6.7.6 dist/index.js
@codemirror/view 6.43.13 dist/index.js
@codemirror/language 6.12.4 dist/index.js
@codemirror/commands 6.11.1 dist/index.js
@codemirror/lint 6.9.7 dist/index.js
@codemirror/autocomplete 6.20.3 dist/index.js
@codemirror/search 6.7.2 dist/index.js
@lezer/common 1.5.3 dist/index.js
@lezer/highlight 1.2.5 dist/index.js
@marijn/find-cluster-break 1.0.4 src/index.js
crelt 1.0.7 index.js
style-mod 4.1.4 src/style-mod.js
w3c-keyname 2.2.8 index.js
@codemirror/legacy-modes 6.5.4 mode/elm.js codemirror-legacy-modes-elm.js
@codemirror/lang-javascript 6.2.5 dist/index.js
@lezer/javascript 1.5.5 dist/index.js
@lezer/lr 1.4.10 dist/index.js
"

here="$(cd "$(dirname "$0")" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Written here and moved into place at the end, so that a failed fetch
# leaves the checked-in directory as it was.
out="$work/vendor"
mkdir -p "$out"

{
  echo "The modules in this directory, each the ES module its npm package ships,"
  echo "unmodified, fetched by playground/vendor.sh. Each package's licence follows"
  echo "its source."
} >"$out/LICENSES.txt"

echo "$PACKAGES" | while read -r name version entry file; do
  [ -n "$name" ] || continue
  base="${name##*/}"
  # `@codemirror/state` is `codemirror-state.js`; a package with no scope
  # keeps its name.
  [ -n "$file" ] || file="$(echo "${name#@}" | tr '/' '-').js"
  tarball="https://registry.npmjs.org/$name/-/$base-$version.tgz"
  # npm's own record of the tarball's SHA-512, checked before anything is
  # taken from it.
  integrity="$(curl -sSf "https://registry.npmjs.org/$name/$version" | node -e 'let s="";process.stdin.on("data",(c)=>s+=c).on("end",()=>process.stdout.write(JSON.parse(s).dist.integrity))')"
  curl -sSf -o "$work/$base.tgz" "$tarball"
  actual="sha512-$(openssl dgst -sha512 -binary "$work/$base.tgz" | openssl base64 -A)"
  if [ "$actual" != "$integrity" ]; then
    echo "$tarball: SHA-512 $actual, npm records $integrity" >&2
    exit 1
  fi
  mkdir -p "$work/$base"
  tar -xzf "$work/$base.tgz" -C "$work/$base"
  cp "$work/$base/package/$entry" "$out/$file"
  licence="$(ls "$work/$base/package" | grep -i '^licen[cs]e' | head -n 1)"
  {
    echo
    echo "== $file: $name $version (MIT)"
    echo "   from $tarball, package/$entry"
    echo
    sed 's/^/   /; s/ *$//' "$work/$base/package/$licence"
  } >>"$out/LICENSES.txt"
done

# `sha256sum` on Linux, `shasum -a 256` on macOS: the same output.
if command -v sha256sum >/dev/null; then sum=(sha256sum); else sum=(shasum -a 256); fi
(cd "$out" && "${sum[@]}" ./*.js | sed 's| \./| |' >SHA256SUMS)
rm -rf "$here/vendor"
mv "$out" "$here/vendor"
cat "$here/vendor/SHA256SUMS"
