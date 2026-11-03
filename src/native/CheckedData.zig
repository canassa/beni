//! One runtime graph check, shared by the core conversion and native data projections.
//! Native message data has no beni type witness or compiler packet metadata.
pub const body = bodyFor(false);
pub const sibling = "// Generated checked graph conversion; native/CheckedData.zig owns the check.\nexport const checkedGraph = (typeWitness, listToken, value) => {\n" ++ bodyFor(true) ++ "};\n";

fn bodyFor(comptime typed: bool) []const u8 {
    return (if (typed) "  if (typeof typeWitness === \"function\") return typeWitness(value);\n" else "") ++ prefix ++ (if (typed) packet_key else "") ++ graph_begin ++
        (if (typed) graph_packet else "") ++ graph_end ++
        (if (typed) witness_check else "") ++ project_begin ++
        (if (typed) project_packet else "") ++ project_end;
}

const prefix =
    \\  const data = (object, key) => {
    \\    if (object === null || typeof object !== "object") return undefined;
    \\    const descriptor = Object.getOwnPropertyDescriptor(object, key);
    \\    return descriptor && Object.hasOwn(descriptor, "value") ? descriptor.value : undefined;
    \\  };
    \\
;

const packet_key =
    \\  const packetKey = typeof typeWitness === "string" ? undefined : typeWitness[2].$packet?.key;
    \\
;

const graph_begin =
    \\  const pending = [value];
    \\  const seen = new Set();
    \\  const views = new Map();
    \\  while (pending.length) {
    \\    const current = pending.pop();
    \\    if (current === null) continue;
    \\    const kind = typeof current;
    \\    if (kind === "function" || kind === "symbol" || kind === "bigint") return { $: "Nothing", a: null };
    \\    if (kind !== "object") continue;
    \\    if (seen.has(current)) continue;
    \\    seen.add(current);
    \\    if (listToken !== undefined && data(current, "$t") === listToken) {
    \\      const count = data(current, "length");
    \\      const elements = new Array(count);
    \\      const header = data(current, "$h");
    \\      if (header === undefined) {
    \\        const base = data(current, "b");
    \\        const offset = data(current, "o");
    \\        for (let i = 0; i < count; i++) elements[i] = data(base, offset + i);
    \\      } else {
    \\        const treeCount = data(header, "treeCount");
    \\        const shift = data(header, "shift");
    \\        const root = data(header, "root");
    \\        const tail = data(data(header, "tail"), "values");
    \\        for (let i = 0; i < treeCount; i++) {
    \\          let node = root;
    \\          for (let level = shift; level > 0; level -= 5) node = data(data(node, "a"), i >>> level & 31);
    \\          elements[i] = data(data(node, "a"), i & 31);
    \\        }
    \\        for (let i = treeCount; i < count; i++) elements[i] = data(tail, i - treeCount);
    \\      }
    \\      views.set(current, elements);
    \\      for (const element of elements) pending.push(element);
    \\      continue;
    \\    }
    \\    const prototype = Object.getPrototypeOf(current);
    \\    if (Array.isArray(current) ? prototype !== Array.prototype : prototype !== null && prototype !== Object.prototype) return { $: "Nothing", a: null };
    \\    for (const key of Reflect.ownKeys(current)) {
    \\
;

const graph_packet =
    \\      if (packetKey !== undefined && key === packetKey) { views.set(current, current); continue; }
    \\
;

const graph_end =
    \\      if (typeof key === "symbol") return { $: "Nothing", a: null };
    \\      const descriptor = Object.getOwnPropertyDescriptor(current, key);
    \\      if (!Object.hasOwn(descriptor, "value")) return { $: "Nothing", a: null };
    \\      pending.push(descriptor.value);
    \\    }
    \\  }
    \\
;

