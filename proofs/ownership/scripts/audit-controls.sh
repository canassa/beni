#!/usr/bin/env bash
# Run after lake build. Use the shared lock and memory caps.
# This script writes only to a fresh directory under this worktree's scratch.
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
worktree_root=$(git -C "$script_dir" rev-parse --show-toplevel)
package_dir="$worktree_root/proofs/ownership"
audit_bin="$package_dir/.lake/build/bin/audit"
base_lean_path="$package_dir/.lake/build/lib/lean${LEAN_PATH:+:$LEAN_PATH}"

command -v lean >/dev/null
command -v rg >/dev/null
command -v python3 >/dev/null
if [[ ! -x "$audit_bin" ]]; then
  printf 'Build the current audit executable first: %s\n' "$audit_bin" >&2
  exit 1
fi

mkdir -p -- "$worktree_root/zig-out/scratch"
test_root=$(mktemp -d "$worktree_root/zig-out/scratch/audit-negative.XXXXXX")
printf 'Audit negative-test artifacts: %s\n' "$test_root"
git -C "$worktree_root" rev-parse HEAD > "$test_root/head.txt"
sha256sum "$package_dir/Audit.lean" "$package_dir/Axioms.lean" \
  "$package_dir/lakefile.toml" "$audit_bin" "${BASH_SOURCE[0]}" > "$test_root/inputs.sha256"
git -C "$worktree_root" show HEAD:proofs/ownership/Ownership.lean \
  > "$test_root/head-Ownership.lean.txt"

compile_ok() {
  local log_file=$1
  shift
  if ! "$@" > "$log_file" 2>&1; then
    cat "$log_file" >&2
    printf 'Unexpected compilation failure: %s\n' "$log_file" >&2
    return 1
  fi
}

expect_reject() {
  local label=$1 log_file=$2 expected=$3 result=0
  shift 3
  "$@" > "$log_file" 2>&1 || result=$?
  if [[ "$result" -eq 0 ]]; then
    cat "$log_file" >&2
    printf 'Unexpected success: %s\n' "$label" >&2
    return 1
  fi
  if ! rg -Fq -- "$expected" "$log_file"; then
    cat "$log_file" >&2
    printf 'Wrong rejection: %s\nExpected: %s\n' "$label" "$expected" >&2
    return 1
  fi
  printf 'PASS: %s (exit %s)\n' "$label" "$result"
}

assert_duplicate_before_dispatch() {
  local log_file=$1
  rg -Fq -- 'Ownership.AuditProbeA' "$log_file"
  rg -Fq -- 'Ownership.AuditProbeB' "$log_file"
  if rg -Fq -- 'audit module:' "$log_file"; then
    printf 'The duplicate guard ran after child dispatch: %s\n' "$log_file" >&2
    return 1
  fi
}

run_lean_in() {
  local case_dir=$1
  shift
  (cd -- "$case_dir" && lean -R "$case_dir" "$@")
}

# A real small module must replay and return one well-formed positive receipt.
export LEAN_PATH="$base_lean_path"
compile_ok "$test_root/module-success.log" "$audit_bin" module Ownership.Syntax
if [[ $(wc -l < "$test_root/module-success.log") -ne 1 ]] || \
    ! rg -xq 'audit module: Ownership\.Syntax: [1-9][0-9]*' "$test_root/module-success.log"; then
  cat "$test_root/module-success.log" >&2
  printf 'The small-module replay returned an invalid receipt.\n' >&2
  exit 1
fi
printf 'PASS: native small-module replay receipt\n'

# A forbidden module must fail before import or replay.
expect_reject 'native module Std refusal' "$test_root/std-refusal.log" \
  'module outside audit scope: Std' "$audit_bin" module Std

# Compile the two probes independently. Neither probe imports the other.
duplicate_root="$test_root/duplicates"
mkdir -p -- "$duplicate_root"
# Lean selects the first module-prefix directory. Keep every imported artifact
# under that prefix beside the probes, including private and server artifacts.
cp -a --reflink=auto -- "$package_dir/.lake/build/lib/lean/Ownership" \
  "$duplicate_root/Ownership"
