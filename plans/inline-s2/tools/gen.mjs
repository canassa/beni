// Usage: node gen.mjs <scenario> <emitter> <size> <seed> <outdir> [k=v ...]
// Runs the research repo's spec + emitter into outdir (outside the research repo), then builds.
import fs from "node:fs";
import path from "node:path";
const RR = process.env.RR;
const [scenario, emitterName, size, seed, out, ...rest] = process.argv.slice(2);
const sel = await import(RR + "/harness/selection.js");
const sc = await sel.loadScenario(scenario);
let em;
if (emitterName.includes("/")) { const mod = await import(emitterName); const framework = await import(RR + "/frameworks/" + mod.framework + "/framework.js"); em = { name: "custom", mod, framework }; }
else em = await sel.loadEmitter(scenario, emitterName);
const opts = { size: Number(size), seed: Number(seed) };
for (const kv of rest) { const [k, v] = kv.split("="); opts[k] = v; }
const { scenarioOptions: so0, emitterOptions } = sel.splitOptions(opts, sc, [em]); const so = so0;
so.size = opts.size; so.seed = opts.seed;
const spec = sc.mod.generate(so);
const eo = emitterOptions(em);
const { files } = em.mod.emit(spec, eo);
fs.rmSync(out, { recursive: true, force: true });
for (const [rel, c] of Object.entries(files)) { const f = path.join(out, rel); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, c); }
fs.writeFileSync(path.join(out, "spec.json"), JSON.stringify(spec, null, 1));
fs.writeFileSync(path.join(out, "fw.json"), JSON.stringify({ framework: em.mod.framework }));
if (process.env.NOBUILD) process.exit(0);
// prepare: absolute node_modules symlink
const fwDir = path.join(RR, "frameworks", em.mod.framework);
if (fs.existsSync(path.join(fwDir, "node_modules"))) fs.symlinkSync(path.join(fwDir, "node_modules"), path.join(out, "node_modules"));
const built = await em.framework.build(out);
console.log(JSON.stringify(built));
