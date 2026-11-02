// Generated checked graph conversion; native/CheckedData.zig owns the check.
export const checked = (value) => {
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
