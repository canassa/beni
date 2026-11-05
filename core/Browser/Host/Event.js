export const kind = (event) => { return event.type; };
export const isTrusted = (event) => { return event.isTrusted; };
export const bubbles = (event) => { return event.bubbles; };
export const cancelBubble = (event) => { return event.cancelBubble; };
export const stopPropagation = (event) => { event.stopPropagation(); return null; };
export const host_target = (event) => { return event.target; };
export const host_errorMessage = (event) => { return typeof globalThis.ErrorEvent === "function" && event instanceof globalThis.ErrorEvent ? event.message : undefined; };
export const message = (event) => { return globalThis.String(event.message); };
export const host_dataOnly = (event) => { const value = event.data;
  const pending = [value];
  const seen = new Set();
  while (pending.length) {
    const current = pending.pop();
    if (current === null) continue;
    const kind = typeof current;
    if (kind === "function" || kind === "symbol" || kind === "bigint") return globalThis.Symbol;
    if (kind !== "object") continue;
    if (seen.has(current)) continue;
    seen.add(current);
    const prototype = Object.getPrototypeOf(current);
    if (Array.isArray(current) ? prototype !== Array.prototype : prototype !== null && prototype !== Object.prototype) return globalThis.Symbol;
    for (const key of Reflect.ownKeys(current)) {
      if (typeof key === "symbol") return globalThis.Symbol;
      const descriptor = Object.getOwnPropertyDescriptor(current, key);
      if (!Object.hasOwn(descriptor, "value")) return globalThis.Symbol;
      pending.push(descriptor.value);
    }
  }
  return value;
};
export const host_error = (event) => { return event.error; };
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