cat > "$duplicate_root/Ownership/AuditProbeA.lean" <<'LEAN'
import Std
theorem Ownership.auditDuplicate : True := True.intro
LEAN
cp -- "$duplicate_root/Ownership/AuditProbeA.lean" \
  "$duplicate_root/Ownership/AuditProbeB.lean"
export LEAN_PATH="$duplicate_root:$base_lean_path"
for probe in AuditProbeA AuditProbeB; do
  compile_ok "$duplicate_root/$probe.log" lean -R "$duplicate_root" \
    -o "$duplicate_root/Ownership/$probe.olean" \
    "$duplicate_root/Ownership/$probe.lean"
done
cp -- "$test_root/head-Ownership.lean.txt" "$duplicate_root/Ownership.lean"
cat >> "$duplicate_root/Ownership.lean" <<'LEAN'

import Ownership.AuditProbeA
import Ownership.AuditProbeB
LEAN
compile_ok "$duplicate_root/root.log" lean -R "$duplicate_root" \
  -o "$duplicate_root/Ownership.olean" "$duplicate_root/Ownership.lean"

expect_reject 'native env duplicate guard' "$duplicate_root/native-env.log" \
  'duplicate declaration Ownership.auditDuplicate' "$audit_bin" env
assert_duplicate_before_dispatch "$duplicate_root/native-env.log"

cp -- "$package_dir/Axioms.lean" "$duplicate_root/Axioms.lean"
expect_reject 'in-build duplicate guard' "$duplicate_root/in-build.log" \
  'duplicate declaration Ownership.auditDuplicate' run_lean_in "$duplicate_root" \
  -o "$duplicate_root/Axioms.olean" "$duplicate_root/Axioms.lean"
assert_duplicate_before_dispatch "$duplicate_root/in-build.log"

# The actual Axioms parent must propagate a nonzero child exit.
# This wrapper occupies only the scratch parent's relative executable path.
failure_root="$test_root/child-failure"
mkdir -p -- "$failure_root/.lake/build/bin"
cp -a --reflink=auto -- "$package_dir/.lake/build/lib/lean/Ownership" \
  "$failure_root/Ownership"
cp -- "$test_root/head-Ownership.lean.txt" "$failure_root/Ownership.lean"
cp -- "$package_dir/Axioms.lean" "$failure_root/Axioms.lean"
cat > "$failure_root/.lake/build/bin/audit" <<'SH'
#!/usr/bin/env bash
exit 73
SH
chmod +x "$failure_root/.lake/build/bin/audit"
export LEAN_PATH="$failure_root:$base_lean_path"
compile_ok "$failure_root/root.log" lean -R "$failure_root" \
  -o "$failure_root/Ownership.olean" "$failure_root/Ownership.lean"
expect_reject 'in-build child failure propagation' "$failure_root/in-build.log" \
  'module replay failed:' run_lean_in "$failure_root" \
  -o "$failure_root/Axioms.olean" "$failure_root/Axioms.lean"
rg -Fq -- '(exit 73)' "$failure_root/in-build.log"

# A zero-exit child with a wrong receipt must also fail in the real Axioms parent.
cat > "$failure_root/.lake/build/bin/audit" <<'SH'
#!/usr/bin/env bash
printf 'not a replay receipt\n'
exit 0
SH
expect_reject 'in-build wrong receipt refusal' "$failure_root/wrong-receipt.log" \
  'module replay receipt mismatch:' run_lean_in "$failure_root" \
  -o "$failure_root/Axioms-wrong-receipt.olean" "$failure_root/Axioms.lean"

# Exercise the actual independent parent's helper without its full env scan.
# Under #eval, appPath names Lean. Its module-mode arguments fail in Lean.
# The helper must propagate that child failure as its own error.
helper_root="$test_root/independent-helper"
mkdir -p -- "$helper_root"
cat > "$helper_root/AuditChildFailure.lean" <<'LEAN'
import Audit
#eval Audit.checkModuleChild `Ownership.Syntax 0
LEAN
export LEAN_PATH="$helper_root:$base_lean_path"
expect_reject 'independent helper child failure propagation' "$helper_root/compile.log" \
  'module replay failed: Ownership.Syntax' run_lean_in "$helper_root" \
  -o "$helper_root/AuditChildFailure.olean" "$helper_root/AuditChildFailure.lean"

