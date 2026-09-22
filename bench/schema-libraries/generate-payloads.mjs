// Deterministic, one-time dataset generator. Stdout is JSON; does not edit files.
// Capture each key's value under payloads/<key>.json. Runners only READ captures.
const clone = (value) => JSON.parse(JSON.stringify(value));
function flat(i) {
  const value = { "user-id": i + 1, "display-name": `Person ${i} — \"quoted\"`,
    email: `person${i}@example.test`, age: 18 + i % 70, active: i % 2 === 0,
    score: (i % 1000) / 8, role: ["reader", "editor", "owner"][i % 3] };
  if (i % 3 !== 0) value.nickname = `nick\\${i}`;
  return value;
}
let nextId = 1;
function tree(depth) {
  return { id: nextId++, label: `node\n${depth}`, children: depth < 8 ? [tree(depth + 1), tree(depth + 1)] : [] };
}
const valid = {
  flat: flat(1),
  list: Array.from({ length: 1000 }, (_, i) => flat(i)),
  union: Array.from({ length: 1000 }, (_, i) => [
    () => ({ kind: "user", user: flat(i) }),
    () => ({ kind: "count", count: i }),
    () => ({ kind: "text", text: `event ${i}\nline` }),
    () => ({ kind: "point", x: i / 8, y: -i / 4 }),
  ][i % 4]()),
  tree: tree(0),
  typeahead: { hits: Array.from({ length: 20 }, (_, i) => ({ hit_id: `hit-${i}`, title: `Search \"${i}\" — result` })), total: 234 },
};
const chain = (n) => Array.from({ length: n }, () => ["children", 0]).flat();
const paths = {
  flat: { wrong_type: ["age"], missing_key: ["email"], unknown_key: ["unexpected"] },
  list: { wrong_type: [777, "age"], missing_key: [333, "email"], unknown_key: [999, "unexpected"] },
  union: { wrong_type: [776, "user", "age"], missing_key: [501, "count"], unknown_key: [999, "unexpected"] },
  tree: { wrong_type: [...chain(8), "label"], missing_key: [...chain(4), "id"], unknown_key: ["unexpected"] },
  typeahead: { wrong_type: ["hits", 17, "title"], missing_key: ["total"], unknown_key: ["hits", 0, "unexpected"] },
};
// Fixture conversion preserves missing and unknown properties, unlike the
// successful-value fast mapping used during measurements.
function program(value) {
  if (Array.isArray(value)) return value.map(program);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).map(([key, item]) =>
    [{ "user-id": "userId", "display-name": "displayName", hit_id: "id" }[key] ?? key, program(item)]));
  return value;
}
const payloads = {};
for (const [workload, original] of Object.entries(valid)) {
  payloads[workload] = ["valid", "wrong_type", "missing_key", "unknown_key"].map((path) => {
    const wire = clone(original);
    const fault = paths[workload][path] ?? [];
    if (path !== "valid") {
      const parent = fault.slice(0, -1).reduce((at, key) => at[key], wire);
      const key = fault.at(-1);
      if (path === "missing_key") delete parent[key];
      else if (path === "unknown_key") parent[key] = true;
      else parent[key] = typeof parent[key] === "string" ? 99 : "not-a-number";
    }
    return { path, wire, program: program(wire), wireFaultPath: fault,
      programFaultPath: fault.map((key) => ({ "user-id": "userId", "display-name": "displayName", hit_id: "id" }[key] ?? key)) };
  });
}
const [workload, caseName] = process.argv.slice(2);
const output = workload ? (caseName ? payloads[workload].find((entry) => entry.path === caseName) : payloads[workload]) : payloads;
process.stdout.write(JSON.stringify(output));
