// node measure.mjs <appdir> : the research harness's measureBuild on a built app (read-only use).
import fs from "node:fs"; import path from "node:path";
const RR = process.env.RR;
const m = await import(RR + "/harness/measure.js");
const dir = process.argv[2];
const rr = JSON.parse(fs.readFileSync(path.join(dir, "fw.json"), "utf8"));
const fw = await import(RR + `/frameworks/${rr.framework}/framework.js`);
const d = path.join(dir, "dist"); const assets = fs.existsSync(path.join(d, "assets")) ? path.join(d, "assets") : d;
const scripts = fs.readdirSync(assets).filter((f) => f.endsWith(".js")).map((f) => ({ file: path.join(assets, f), map: path.join(assets, f + ".map") }));
const r = m.measureBuild({ html: path.join(d, "index.html"), scripts }, fw);
console.log(JSON.stringify({ total: r.total.br, html: r.html.br, js: r.js.br, runtime: r.attribution.br.runtime, app: r.attribution.br.app }));
