export const run = (main) => {
  console.log(main.b);
  let calls = 0;
  const accessed = {};
  Object.defineProperty(accessed, "value", { enumerable: true, get() { calls++; return 1; } });
  const cycle = {};
  cycle.self = cycle;
  const cases = [
    ["number", 42],
    ["record", { marker: "ok", values: [1, true, null] }],
    ["array", [1, 2]],
    ["null prototype", Object.assign(Object.create(null), { value: "ok" })],
    ["cycle", cycle],
    ["callback", () => { calls++; }],
    ["nested callback", { listener: () => { calls++; } }],
    ["native bytes", new Uint8Array([1])],
    ["native date", new Date(0)],
    ["accessor", accessed],
    ["symbol", Symbol("no")],
    ["bigint", 1n],
  ];
  for (const [label, data] of cases) {
    const event = new globalThis.MessageEvent("message", { data });
    console.log(`${label}: ${main.a(event)}`);
  }
  console.log(`calls: ${calls}`);
};
