// Typed core protocol primitives; identities are supplied by the compiler.
export const pack = (type, value) => Object.create({ type, value });
export const unpack = (type, box) => box.type === type ? { $: "Just", a: box.value } : { $: "Nothing", a: null };
export const fingerprint = (box) => box.type;
