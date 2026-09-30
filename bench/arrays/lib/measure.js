// The timing loop of research/38 (§13's harness.js, unchanged in method), shared by every harness in
// bench/arrays: warm up for at least WARM_MS and 3 calls, then 7 samples of at least 10 ms of
// repeated calls each (3 samples when a call exceeds 400 ms, 1 above 1.5 s), and report the median,
// quartiles and range in nanoseconds per `per` units. The caller runs a full GC before each cell.
//
// One addition for the combined batch (all.mjs): a call slower than CAP_MS is not repeated at all.
// Its one cold call is the figure (S = 0), because a cell that costs tens of seconds a call is
// reported as "over the cap", not ranked to three digits.
const env = globalThis.process?.env ?? {};
export const CFG = { minMs: 10, warmMs: +(env.WARM_MS ?? 25), samples: 7, maxCallMs: 400, hugeMs: 1500, capMs: +(env.CAP_MS ?? Infinity) };
export const now = typeof performance !== 'undefined' ? () => performance.now() : () => Date.now();
export let sink = null;
export const keep = (x) => { sink = x; };

export function measure(fn, per = 1) {
  let t0 = now(), calls = 0;
  do { sink = fn(); calls++; } while ((calls < 3 && now() - t0 < CFG.maxCallMs && now() - t0 < CFG.capMs) || now() - t0 < CFG.warmMs);
  const one = (now() - t0) / calls;
  if (one > CFG.capMs) return { med: one * 1e6 / per, lo: one * 1e6 / per, hi: one * 1e6 / per, q1: one * 1e6 / per, q3: one * 1e6 / per, S: 0 };
  const k = Math.max(1, Math.ceil(CFG.minMs / Math.max(one, 1e-6)));
  const S = one > CFG.hugeMs ? 1 : one > CFG.maxCallMs ? 3 : CFG.samples;
  const xs = [];
  for (let s = 0; s < S; s++) { const a = now(); for (let i = 0; i < k; i++) sink = fn(); xs.push(((now() - a) / k) * 1e6 / per); }
  xs.sort((a, b) => a - b);
  const q = (p) => xs[Math.min(xs.length - 1, Math.floor(p * (xs.length - 1) + 0.5))];
  return { med: q(0.5), lo: xs[0], hi: xs[xs.length - 1], q1: q(0.25), q3: q(0.75), S };
}

// one JSON line per cell, four significant digits
export const cellLine = (base, r) => {
  const p = (x) => +x.toPrecision(4);
  return JSON.stringify({ ...base, med: p(r.med), q1: p(r.q1), q3: p(r.q3), lo: p(r.lo), hi: p(r.hi), S: r.S });
};
