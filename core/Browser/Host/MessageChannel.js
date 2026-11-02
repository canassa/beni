export const create = (_) => { return new globalThis.MessageChannel(); };
export const port1 = (channel) => { return channel.port1; };
export const port2 = (channel) => { return channel.port2; };
