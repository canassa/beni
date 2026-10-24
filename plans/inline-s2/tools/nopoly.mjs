// brotli of the app JS (adapter excluded, as rr measures) with and without Vite's modulepreload polyfill
import fs from "node:fs"; import path from "node:path";
const RR = process.env.RR;
const m = await import(RR + "/harness/measure.js");
const { bucketer } = await import(RR + "/harness/sourcemap.js");
const fw = await import(RR + "/frameworks/tea-inline/framework.js");
for (const dir of process.argv.slice(2)) {
  const d = path.join(dir, "dist", "assets");
  const f = fs.readdirSync(d).find((x) => x.endsWith(".js"));
  const code = fs.readFileSync(path.join(d, f), "utf8"), map = JSON.parse(fs.readFileSync(path.join(d, f + ".map"), "utf8"));
  const only = bucketer(code, map, (src) => fw.classify(src), "tooling");
  const js = only("runtime", "tooling", "app"), nop = only("runtime", "app");
  const html = m.brotli(fs.readFileSync(path.join(dir, "dist", "index.html"), "utf8"));
  console.log(path.basename(dir), "js", m.brotli(js), "js-no-polyfill", m.brotli(nop), "delta", m.brotli(js) - m.brotli(nop), "html", html);
}
