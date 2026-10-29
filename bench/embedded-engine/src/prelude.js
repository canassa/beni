// Host prelude: the Node globals the emitted code reaches, made from one host
// function, __write(fd, s). Timers run on a virtual clock, in (time, id) order.
(() => {
  const w = globalThis.__write;
  const fmt = (a) => a.map(String).join(" ") + "\n";
  globalThis.console = {
    log: (...a) => w(1, fmt(a)), info: (...a) => w(1, fmt(a)),
    error: (...a) => w(2, fmt(a)), warn: (...a) => w(2, fmt(a)),
  };
  let now = 0, seq = 0;
  const timers = [];
  globalThis.setTimeout = (f, ms, ...args) => {
    const id = ++seq;
    ms = Number(ms); if (!(ms >= 1)) ms = 1;
    timers.push({ id, at: now + ms, f, args });
    return id;
  };
  globalThis.clearTimeout = (id) => {
    const i = timers.findIndex((t) => t.id === id);
    if (i >= 0) timers.splice(i, 1);
  };
  globalThis.setImmediate = (f, ...args) => globalThis.setTimeout(f, 0, ...args);
  globalThis.queueMicrotask = (f) => { Promise.resolve().then(f); };
  // Node's process, as far as the node platform reads it from globalThis.
  const handlers = [];
  globalThis.process = {
    stdout: { write: (s) => { w(1, String(s)); return true; } },
    stderr: { write: (s) => { w(2, String(s)); return true; } },
    argv: [], env: {},
    on(ev, f) { if (ev === "beforeExit") handlers.push(f); return this; },
    once(ev, f) { return this.on(ev, f); },
    off() { return this; }, removeListener() { return this; },
    set exitCode(v) { globalThis.__exitCode = v; }, get exitCode() { return globalThis.__exitCode; },
  };
  // Node emits beforeExit each time the loop empties; the host loops while
  // a handler schedules more work.
  globalThis.__beforeExit = () => {
    for (const f of handlers.slice()) f(globalThis.__exitCode);
    return handlers.length > 0;
  };
  globalThis.__pending = () => timers.length > 0;
  globalThis.__tick = () => {
    if (timers.length === 0) return false;
    let k = 0;
    for (let i = 1; i < timers.length; i++)
      if (timers[i].at < timers[k].at || (timers[i].at === timers[k].at && timers[i].id < timers[k].id)) k = i;
    const [t] = timers.splice(k, 1);
    now = t.at;
    t.f(...t.args);
    return true;
  };
})();
