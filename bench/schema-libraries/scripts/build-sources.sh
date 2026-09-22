#!/usr/bin/env bash
set -euo pipefail

benchmark_dir=$(cd "$(dirname "$0")/.." && pwd)
repo_dir=$(cd "$benchmark_dir/../.." && pwd)

run_in() {
  local directory=$1
  shift
  echo "+ ($directory) $*" >&2
  (cd "$directory" && "$@")
}

# Ajv's release tag does not contain a dependency lockfile.
run_in "$repo_dir/references/ajv" npm install --ignore-scripts --legacy-peer-deps
run_in "$repo_dir/references/ajv" npm run build

run_in "$repo_dir/references/typia" corepack pnpm@10.6.4 install --frozen-lockfile
run_in "$repo_dir/references/typia" corepack pnpm@10.6.4 --filter typia build

if [[ -n "${DENO_BIN:-}" ]]; then
  run_in "$repo_dir/references/typebox" "$DENO_BIN" task build
else
  run_in "$repo_dir/references/typebox" npx --yes deno@2.6.3 task build
fi

run_in "$repo_dir/references/arktype" npx --yes pnpm@10.19.0 install --frozen-lockfile
run_in "$repo_dir/references/arktype" npx --yes pnpm@10.19.0 -r --filter '!@ark/docs' build

# fast-json-stringify publishes the JavaScript checked into this tag; there is
# no build script. Install its test/runtime dependencies and exercise index.js.
run_in "$repo_dir/references/fast-json-stringify" npm install --ignore-scripts
run_in "$repo_dir/references/fast-json-stringify" node -e \
  'const fjs=require("./index.js"); const s=fjs({type:"object",properties:{x:{type:"integer"}}}); if(s({x:1})!=="{\"x\":1}") process.exit(1)'

nub_dir="$benchmark_dir/.source-build/nub"
if [[ ! -x "$nub_dir/bin/nub" ]]; then
  NUB_INSTALL_DIR="$nub_dir" NUB_NO_MODIFY_PATH=1 \
    bash -c 'curl -fsSL https://raw.githubusercontent.com/nubjs/nub/0ae8783f1f93763c56dfc827892cfb679e8a0a77/install.sh | bash -s -- 0.8.3'
fi
run_in "$repo_dir/references/zod" env PATH="$nub_dir/bin:$PATH" nub install --frozen-lockfile
run_in "$repo_dir/references/zod" env PATH="$nub_dir/bin:$PATH" nub run build

run_in "$repo_dir/references/valibot" npx --yes pnpm@11.5.0 install --frozen-lockfile
run_in "$repo_dir/references/valibot" npx --yes pnpm@11.5.0 -r --filter='!website' run build

run_in "$repo_dir/references/effect" npx --yes pnpm@11.20.0 install --frozen-lockfile --ignore-scripts
run_in "$repo_dir/references/effect" npx --yes pnpm@11.20.0 --filter effect build
