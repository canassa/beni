// Research 59 Q2: does a record of about 1 020 fields fall off V8's fast
// path? For each width W, an object literal of W fields (as beni's release
// `init` writes one) and the update the width page's `update` compiles to,
// `{ ...m, k: m.k + 1 }`, timed in a loop of as many spreads as take about
// `budget` ms, 15 runs, median and IQR; with `--allow-natives-syntax` (Node)
// it also says whether the literal and the spread's result have fast
// properties. `plumbing.mjs --mode=spread` runs the same source in Chrome.
//
//   node --allow-natives-syntax spread-micro.mjs [--widths=256,512,…] [--budget=5]

export const microSource = `
function micro(widths, budgetMs, natives, each) {
  const out = [];
  for (const w of widths) {
    // A literal of W fields, f0 … fW−1, built by the engine's literal path.
    const lit = new Function("return {" + Array.from({ length: w }, (_, i) => "f" + i + ":" + i).join(",") + "};")();
    const key = "f" + Math.floor(w / 2);
    const step = new Function("m", "return { ...m, " + key + ": m." + key + " + 1 };");
    let m = lit;
    for (let i = 0; i < 20; i++) m = step(m);
    // As many spreads per run as take about budgetMs, found once.
    let n = 1;
    for (;;) {
      const t0 = performance.now();
      for (let i = 0; i < n; i++) m = step(m);
      if (performance.now() - t0 >= budgetMs / 4 || n >= 1e6) break;
      n *= 4;
    }
    n *= 4;
    const runs = [];
    for (let r = 0; r < 15; r++) {
      const t0 = performance.now();
      for (let i = 0; i < n; i++) m = step(m);
      runs.push(((performance.now() - t0) * 1e6) / n);
    }
    runs.sort((a, b) => a - b);
    const row = { w, n, ns: runs[7], q1: runs[3], q3: runs[11], nsPerField: runs[7] / w };
    if (natives) {
      row.literalFast = natives.fast(lit);
      row.spreadFast = natives.fast(m);
    }
    out.push(row);
    if (each) each(row);
  }
  return out;
}`;

if (typeof process !== "undefined" && import.meta.url === `file://${process.argv[1]}`) {
  const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;
  const widths = arg("widths", "64,127,128,256,512,1000,1016,1019,1020,1021,1024,1030,2048").split(",").map(Number);
  let natives = null;
  try {
    natives = { fast: new Function("o", "return %HasFastProperties(o);") };
  } catch {}
  const micro = new Function(`${microSource}; return micro;`)();
  console.log(`node ${process.version}, V8 ${process.versions.v8}${natives ? "" : " (no --allow-natives-syntax: fast-property columns omitted)"}`);
  console.log("| W | ns per spread [IQR] | ns per field | literal fast | spread result fast |");
  console.log("|--:|--:|--:|:-:|:-:|");
  micro(widths, Number(arg("budget", "5")), natives, (r) =>
    console.log(`| ${r.w} | ${r.ns.toFixed(0)} [${r.q1.toFixed(0)}–${r.q3.toFixed(0)}] | ${r.nsPerField.toFixed(2)} | ${r.literalFast ?? "—"} | ${r.spreadFast ?? "—"} |`),
  );
}
