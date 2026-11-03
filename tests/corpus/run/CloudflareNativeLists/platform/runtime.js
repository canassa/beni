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
};
