// The playground's compiler, in a Web Worker (docs/design/playground.md
// §4.1): a compile does not stop the page.
//
// The worker compiles `beni.wasm` once to a `WebAssembly.Module` and runs
// each command on a new instance with a new file system (§3, rule 1). A
// request is `{ id, command, platform, source }`, where `command` is
// `build`, `types` or `ownership` (§4.4); the answer is
// `{ kind: "result", id, command, code, crash, crashKind, stdout, stderr,
// files, ms }`, where `crashKind` is `stack` or `trap` (§3, rule 7),
// `stderr` holds the diagnostics as JSON (`--diagnostics=json`), and `files`
// maps each path a build wrote under `out/`, its default output directory,
// to its text. An exception the worker did not foresee is not caught: the
// `error` and `unhandledrejection` listeners send it to the page as
// `{ kind: "defect", message }`.
import { directoryOf, filesOf, isStackExhausted, run } from "./wasi.js";

const decoder = new TextDecoder();

self.addEventListener("error", (event) => {
  self.postMessage({ kind: "defect", message: event.error instanceof Error ? (event.error.stack ?? String(event.error)) : event.message });
});
self.addEventListener("unhandledrejection", (event) => {
  self.postMessage({ kind: "defect", message: event.reason instanceof Error ? (event.reason.stack ?? String(event.reason)) : String(event.reason) });
});

async function load() {
  const started = performance.now();
  const response = await fetch(new URL("beni.wasm", import.meta.url));
  if (!response.ok) throw new Error(`cannot load beni.wasm: HTTP ${response.status}`);
  const module = await WebAssembly.compile(await response.arrayBuffer());
  self.postMessage({ kind: "ready", ms: performance.now() - started });
  return module;
}

const compiler = load();

// The arguments of each command, after the platform flag.
const commands = {
  build: (platform) => ["beni", "build", platform, "--no-cache", "--no-source-maps", "--diagnostics=json", "Main.beni"],
  types: (platform) => ["beni", "dump", "--stage=types", platform, "--diagnostics=json", "Main.beni"],
  ownership: (platform) => ["beni", "dump", "--stage=ownership", platform, "--diagnostics=json", "Main.beni"],
};

self.addEventListener("message", async ({ data }) => {
  const module = await compiler;
  const started = performance.now();
  const root = directoryOf({ "Main.beni": data.source });
  const args = commands[data.command](`--platform=${data.platform}`);
  const result = await run(module, args, root);
  const files = {};
  for (const [path, bytes] of filesOf(root)) {
    if (path.startsWith("out/")) files[path.slice("out/".length)] = decoder.decode(bytes);
  }
  self.postMessage({
    kind: "result",
    id: data.id,
    command: data.command,
    code: result.code,
    crash: result.crash === null ? null : String(result.crash),
    crashKind: result.crash === null ? null : isStackExhausted(result.crash) ? "stack" : "trap",
    stdout: decoder.decode(result.stdout),
    stderr: decoder.decode(result.stderr),
    files,
    ms: performance.now() - started,
  });
});
