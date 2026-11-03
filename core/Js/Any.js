// Typed core protocol primitives; identities are supplied by the compiler.
const Box = function (type, value) { this.type = type; this.value = value; };
export const pack = (type, value) => new Box(type, value);
export const unpack = (type, box) => box.type === type ? { $: "Just", a: box.value } : { $: "Nothing", a: null };
export const fingerprint = (box) => box.type;
