// The workloads of the fiber runtime benchmark, shared by the Node runner
// (node.mjs) and the page chrome.mjs serves: every one runs `runs` times after
// `warm` warm-up runs, and reports the median time and the time per
// operation. Nothing here knows which host it runs on.

const now = () => performance.now();

const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  return s[s.length >> 1];
};

async function measure(label, ops, run, expect, { warm = 3, runs = 9 } = {}) {
  for (let i = 0; i < warm; i++) {
    const got = await run();
    if (got !== expect) throw new Error(`${label}: ${got}, expected ${expect}`);
  }
  const times = [];
  for (let i = 0; i < runs; i++) {
    const t0 = now();
    await run();
    times.push(now() - t0);
  }
  const ms = median(times);
  return { label, ops, ms: +ms.toFixed(3), nsPerOp: +((ms * 1e6) / ops).toFixed(2), min: +Math.min(...times).toFixed(3), max: +Math.max(...times).toFixed(3) };
}

// A workload that must run in a fiber: started by the beni runtime's
// `start`, answered through the exit it reports.
const inFiber = (beni, work) =>
  new Promise((resolve, reject) =>
    beni.Bench$start(work, (exit) => (exit.$ === "Done" ? resolve(exit.a) : reject(new Error("cancelled")))),
  );

// What a long yielding loop does to the rest of the page (research/16
// §2.3, §6): a `setTimeout(0)` armed as it starts, and — where the host has
// one — a `requestAnimationFrame` asked for then and every frame after.
// Reports when the timer fired, how many frames were painted during the
// run, and the longest gap between two of them.
export async function latency(label, run) {
  const t0 = now();
  let timer = null;
  setTimeout(() => {
    timer = now() - t0;
  }, 0);
  const frames = [];
  let running = true;
  const raf = globalThis.requestAnimationFrame;
  if (typeof raf === "function") {
    const tick = (t) => {
      frames.push(now());
      if (running) raf(tick);
    };
    raf(tick);
  }
  await run();
  const total = now() - t0;
  running = false;
  let gap = 0;
  let last = t0;
  for (const f of frames) {
    gap = Math.max(gap, f - last);
    last = f;
  }
  if (frames.length !== 0) gap = Math.max(gap, t0 + total - last);
  return {
    label,
    ms: +total.toFixed(1),
    timerMs: timer === null ? null : +timer.toFixed(1),
    frames: typeof raf === "function" ? frames.length : null,
    longestFrameGapMs: typeof raf === "function" ? +gap.toFixed(1) : null,
  };
}

export async function all(beni, effect, sizes = {}, progress = () => {}) {
  const n = sizes.calls ?? 10_000_000;
  const seq = sizes.sequenced ?? 2_500_000;
  const y = sizes.yields ?? 1_000_000;
  const f = sizes.fibers ?? 10_000;
  const fy = sizes.effectCalls ?? 1_000_000;
  // Effect parks a yielding fiber on `setImmediate` where the host has it and
  // on `setTimeout(0)` where it does not — every browser — and a nested
  // timer is clamped to 4 ms there, so a page gets its own, smaller count.
  const ey = sizes.effectYields ?? y;
  const out = [];
  out.push(await measure("beni: plain call, in a loop", n, () => beni.Bench$loopPlain(n, 0), n));
  progress(out[out.length - 1].label);
  out.push(await measure("beni: suspension point on its fast path, in a loop", n, () => beni.Bench$loopSuspending(n, 0), n));
  progress(out[out.length - 1].label);
  out.push(await measure("beni: suspension point on its fast path, in sequence", seq * 4, () => beni.Bench$loopSequenced(seq, 0), seq));
  progress(out[out.length - 1].label);
  out.push(await measure("beni: yieldNow (really parks)", y, () => inFiber(beni, () => beni.Bench$loopYielding(y, 0)), y));
  progress(out[out.length - 1].label);
  out.push(await measure(`beni: ${f} fibers spawned, each yields once, joined`, f, () => inFiber(beni, () => beni.Bench$fanOut(f)), (f * (f + 1)) / 2));
  progress(out[out.length - 1].label);
  out.push(await measure("Effect v4: sync op chained by flatMap", fy, () => effect.loopFlatMap(fy), fy));
  progress(out[out.length - 1].label);
  out.push(await measure("Effect v4: sync op in Effect.gen", fy, () => effect.loopGen(fy), fy));
  progress(out[out.length - 1].label);
  out.push(await measure("Effect v4: yieldNow (really parks)", ey, () => effect.loopYielding(ey), ey));
  progress(out[out.length - 1].label);
  out.push(await measure(`Effect v4: ${f} fibers forked, each yields once, joined`, f, () => effect.fanOut(f), (f * (f + 1)) / 2));
  progress(out[out.length - 1].label);
  return out;
}

