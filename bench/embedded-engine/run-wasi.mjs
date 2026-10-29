// node run-wasi.mjs <module.wasm> <dir> <entry> : run a WASI build of the
// prototype host with <dir> preopened as "/", the entry relative to it.
import { WASI } from "node:wasi";
import { readFileSync } from "node:fs";
const [wasmPath, dir, entry] = process.argv.slice(2);
const wasi = new WASI({ version: "preview1", args: ["qhost", "/" + entry], preopens: { "/": dir }, returnOnExit: true });
const mod = await WebAssembly.compile(readFileSync(wasmPath));
const inst = await WebAssembly.instantiate(mod, wasi.getImportObject());
const t = performance.now();
const code = wasi.start(inst);
process.stderr.write(`wasi exit ${code} in ${(performance.now() - t).toFixed(1)} ms\n`);
