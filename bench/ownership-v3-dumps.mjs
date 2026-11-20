// ownership-v3-dumps.mjs: `beni dump --stage=ownership --ownership-everywhere --ownership=v3` of every
// root of `bench/ownership-roots.mjs`, one file per root, `<out>/<name>.txt` (the root's path with `/` as
// `__`; its first line is the root's path and the dump's exit code), and `<out>/INDEX`. Two such
// directories, from the compiler before and after a change, diff file by file: the verdict changes of a
// slice (research report 165 §10). The sources a root copies go to a directory under `TMPDIR`, which
// the caller removes.
//
//     TMPDIR=<disk> node bench/ownership-v3-dumps.mjs <beni> <out> [jobs]
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { spawn } from "node:child_process";
const [beni, out, jobsArg] = process.argv.slice(2);
const repo = join(dirname(new URL(import.meta.url).pathname), "..");
const { o1Roots } = await import(join(repo, "bench/ownership-roots.mjs"));
mkdirSync(out, { recursive: true });
const scratch = mkdtempSync(join(process.env.TMPDIR, "roots-"));
const roots = o1Roots(repo, scratch);
const jobs = Number(jobsArg ?? 8);
let next = 0;
const index = [];
function run(r, i) {
  return new Promise((res) => {
    const p = spawn("timeout", ["300", beni, "dump", "--stage=ownership", "--ownership-everywhere", "--ownership=v3", ...r.argv], { cwd: repo });
    let s = "";
    p.stdout.on("data", (d) => (s += d));
    p.stderr.on("data", (d) => (s += d));
    p.on("close", (code) => { writeFileSync(join(out, `${r.name.replaceAll("/", "__")}.txt`), `# ${r.name} exit ${code}\n` + s); res(); });
  });
}
async function worker() { while (next < roots.length) { const i = next++; index[i] = roots[i].name; await run(roots[i], i); } }
await Promise.all(Array.from({ length: jobs }, worker));
writeFileSync(join(out, "INDEX"), index.map((n, i) => `${i} ${n}`).join("\n") + "\n");
console.log(`${roots.length} roots`);
