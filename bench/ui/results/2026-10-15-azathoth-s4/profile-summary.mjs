// Sampled self time, not elapsed click time. Native/unattributed `(program)`
// and idle time stay separate; an instrumented profile is not a verdict.
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { gunzipSync } from "node:zlib";
import { fileURLToPath } from "node:url";
const dir = fileURLToPath(new URL("./", import.meta.url));
let text = "Sampling interval requested: 25 µs. Actual time deltas are retained.\n\nSelf times below are averages over fresh pages, under the profiler, **not** comparison timings. Idle and unattributed/native `(program)` time are excluded from the function rows and reported separately.\n\n";
const result = {};
for (const filename of ["profile-update", "profile-rendering"]) {
  const file = dir + filename + (existsSync(dir + filename + ".json.gz") ? ".json.gz" : ".json");
  const bytes = readFileSync(file);
  const raw = JSON.parse(file.endsWith(".gz") ? gunzipSync(bytes) : bytes);
  const groups = new Map();
  for (const row of raw.profiles) {
    const name = `${row.sweep ?? "table-update"}/${row.subject}`;
    let g = groups.get(name);
    if (g === undefined) groups.set(name, g = { pages: 0, idleUs: 0, programUs: 0, functions: new Map() });
    g.pages++;
    const nodes = new Map(row.profile.nodes.map((n) => [n.id, n]));
    row.profile.samples.forEach((id, i) => {
      const f = nodes.get(id).callFrame;
      const us = row.profile.timeDeltas[i] ?? 0;
      if (f.functionName === "(idle)") g.idleUs += us;
      else if (f.functionName === "(program)") g.programUs += us;
      else {
        const key = `${f.functionName || "(anonymous)"} ${f.url}:${f.lineNumber + 1}:${f.columnNumber}`;
        g.functions.set(key, (g.functions.get(key) ?? 0) + us);
      }
    });
  }
  for (const [name, g] of groups) {
    const functions = [...g.functions].sort((a, b) => b[1] - a[1]).map(([name, us]) => ({ name, sampledUs: us, perPageUs: us / g.pages }));
    result[name] = { pages: g.pages, idleUs: g.idleUs, programUs: g.programUs, functions };
    text += `**${name}**, ${g.pages} pages; idle ${(g.idleUs / 1000).toFixed(1)} ms, unattributed/native ${(g.programUs / 1000).toFixed(1)} ms.\n\n| function / URL:line:column | sampled self µs per page |\n|---|--:|\n`;
    for (const f of functions.slice(0, 12)) text += `| ${f.name} | ${f.perPageUs.toFixed(2)} |\n`;
    text += "\n";
  }
}
writeFileSync(dir + "profile-summary.json", JSON.stringify(result, null, 2) + "\n");
writeFileSync(dir + "profile-summary.md", text);
