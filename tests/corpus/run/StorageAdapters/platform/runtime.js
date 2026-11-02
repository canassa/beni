// Fixture instrumentation of the host, outside the compiler/program boundary.
export function run(main) {
  const line = text => process.stdout.write(text + "\n");
  line(main.b);
  let local = null, session = null, localFault = null, sessionFault = null;
  Object.defineProperty(globalThis, "localStorage", { configurable: true, get() { if (localFault) throw localFault; return local; } });
  Object.defineProperty(globalThis, "sessionStorage", { configurable: true, get() { if (sessionFault) throw sessionFault; return session; } });
  function expectFault(label, phase, expected) {
    try { main.a(phase); throw new Error("the storage failure was swallowed"); }
    catch (error) { if (error !== expected) throw error; line(label); }
  }
  line("null: " + main.a(0) + "/" + main.a(1));
  localFault = new DOMException("blocked", "SecurityError");
  line("security: " + main.a(0) + "/" + main.a(1));
  localFault = null;
  sessionFault = new DOMException("blocked", "SecurityError");
  line("session security: " + main.a(2));
  sessionFault = null;
  const items = new Map([["key", "old"], ["a", "A"]]);
  local = {
    get length() { return items.size; },
    key(index) { return Array.from(items.keys())[index] ?? null; },
    getItem(key) { return items.get(key) ?? null; },
    setItem(key, value) { items.set(key, value); },
    removeItem(key) { items.delete(key); }
  };
  line("normal: " + main.a(0) + "/" + main.a(1) + "/" + main.a(3) + "/" + main.a(4) + "/" + main.a(0));
  local.setItem = () => { throw new DOMException("full", "QuotaExceededError"); };
  line("quota: " + main.a(1));
  const getter = Object.assign(new Error("getter"), { name: "SecurityError" });
  localFault = getter;
  expectFault("non-DOM security unchanged", 0, getter);
  localFault = null;
  const quota = Object.assign(new Error("write"), { name: "QuotaExceededError" });
  local.setItem = () => { throw quota; };
  expectFault("non-DOM quota unchanged", 1, quota);
  const write = new DOMException("write", "SecurityError");
  local.setItem = () => { throw write; };
  expectFault("write security unchanged", 1, write);
  const read = new Error("read");
  local.getItem = () => { throw read; };
  expectFault("get error unchanged", 0, read);
  local = { length: 2, key(index) { return index === 0 ? null : "tail"; } };
  line("missing key: " + main.a(3));
}