# Test the unchanged independent helper with a native test dispatcher.
# Copy the current Audit source and replace only its CLI main. The child mode
# returns a zero-exit wrong receipt. The parent mode calls the real helper.
# Native execution is required: under lean --run, IO.appPath names Lean.
receipt_root="$test_root/independent-receipt"
mkdir -p -- "$receipt_root"
export LEAN_PATH="$base_lean_path"
compile_ok "$receipt_root/build.log" python3 - "$package_dir" "$receipt_root" <<'PY'
import json
from pathlib import Path
import shlex
import subprocess
import sys

package = Path(sys.argv[1])
scratch = Path(sys.argv[2])
audit_source = (package / 'Audit.lean').read_text()
marker = '\ndef main (args : List String) : IO UInt32 := do\n'
if audit_source.count(marker) != 1:
    raise SystemExit('Audit main shape changed; inspect the native test dispatcher')
prefix, _ = audit_source.split(marker)
source = scratch / 'AuditReceipt.lean'
source.write_text(prefix + '''
def main (args : List String) : IO UInt32 := do
  match args with
  | ["module", _] =>
    IO.println "not a replay receipt"
    pure 0
  | [] =>
    Audit.checkModuleChild `Ownership.Syntax 0
    pure 0
  | _ => pure 2
''')
c_source = scratch / 'AuditReceipt.c'
obj = scratch / 'AuditReceipt.o'
binary = scratch / 'audit-receipt'
subprocess.run(['lean', '-R', str(scratch), '-o', str(scratch / 'AuditReceipt.olean'),
                '-c', str(c_source), str(source)], cwd=package, check=True)

def read_command(trace):
    data = json.loads(trace.read_text())
    if data.get('schemaVersion') != '2025-09-10':
        raise SystemExit(f'Unsupported Lake trace schema: {trace}')
    commands = [item['message'][3:] for item in data.get('log', [])
                if isinstance(item.get('message'), str) and item['message'].startswith('.> ')]
    if len(commands) != 1:
        raise SystemExit(f'Expected exactly one command in {trace}')
    return shlex.split(commands[0])

def replace_unique(args, before, after):
    if args.count(str(before)) != 1:
        raise SystemExit(f'Expected exactly one path {before} in {args!r}')
    args[args.index(str(before))] = str(after)

def replace_output(args, before, after):
    if args.count('-o') != 1:
        raise SystemExit(f'Expected exactly one output option: {args!r}')
    index = args.index('-o') + 1
    if index >= len(args) or args[index] != str(before):
        raise SystemExit(f'Unexpected output path: {args!r}')
    args[index] = str(after)

old_c = package / '.lake/build/ir/Audit.c'
old_obj = package / '.lake/build/ir/Audit.c.o.export'
compile_args = read_command(package / '.lake/build/ir/Audit.c.o.export.trace')
if compile_args.count('-c') != 1:
    raise SystemExit('Audit compile command no longer contains one -c option')
replace_unique(compile_args, old_c, c_source)
replace_output(compile_args, old_obj, obj)
link_args = read_command(package / '.lake/build/bin/audit.trace')
if '-c' in link_args:
    raise SystemExit('Audit link command unexpectedly compiles a source')
replace_unique(link_args, old_obj, obj)
replace_output(link_args, package / '.lake/build/bin/audit', binary)
(scratch / 'native-argv.json').write_text(json.dumps(
    {'compile': compile_args, 'link': link_args}, indent=2) + '\n')
subprocess.run(compile_args, cwd=package, check=True)
subprocess.run(link_args, cwd=package, check=True)
PY
expect_reject 'independent helper wrong receipt refusal' "$receipt_root/run.log" \
  'module replay receipt mismatch: Ownership.Syntax' "$receipt_root/audit-receipt"

printf 'One positive receipt and all seven negative controls passed. Logs: %s\n' "$test_root"
