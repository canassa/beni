// node check.mjs <scenario> <emitter|path> <size> <seed> [k=v...] : build into scratch and run rr's script check (same-task included).
import fs from "node:fs"; import path from "node:path"; import { execFileSync } from "node:child_process";
const RR = process.env.RR;
const S = process.env.S2DIR, T = import.meta.dirname;
const [scenario, em, size, seed, ...rest] = process.argv.slice(2);
const out = `${S}/out/check-${scenario}-${path.basename(em, ".js")}-${process.env.S2 || "none"}-n${size}-s${seed}`;
execFileSync("node", [`${T}/gen.mjs`, scenario, em, size, seed, out, ...rest], { stdio: ["ignore", "ignore", "inherit"], env: process.env });
const spec = JSON.parse(fs.readFileSync(path.join(out, "spec.json"), "utf8"));
const sel = await import(RR + "/harness/selection.js");
const sc = await sel.loadScenario(scenario);
const { serveHandler } = await import(RR + "/harness/serve.js");
const { listen } = await import(RR + "/harness/tunnel.js");
const { launch } = await import(RR + "/harness/chrome.js");
const { scriptCheck, checkReport } = await import(RR + "/harness/check.js");
const handler = serveHandler(sc, spec, new Map([["v", path.join(out, "dist")]]));
const server = await listen(handler, 0);
const chrome = await launch();
try {
  const r = await scriptCheck(chrome, `http://127.0.0.1:${server.address().port}/v/`, { sameTask: true });
  console.log(checkReport(scenario, process.env.S2 || "tea", spec, r).text);
} finally { await chrome.close(); server.close(); server.closeAllConnections?.(); }
