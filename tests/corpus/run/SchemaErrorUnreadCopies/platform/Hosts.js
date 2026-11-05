// Preserve descriptor flags, getter invocation order and one-read instrumentation.
export const defineGetter = (out, key, get) => Object.defineProperty(out, key, { get, enumerable: true });
