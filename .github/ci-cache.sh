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
#
# A cache only saves time, so neither command fails the job: a restore that
# fails leaves nothing behind and the job runs cold, and a save that fails is
# reported as a warning on the run with the store's answer.
set -uo pipefail

store=/var/cache/beni-ci
socket=/run/beni-ci-cache.sock

warn() { echo "::warning title=ci-cache::$*"; }

case "${1-}" in
restore)
  shift
  for name in "$@"; do
    [ -d "$store/$name/" ] || continue
    start=$SECONDS
    # Copied whole into a scratch directory first, so that a copy that fails
    # half-way leaves no partial cache in the job. On ZFS both copies share
    # blocks with the store (block cloning): a gigabyte takes a second.
    staging=$(mktemp -d "${RUNNER_TEMP:-$HOME}/ci-cache.XXXXXX")
    if cp -R --no-dereference --preserve=mode,timestamps,links --reflink=auto \
      "$store/$name/." "$staging/" 2> "$staging.err" &&
      cp -R --no-dereference --preserve=mode,timestamps,links --reflink=auto \
        "$staging/." "$HOME/" 2>> "$staging.err"; then
      rm -rf "$staging" "$staging.err"
      echo "restored $name in $((SECONDS - start)) s"
      exit 0
    fi
    echo "$(wc -l < "$staging.err") errors, the first:"
    head -3 "$staging.err"
    rm -rf "$staging" "$staging.err"
    warn "could not restore $name; this job runs without it"
    exit 0
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
  if ! token=$(curl -sSf -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=beni-ci-cache" | jq -er .value); then
    warn "could not get the OIDC token; $name is not saved"
    exit 0
  fi
  start=$SECONDS
  reply=$({
    printf 'PUT %s\n%s\n' "$name" "$token"
    tar -C "$HOME" -c "${paths[@]}" | zstd -1 -T0 -q
  } | socat -t 900 - "UNIX-CONNECT:$socket")
  status=$?
  echo "store answered: ${reply:-nothing} (exit $status; $name, ${paths[*]}, $((SECONDS - start)) s)"
  case "$status:$reply" in
  0:ok*) ;;
  *) warn "$name is not saved: ${reply:-no answer} (exit $status)" ;;
  esac
  ;;
*)
  echo "usage: ci-cache.sh restore NAME... | save NAME PATH..." >&2
  exit 2
  ;;
esac
