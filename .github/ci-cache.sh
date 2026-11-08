#!/usr/bin/env bash
# The CI caches on azathoth (infra repository, hosts/azathoth/github-runners.nix,
# beni-ci-cache): master's Zig and run-hash caches, kept on the host.
#
#   ci-cache.sh restore NAME...       copy the first NAME the store holds into
#                                     $HOME, as this job's own files
#   ci-cache.sh save NAME PATH...     upload PATHs (under $HOME) as NAME
#
# Every job may restore; the store is read-only to it. Only a run of ci.yml on
# a push to master (or its schedule) may save: the job sends GitHub's OIDC
# token with the upload, and the host checks its signature, repository, ref,
# event and workflow before it unpacks anything. A pull request therefore
# reads master's caches and can never change them, as with actions/cache's
# scopes. A job that finds no cache starts cold.
set -euo pipefail

store=/var/cache/beni-ci
socket=/run/beni-ci-cache.sock

case "${1-}" in
restore)
  shift
  for name in "$@"; do
    if [ -d "$store/$name/" ]; then
      start=$SECONDS
      # Copies on ZFS share blocks with the store (block cloning), so a
      # gigabyte takes a second; the files are this job's to change.
      cp -R --no-dereference --preserve=mode,timestamps,links --reflink=auto \
        "$store/$name/." "$HOME/"
      echo "restored $name in $((SECONDS - start)) s"
      exit 0
    fi
  done
  echo "no cache: $*"
  ;;
save)
  name=$2
  shift 2
  paths=()
  for path in "$@"; do
    [ -e "$path" ] || continue
    paths+=("$(realpath --relative-to="$HOME" "$path")")
  done
  if [ ${#paths[@]} -eq 0 ]; then
    echo "nothing to save"
    exit 0
  fi
  token=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=beni-ci-cache" | jq -r .value)
  start=$SECONDS
  reply=$({
    printf 'PUT %s\n%s\n' "$name" "$token"
    tar -C "$HOME" -c "${paths[@]}" | zstd -1 -T0 -q
  } | socat -t 900 - "UNIX-CONNECT:$socket")
  echo "$reply ($name, ${paths[*]}, $((SECONDS - start)) s)"
  case "$reply" in ok*) ;; *) exit 1 ;; esac
  ;;
*)
  echo "usage: ci-cache.sh restore NAME... | save NAME PATH..." >&2
  exit 2
  ;;
esac
