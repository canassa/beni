// Run beni's WebAssembly compiler as a command, on the playground's own
// WASI host (docs/design/playground.md §3, §6):
//
//   node --liftoff-only tests/wasm/beni.mjs <beni.wasm> <arg>…
//
// It loads every file under the working directory into the host's file
// system in memory, runs `beni <arg>…` on it, writes the two streams to
// this process's own, writes every file the run made or changed back to
// the working directory, and exits with the command's exit code. So it is
// a stand-in for the native `beni` that a black-box test runs in the same
// way, and compares byte for byte (`tests/blackbox/wasm_test.zig`).
//
// `--liftoff-only`: V8 compiles hot functions again with TurboFan, on
// background threads, which costs more than it saves in one short run
// (playground.md §6).
import { mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { directoryOf, filesOf, run } from "../../playground/wasi.js";

const [wasmPath, ...args] = process.argv.slice(2);
if (wasmPath === undefined) {
  process.stderr.write("usage: node tests/wasm/beni.mjs <beni.wasm> <arg>…\n");
  process.exit(2);
}

/// Every regular file under `dir`, by its path relative to `dir`.
function readTree(dir, prefix = "", into = new Map()) {
  for (const entry of readdirSync(join(dir, prefix), { withFileTypes: true })) {
    const rel = prefix + entry.name;
    if (entry.isDirectory()) readTree(dir, `${rel}/`, into);
    else if (entry.isFile()) into.set(rel, readFileSync(join(dir, rel)));
  }
  return into;
}

const before = readTree(".");
const module = await WebAssembly.compile(readFileSync(wasmPath));
const result = await run(module, ["beni", ...args], directoryOf(before));

for (const [path, bytes] of filesOf(result.root)) {
  const old = before.get(path);
  if (old !== undefined && Buffer.compare(old, bytes) === 0) continue;
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, bytes);
}
process.stdout.write(result.stdout);
process.stderr.write(result.stderr);
// A crash fails the run as a crash: Node prints it and exits 1.
if (result.crash !== null) throw result.crash;
process.exitCode = result.code;
