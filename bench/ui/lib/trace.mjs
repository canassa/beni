// A port of js-framework-benchmark's `webdriver-ts/src/timeline.ts`
// (commit 652198560d0c): `computeResultsCPU`, `computeResultsJS` and
// `computeResultsPaint`, over the events of one trace rather than a file.
// Same event selection, same "first Commit after the last of {click,
// FireAnimationFrame, TimerFire, Layout, FunctionCall}" rule, same >16 ms
// requestAnimationFrame correction, same interval union.

export const categories = ["blink.user_timing", "devtools.timeline", "disabled-by-default-devtools.timeline"];

const traceJSEventNames = ["EventDispatch", "EvaluateScript", "v8.evaluateModule", "FunctionCall", "TimerFire", "FireIdleCallback", "FireAnimationFrame", "RunMicrotasks", "V8.Execute"];
const tracePaintEventNames = ["UpdateLayoutTree", "Layout", "Commit", "Paint", "Layerize", "PrePaint"];

const ev = (type, e, dur = +e.dur) => ({ type, ts: +e.ts, dur, end: +e.ts + dur, pid: e.pid });

function extractRelevantEvents(entries) {
  const out = [];
  for (const e of entries) {
    if (e.name === "EventDispatch") {
      const t = e.args?.data?.type;
      if (t === "click") {
        out.push(ev("startLogicEvent", e));
        out.push(ev("click", e));
      } else if (t === "mousedown") out.push(ev("mousedown", e));
      else if (t === "pointerup") out.push(ev("pointerup", e));
    } else if (e.ph === "X" && e.name === "Layout") out.push(ev("layout", e));
    else if (e.ph === "X" && e.name === "FunctionCall") out.push(ev("functioncall", e));
    else if (e.ph === "X" && e.name === "HitTest") out.push(ev("hittest", e));
    else if (e.ph === "X" && e.name === "Commit") out.push(ev("commit", e));
    else if (e.ph === "X" && e.name === "Paint") out.push(ev("paint", e));
    else if (e.ph === "X" && e.name === "FireAnimationFrame") out.push(ev("fireAnimationFrame", e));
    else if (e.ph === "X" && e.name === "TimerFire") out.push(ev("timerFire", e, 0));
    else if (e.name === "RequestAnimationFrame") out.push(ev("requestAnimationFrame", e, 0));
  }
  return out;
}

export function computeResultsCPU(entries) {
  const events = extractRelevantEvents(entries).sort((a, b) => a.end - b.end);
  const clicks = events.filter((e) => e.type === "startLogicEvent");
  if (clicks.length !== 1) throw new Error(`exactly one click event is expected, got ${clicks.length}`);
  const click = clicks[0];
  const pid = click.pid;
  const during = events.filter((e) => e.ts > click.end || e.type === "click");
  const onMain = during.filter((e) => e.pid === pid);
  const startFrom = onMain.filter((e) => ["startLogicEvent", "click", "fireAnimationFrame", "timerFire", "layout", "functioncall"].includes(e.type));
  const startFromEvent = startFrom.at(-1);
  if (startFromEvent === undefined) throw new Error("no events after the click");
  const commits = onMain.filter((e) => e.type === "commit");
  let commit = commits.find((e) => e.ts > startFromEvent.end);
  if (!commit) {
    if (commits.length === 0) throw new Error("no commit event");
    commit = commits.at(-1);
  }
  let duration = (commit.end - click.ts) / 1000;
  const layouts = onMain.filter((e) => e.type === "layout");
  const rafs = events.filter((e) => e.type === "requestAnimationFrame" && e.ts >= click.ts && e.ts <= click.end);
  const fafs = events.filter((e) => e.type === "fireAnimationFrame" && e.ts >= click.ts && e.ts < commit.ts);
  let rafLongDelay = 0;
  if (rafs.length > 0 && fafs.length > 0) {
    const waitDelay = (fafs[0].ts - click.end) / 1000;
    if (rafs.length === 1 && fafs.length === 1 && waitDelay > 16 && !layouts.some((l) => l.ts < fafs[0].ts)) {
      rafLongDelay = waitDelay - 16;
      duration -= rafLongDelay;
    }
  }
  return { tsStart: click.ts, tsEnd: commit.end, duration, layouts: layouts.length, commits: commits.length, rafLongDelay };
}

function newContainedInterval(outer, intervals) {
  const outerIv = { start: outer.ts, end: outer.end };
  const cleaned = [];
  if (!intervals.some((iv) => outerIv.start >= iv.start && outerIv.end <= iv.end)) cleaned.push(outerIv);
  for (const iv of intervals) if (iv.start < outer.ts || iv.end > outer.end) cleaned.push(iv);
  return cleaned;
}

function fromTrace(cpu, entries, names, includeClick) {
  const within = [];
  for (const e of entries) {
    let x = null;
    if (e.name === "EventDispatch") {
      if (includeClick && e.args?.data?.type === "click") x = { ts: +e.ts, end: +e.ts + +e.dur };
    } else if (e.ph === "X" && names.includes(e.name)) x = { ts: +e.ts, end: +e.ts + +e.dur };
    if (x !== null && x.ts >= cpu.tsStart && x.ts <= cpu.tsEnd) within.push({ ts: x.ts - cpu.tsStart, end: x.end - cpu.tsStart });
  }
  let intervals = [];
  for (const e of within) intervals = newContainedInterval(e, intervals);
  return intervals.reduce((p, c) => p + (c.end - c.start), 0) / 1000;
}

export function analyse(entries) {
  const cpu = computeResultsCPU(entries);
  return {
    total: cpu.duration,
    script: fromTrace(cpu, entries, traceJSEventNames, true),
    paint: fromTrace(cpu, entries, tracePaintEventNames, false),
    commits: cpu.commits,
    rafLongDelay: cpu.rafLongDelay,
  };
}

export const median = (xs) => {
  const s = [...xs].sort((a, b) => a - b);
  const n = s.length;
  return n === 0 ? NaN : n % 2 ? s[(n - 1) / 2] : (s[n / 2 - 1] + s[n / 2]) / 2;
};

export const quantile = (xs, q) => {
  const s = [...xs].sort((a, b) => a - b);
  if (s.length === 0) return NaN;
  const pos = (s.length - 1) * q;
  const lo = Math.floor(pos);
  const hi = Math.ceil(pos);
  return s[lo] + (s[hi] - s[lo]) * (pos - lo);
};

export const sd = (xs) => {
  const m = xs.reduce((a, b) => a + b, 0) / xs.length;
  return Math.sqrt(xs.reduce((a, b) => a + (b - m) ** 2, 0) / Math.max(1, xs.length - 1));
};