// The time workloads (transparent-effects-proposal.md §17.6, §17.8;
// `plans/effects-plan.md` §8 P2): `node.mjs --group=time`.
export async function time(beni, effect, sizes = {}, progress = () => {}) {
  const z = sizes.zeroSleeps ?? 200_000;
  const t = sizes.tenHours ?? 2_000;
  const pairs = [
    [`${z} zero-length sleeps`, z, () => inFiber(beni, () => beni.Bench$sleepZero(z, 0)), () => effect.sleepZero(z), z],
    [`ten hours of exponential retry on a virtual clock (report 23 case 5.5), ${t} times`, t, async () => { let s = 0; for (let i = 0; i < t; i++) s += await inFiber(beni, () => beni.Bench$tenHours()); return s; }, async () => { let s = 0; for (let i = 0; i < t; i++) s += await effect.tenHours(); return s; }, 4 * t],
  ];
  const out = [];
  for (const [label, ops, b, e, expect] of pairs) {
    out.push(await measure(`beni: ${label}`, ops, b, expect));
    progress(out[out.length - 1].label);
    out.push(await measure(`Effect v4: ${label}`, ops, e, expect));
    progress(out[out.length - 1].label);
  }
  return out;
}

// The coordination workloads (transparent-effects-proposal.md §17.3–§17.4,
// `plans/effects-plan.md` §8 P1), each beni's and then Effect's: `node.mjs
// --group=coordination`.
export async function coordination(beni, effect, sizes = {}, progress = () => {}) {
  const h = sizes.handoffs ?? 20_000;
  const r = sizes.ready ?? 200_000;
  const u = sizes.updates ?? 1_000_000;
  const d = sizes.detached ?? 20_000;
  const pairs = [
    [`${h} Deferred hand-offs (spawn, wait, complete, join)`, h, () => inFiber(beni, () => beni.Bench$deferredHandoff(h, 0)), () => effect.deferredHandoff(h), h],
    [`${r} Deferreds completed, then waited for`, r, () => inFiber(beni, () => beni.Bench$deferredReady(r, 0)), () => effect.deferredReady(r), r],
    [`${u} Ref.update`, u, () => inFiber(beni, () => beni.Bench$refUpdates(u)), () => effect.refUpdates(u), u],
    [`${d} detached fibers, each joined`, d, () => inFiber(beni, () => beni.Bench$detachJoin(d, 0)), () => effect.detachJoin(d), d],
  ];
  const out = [];
  for (const [label, ops, b, e, expect] of pairs) {
    out.push(await measure(`beni: ${label}`, ops, b, expect));
    progress(out[out.length - 1].label);
    out.push(await measure(`Effect v4: ${label}`, ops, e, expect));
    progress(out[out.length - 1].label);
  }
  return out;
}

// The same yielding loop under each budget (`budgets` maps a label to a
// beni build whose runtime escapes to a macrotask after that many
// resumptions), then Effect's, for `latency`.
export async function sweep(budgets, effect, yields = 200_000, effectYields = yields) {
  const out = [];
  for (const [label, beni] of budgets) {
    await inFiber(beni, () => beni.Bench$loopYielding(1000, 0));
    out.push(await latency(`beni, budget ${label}: ${yields} yieldNow`, () => inFiber(beni, () => beni.Bench$loopYielding(yields, 0))));
  }
  await effect.loopYielding(1000);
  out.push(await latency(`Effect v4 (default scheduler): ${effectYields} yieldNow`, () => effect.loopYielding(effectYields)));
  return out;
}
