export const dataOnly = (event) => { const value = event.data; const listToken = undefined;
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
export const error = (event) => { const error = event.error; return error == null ? { $: "Nothing", a: null } : { $: "Just", a: error }; };
export const defaultPrevented = (event) => { return event.defaultPrevented; };
export const button = (event) => { return event.button; };
export const composedPath = (event) => { return event.composedPath(); };
export const currentBox = (event) => { return event.currentTarget.getBoundingClientRect(); };
export const targetValue = (event) => { return event.target.value; };
export const targetChecked = (event) => { return event.target.checked; };
export const preventDefault = (event) => { event.preventDefault(); return null; };
export const key = (event) => { return event.key ?? ""; };
export const code = (event) => { return event.code ?? ""; };
export const ctrlKey = (event) => { return event.ctrlKey === true; };
export const shiftKey = (event) => { return event.shiftKey === true; };
export const altKey = (event) => { return event.altKey === true; };
export const metaKey = (event) => { return event.metaKey === true; };
export const pointerId = (event) => { return event.pointerId; };
export const pointerType = (event) => { return event.pointerType ?? ""; };
export const isPrimary = (event) => { return event.isPrimary === true; };
export const clientX = (event) => { return event.clientX; };
export const clientY = (event) => { return event.clientY; };
