// The playground's compiler, in a Web Worker (docs/design/playground.md
// §4.1): a compile does not stop the page.
//
// The worker compiles `beni.wasm` once to a `WebAssembly.Module` and runs
// each compile on a new instance with a new file system (§3, rule 1). A
// request is `{ id, platform, source }`; the answer is
// `{ kind: "result", id, code, crash, stdout, stderr, files, ms }`, where
// `files` maps each path under `out/` to its text. An exception the worker
// did not foresee is not caught: the `error` and `unhandledrejection`
// listeners send it to the page as `{ kind: "defect", message }`.
import { directoryOf, filesOf, run } from "./wasi.js";

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

self.addEventListener("message", async ({ data }) => {
  const module = await compiler;
  const started = performance.now();
  const root = directoryOf({ "Main.beni": data.source });
  const args = ["beni", "build", `--platform=${data.platform}`, "--no-cache", "--no-source-maps", "Main.beni"];
  const result = await run(module, args, root);
  const files = {};
  for (const [path, bytes] of filesOf(root)) {
    if (path.startsWith("out/")) files[path.slice("out/".length)] = decoder.decode(bytes);
  }
  self.postMessage({
    kind: "result",
    id: data.id,
    code: result.code,
    crash: result.crash === null ? null : String(result.crash),
    stdout: decoder.decode(result.stdout),
    stderr: decoder.decode(result.stderr),
    files,
    ms: performance.now() - started,
  });
});
