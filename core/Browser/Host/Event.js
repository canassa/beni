export const errorMessage = (event) => { return typeof globalThis.ErrorEvent === "function" && event instanceof globalThis.ErrorEvent ? { $: "Just", a: event.message } : { $: "Nothing", a: null }; };
export const message = (event) => { return globalThis.String(event.message); };
export const dataOnly = (event) => { const value = event.data;
  const pending = [value];
  const seen = new Set();
  while (pending.length) {
    const current = pending.pop();
    if (current === null) continue;
    const kind = typeof current;
    if (kind === "function" || kind === "symbol" || kind === "bigint") return { $: "Nothing", a: null };
    if (kind !== "object") continue;
    if (seen.has(current)) continue;
    seen.add(current);
    const prototype = Object.getPrototypeOf(current);
    if (Array.isArray(current) ? prototype !== Array.prototype : prototype !== null && prototype !== Object.prototype) return { $: "Nothing", a: null };
    for (const key of Reflect.ownKeys(current)) {
      if (typeof key === "symbol") return { $: "Nothing", a: null };
      const descriptor = Object.getOwnPropertyDescriptor(current, key);
      if (!Object.hasOwn(descriptor, "value")) return { $: "Nothing", a: null };
      pending.push(descriptor.value);
    }
  }
  return { $: "Just", a: value };
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