const witness_check =
    \\  // Static witnesses distinguish native scalars and checked existentials from
    \\  // plain values with the same representation. Expand only active ADT branches.
    \\  if (typeof typeWitness !== "undefined") {
    \\    const parsed = new Map();
    \\    const definitions = new Map();
    \\    const types = new Map();
    \\    let nextType = 0;
    \\    const readWitness = (witness) => {
    \\      const text = typeof witness === "string" ? witness : witness[0];
    \\      if (!parsed.has(text)) parsed.set(text, JSON.parse(text));
    \\      return parsed.get(text);
    \\    };
    \\    const intern = (key, type) => {
    \\      if (!types.has(key)) types.set(key, { ...type, id: nextType++ });
    \\      return types.get(key);
    \\    };
    \\    // Explicit stacks keep deeply nested types and recursive values off the
    \\    // JavaScript call stack. Interned applications make recursive visits finite.
    \\    const makeType = (shape, defs, environment, parameters) => {
    \\      const work = [{ shape, defs, environment, parameters }];
    \\      const result = [];
    \\      while (work.length) {
    \\        const job = work.pop();
    \\        if (job.finish) {
    \\          const children = result.splice(result.length - job.count, job.count);
    \\          const key = JSON.stringify([job.tag, job.label, children.map((child) => child.id)]);
    \\          result.push(intern(key, { tag: job.tag, children, keys: job.keys, definition: job.definition, defs: job.defs }));
    \\          continue;
    \\        }
    \\        const node = job.shape;
    \\        if (typeof node === "number") {
    \\          result.push(job.environment[node] || intern("?", { tag: "?" }));
    \\          continue;
    \\        }
    \\        if (typeof node === "string") {
    \\          result.push(intern(node, { tag: node }));
    \\          continue;
    \\        }
    \\        if (Array.isArray(node) && node[0] === "p") {
    \\          const witness = job.parameters[node[1]];
    \\          if (typeof witness === "function") {
    \\            result.push(intern(witness, { tag: "p", checker: witness }));
    \\            continue;
    \\          }
    \\          const pair = readWitness(witness);
    \\          work.push({ shape: pair[0], defs: pair[1], environment: [], parameters: typeof witness === "string" ? [] : witness[1] });
    \\          continue;
    \\        }
    \\        const tag = Array.isArray(node) ? node[0] : "r";
    \\        const keys = tag === "r" ? Object.keys(node) : undefined;
    \\        const childShapes = tag === "r" ? keys.map((key) => node[key]) : node.slice(tag === "n" ? 2 : 1);
    \\        const definition = tag === "n" ? job.defs[node[1]] : undefined;
    \\        if (tag === "n" && !definitions.has(definition)) definitions.set(definition, definitions.size);
    \\        work.push({ finish: true, tag, label: tag === "r" ? keys : tag === "n" ? definitions.get(definition) : null, count: childShapes.length, keys, definition, defs: job.defs });
    \\        for (let i = childShapes.length - 1; i >= 0; i--)
    \\          work.push({ shape: childShapes[i], defs: job.defs, environment: job.environment, parameters: job.parameters });
    \\      }
    \\      return result[0];
    \\    };
    \\    const pair = readWitness(typeWitness);
    \\    const jobs = [[value, makeType(pair[0], pair[1], [], typeof typeWitness === "string" ? [] : typeWitness[1])]];
    \\    const visited = new Map();
    \\    while (jobs.length) {
    \\      const [current, type] = jobs.pop();
    \\      if (type.tag === "x" || type.tag === "F" || type.tag === "?") return { $: "Nothing", a: null };
    \\      if (type.tag === "p") {
    \\        if (type.checker(current).$ !== "Just") return { $: "Nothing", a: null };
    \\        continue;
    \\      }
    \\      let done = visited.get(current);
    \\      if (done && done.has(type.id)) continue;
    \\      if (!done) visited.set(current, done = new Set());
    \\      done.add(type.id);
    \\      const source = views.get(current) || current;
    \\      if (type.tag === "l") {
    \\        for (let i = 0; i < data(source, "length"); i++) jobs.push([data(source, i), type.children[0]]);
    \\      } else if (type.tag === "r") {
    \\        for (let i = 0; i < type.children.length; i++) jobs.push([type.keys[i] === "$row" ? current : data(current, type.keys[i]), type.children[i]]);
    \\      } else if (type.tag === "e") {
    \\        for (const child of type.children) jobs.push([current, child]);
    \\      } else if (type.tag === "t") {
    \\        for (let i = 0; i < type.children.length; i++) jobs.push([data(current, String.fromCharCode(97 + i)), type.children[i]]);
    \\      } else if (type.tag === "R") {
    \\        jobs.push([data(current, "v"), type.children[0]]);
    \\      } else if (type.tag === "C") {
    \\        jobs.push([current, type.children[0]]);
    \\      } else if (type.tag === "O") {
    \\        if (current !== typeWitness[3]) jobs.push([current, type.children[0]]);
    \\      } else if (type.tag === "n") {
    \\        const tag = typeof current === "string" ? current : data(current, "$");
    \\        const fields = type.definition[tag];
    \\        if (!fields) return { $: "Nothing", a: null };
    \\        for (let i = 0; i < fields.length; i++) {
    \\          const child = makeType(fields[i], type.defs, type.children, []);
    \\          jobs.push([data(current, String.fromCharCode(97 + i)), child]);
    \\        }
    \\      }
    \\    }
    \\  }
    \\
;

const project_begin =
    \\  if (views.size === 0) return { $: "Just", a: value };
    \\  const copies = new Map();
    \\  const jobs = [];
    \\  const project = (current) => {
    \\    if (current === null || typeof current !== "object") return current;
    \\    if (copies.has(current)) return copies.get(current);
    \\    const source = views.get(current) || current;
    \\    const copy = Array.isArray(source) ? [] : Object.create(Object.getPrototypeOf(source));
    \\    copies.set(current, copy);
    \\    jobs.push([source, copy]);
    \\    return copy;
    \\  };
    \\  const result = project(value);
    \\  while (jobs.length) {
    \\    const job = jobs.pop();
    \\    const source = job[0];
    \\    const copy = job[1];
    \\    for (const key of Reflect.ownKeys(source)) {
    \\
;

const project_packet =
    \\      if (packetKey !== undefined && key === packetKey) continue;
    \\
;

const project_end =
    \\      const descriptor = Object.getOwnPropertyDescriptor(source, key);
    \\      Object.defineProperty(copy, key, { ...descriptor, value: project(descriptor.value) });
    \\    }
    \\  }
    \\  return { $: "Just", a: result };
    \\
;
