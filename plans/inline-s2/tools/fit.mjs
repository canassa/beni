// node fit.mjs file.tsv [minN] : per (emitter,flags): mean at N=1, N=256, fit baseline+slope over N>=minN on total
import fs from "node:fs";
const rows = fs.readFileSync(process.argv[2], "utf8").trim().split("\n").filter((l) => !l.includes("FAIL")).map((l) => { const [e, f, n, s, j] = l.split("\t"); return { k: `${e}/${f}`, n: +n, s: +s, ...JSON.parse(j) }; });
const min = +(process.argv[3] || 4);
const groups = {};
for (const r of rows) (groups[r.k] ||= []).push(r);
const mean = (a) => a.reduce((x, y) => x + y, 0) / a.length;
for (const [k, g] of Object.entries(groups)) {
  const pts = g.filter((r) => r.n >= min);
  const xs = pts.map((r) => r.n), ys = pts.map((r) => r.total);
  const mx = mean(xs), my = mean(ys);
  const slope = xs.reduce((a, x, i) => a + (x - mx) * (ys[i] - my), 0) / xs.reduce((a, x) => a + (x - mx) ** 2, 0);
  const base = my - slope * mx;
  const at = (n) => { const v = g.filter((r) => r.n === n).map((r) => r.total); return v.length ? Math.round(mean(v)) : "-"; };
  const rt = Math.round(mean(g.filter((r) => r.n === 1).map((r) => r.runtime)));
  console.log(`${k}\tN1=${at(1)}\tN256=${at(256)}\tbase=${Math.round(base)}\tslope=${slope.toFixed(1)}\truntime=${rt}`);
}
