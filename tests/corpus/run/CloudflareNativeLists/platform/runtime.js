export const run = async (program) => {
  console.log(program.d);
  const shapes = (values) => [
    ["array", values],
    ["trie", { length: values.length, $plain() { return values; } }],
    ["view", { b: ["inactive", ...values], o: 1, length: values.length }],
  ];
  for (const [shape, definitions] of shapes([{ name: "one" }, { name: "two" }])) {
    const worker = program.a(definitions);
    if (worker.objects.map((item) => item.name).join(",") !== "one,two") throw new Error(`${shape} definition reader changed`);
    console.log(`${shape} definitions one,two`);
  }
  const borrowed = [{ name: "one" }];
  const retained = program.a(borrowed);
  borrowed.push({ name: "later" });
  if (retained.objects.length !== 1) throw new Error("program retained a borrowed mutable List array");
  console.log("definition snapshot one");
  for (const [shape, headers] of shapes([{ a: "x-one", b: "1" }, { a: "x-two", b: "2" }])) {
    const response = program.b(headers);
    if (response.headers.get("x-one") !== "1" || response.headers.get("x-two") !== "2" || await response.text() !== "ok") throw new Error(`${shape} header reader changed`);
    console.log(`${shape} headers 1,2`);
  }
  for (const [shape, tags] of shapes(["one", "two"])) {
    let accepted, attachment;
    const socket = { serializeAttachment(value) { attachment = structuredClone(value); } };
    const state = { acceptWebSocket(given, values) { if (given !== socket) throw new Error("socket identity changed"); accepted = values.slice(); } };
    program.c(state, socket, tags);
    if (accepted.join(",") !== "one,two" || !Array.isArray(attachment.tags) || attachment.tags.join(",") !== "one,two" || attachment.id !== "id" || attachment.protocol !== "protocol" || attachment.data !== null) throw new Error(`${shape} tag reader changed`);
    console.log(`${shape} tags one,two`);
  }
  const expectedTags = Array.from({ length: 41 }, (_, i) => String(i + 1));
  let acceptedLarge, attachedLarge, protocolsLarge;
  const largeSocket = { serializeAttachment(value) { attachedLarge = structuredClone(value); } };
  const largeState = { acceptWebSocket(socket, tags) {
    if (socket !== largeSocket) throw new Error("large socket identity changed");
    acceptedLarge = tags.slice();
  } };
  const OriginalWebSocket = globalThis.WebSocket;
  let large;
  try {
    globalThis.WebSocket = class { constructor(url, protocols) { protocolsLarge = protocols.slice(); } };
    large = program.e({ name: "large" }, largeState, largeSocket);
  } finally { globalThis.WebSocket = OriginalWebSocket; }
  if (large.a.objects.length !== 41 || large.a.objects.some(item => item.name !== "large")) throw new Error("real trie definitions changed");
  const response = large.b;
  if (response.headers.get("x-repeat") !== Array(40).fill("1").join(", ") || response.headers.get("x-last") !== "41" || await response.text() !== "ok") throw new Error("real trie headers changed");
  for (const tags of [acceptedLarge, attachedLarge.tags, protocolsLarge]) {
    if (!Array.isArray(tags) || JSON.stringify(tags) !== JSON.stringify(expectedTags)) throw new Error("real trie tags/protocols changed");
  }
  if (large.c.$ !== "Just" || attachedLarge.id !== "id" || attachedLarge.protocol !== "protocol" || attachedLarge.data !== null) throw new Error("real trie attachment changed");
  console.log("real trie definitions, headers, tags, protocols 41");
};
