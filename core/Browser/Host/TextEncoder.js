export const create = (_) => { return new globalThis.TextEncoder(); };
export const encode = (encoder, text) => { return encoder.encode(text); };
