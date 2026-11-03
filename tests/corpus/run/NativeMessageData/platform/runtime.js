// Frozen pre-specialization validator (763c76b83d): differential oracle.
const referenceDataOnly = (event) => { const value = event.data; const listToken = undefined;
  const data = (object, key) => {
    if (object === null || typeof object !== "object") return undefined;
    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    return descriptor && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined;
  };
  const pending = [value];
  const seen = new Set();
  const views = new Map();
  while (pending.length) {
    const current = pending.pop();
    if (current === null) continue;
    const kind = typeof current;
    if (kind === "function" || kind === "symbol" || kind === "bigint") return { $: "Nothing", a: null };
    if (kind !== "object") continue;
    if (seen.has(current)) continue;
    seen.add(current);
    if (listToken !== undefined && data(current, "$t") === listToken) {
      const count = data(current, "length");
      const elements = new Array(count);
      const header = data(current, "$h");
      if (header === undefined) {
        const base = data(current, "b");
        const offset = data(current, "o");
        for (let i = 0; i < count; i++) elements[i] = data(base, offset + i);
      } else {
        const treeCount = data(header, "treeCount");
        const shift = data(header, "shift");
        const root = data(header, "root");
        const tail = data(data(header, "tail"), "values");
        for (let i = 0; i < treeCount; i++) {
          let node = root;
          for (let level = shift; level > 0; level -= 5) node = data(data(node, "a"), i >>> level & 31);
          elements[i] = data(data(node, "a"), i & 31);
        }
        for (let i = treeCount; i < count; i++) elements[i] = data(tail, i - treeCount);
      }
      views.set(current, elements);
      for (const element of elements) pending.push(element);
      continue;
    }
    const prototype = Object.getPrototypeOf(current);
    if (Array.isArray(current) ? prototype !== Array.prototype : prototype !== null && prototype !== Object.prototype) return { $: "Nothing", a: null };
    for (const key of Reflect.ownKeys(current)) {
      if (typeof key === "symbol") return { $: "Nothing", a: null };
      const descriptor = Object.getOwnPropertyDescriptor(current, key);
      if (!Object.hasOwn(descriptor, "value")) return { $: "Nothing", a: null };
      pending.push(descriptor.value);
    }
  }
  if (views.size === 0) return { $: "Just", a: value };
  const copies = new Map();
  const jobs = [];
  const project = (current) => {
    if (current === null || typeof current !== "object") return current;
    if (copies.has(current)) return copies.get(current);
    const source = views.get(current) || current;
    const copy = Array.isArray(source) ? [] : Object.create(Object.getPrototypeOf(source));
    copies.set(current, copy);
    jobs.push([source, copy]);
    return copy;
  };
  const result = project(value);
  while (jobs.length) {
    const job = jobs.pop();
    const source = job[0];
    const copy = job[1];
    for (const key of Reflect.ownKeys(source)) {
      const descriptor = Object.getOwnPropertyDescriptor(source, key);
      Object.defineProperty(copy, key, { ...descriptor, value: project(descriptor.value) });
    }
  }
  return { $: "Just", a: result };
};

export const run = (main) => {
  console.log(main.c);
  let calls = 0;
  const accessed = {};
  Object.defineProperty(accessed, "value", { enumerable: true, get() { calls++; return 1; } });
  const cycle = {};
  cycle.self = cycle;
  const cases = [
    ["number", 42],
    ["record", { marker: "ok", values: [1, true, null] }],
    ["array", [1, 2]],
    ["null prototype", Object.assign(Object.create(null), { value: "ok" })],
    ["cycle", cycle],
    ["callback", () => { calls++; }],
    ["nested callback", { listener: () => { calls++; } }],
    ["native bytes", new Uint8Array([1])],
    ["native date", new Date(0)],
    ["accessor", accessed],
    ["symbol", Symbol("no")],
    ["bigint", 1n],
  ];
  for (const [label, data] of cases) {
    const event = new globalThis.MessageEvent("message", { data });
    console.log(`${label}: ${main.a(event)}`);
  }
  console.log(`calls: ${calls}`);
  // Exercise the emitted native adapter in both development and release.
  let getterCalls = 0;
  const accessor = {};
  Object.defineProperty(accessor, "a", { get() { getterCalls++; return 1; }, enumerable: true });
  const recursive = { a: 1 };
  recursive.self = recursive;
  const symbol = Symbol("test");
  const hidden = {};
  Object.defineProperty(hidden, "a", { value: () => null });
  const array = [1];
  array[symbol] = 1;
  const inputs = [null, undefined, 0, NaN, Infinity, -0, "x", true, [], {}, Object.create(null),
    recursive, accessor, { a: accessor }, () => null, Symbol("s"), 1n, { x: 1n }, new Date(0),
    new Uint8Array(1), new Map(), new Set(), { [symbol]: 0 }, array, hidden, { a: [1, { b: "ok" }] }];
  for (let n = 0; n < 300; n++) inputs.push({ n, a: [n % 3, { v: "x".repeat(n % 8) }], extra: n % 13 === 0 ? () => 0 : null });
  let checks = 0;
  for (let pass = 0; pass < 2; pass++) for (const value of inputs) {
    const event = new globalThis.MessageEvent("message", { data: value });
    const expected = referenceDataOnly(event);
    const actual = main.b(event);
    const keys = Reflect.ownKeys(actual), expectedKeys = Reflect.ownKeys(expected);
    if (keys.length !== expectedKeys.length || keys.some((key, index) => key !== expectedKeys[index])) throw new Error("native data result shape mismatch");
    if (actual.$ !== expected.$ || !Object.is(actual.a, expected.a)) throw new Error("native data differential mismatch");
    if (actual.$ === "Just" && !Object.is(actual.a, event.data)) throw new Error("native data identity mismatch");
    checks++;
  }
  if (getterCalls !== 0) throw new Error("native data invoked a getter");
  console.log("differential: " + checks);
  console.log("getters: " + getterCalls);
};
