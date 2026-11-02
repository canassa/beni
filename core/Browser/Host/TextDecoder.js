export const create = (_) => { return new globalThis.TextDecoder(); };
export const decodeMore = (decoder, bytes) => { return decoder.decode(bytes, { stream: true }); };
export const finish = (decoder) => { return decoder.decode(); };
