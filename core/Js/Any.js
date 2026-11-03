// Typed core protocol primitives; identities are supplied by the compiler.
const Box = function (type, value) { this.type = type; this.value = value; };
export const pack = (type, value) => new Box(type, value);
const packetKey = Symbol();
const packetDescriptor = { value: undefined };
const packet = pack.$packet = Object.assign((type, value) => {
  packetDescriptor.value = type;
  Object.defineProperty(value, packetKey, packetDescriptor);
  return value;
}, { key: packetKey });
export const unpack = (type, box) => {
  const packetType = box[packetKey];
  if (packetType !== undefined) return packetType === type ? { $: "Just", a: box } : { $: "Nothing", a: null };
  return box.type === type ? { $: "Just", a: box.value } : { $: "Nothing", a: null };
};
export const fingerprint = (box) => box.type;
