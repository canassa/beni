// Isolated prototype JSON boundary. The depth and node budgets apply in both
// directions, before recursive work can exhaust the JavaScript stack.

const MAX_DEPTH = 128;
const MAX_NODES = 100000;
const nil = { $: 0, a: null, b: null };

const ok = (value) => ({ $: "Ok", a: value });
const err = (message) => ({ $: "Err", a: message });

const listFromArray = (items) => {
  let out = nil;
  for (let i = items.length - 1; i >= 0; i--) {
    out = { $: 1, a: items[i], b: out };
  }
  return out;
};

const tuple2 = (a, b) => ({ a, b });

const spend = (budget, depth) => {
  if (depth > MAX_DEPTH) throw new Error(`JSON nesting exceeds ${MAX_DEPTH}`);
  budget.nodes += 1;
  if (budget.nodes > MAX_NODES) throw new Error(`JSON value exceeds ${MAX_NODES} nodes`);
};

const fromHost = (value, budget, depth) => {
  spend(budget, depth);
  if (value === null) return { $: "Null", a: null };
  if (typeof value === "boolean") return { $: "Flag", a: value };
  if (typeof value === "number") return { $: "Number", a: value };
  if (typeof value === "string") return { $: "Text", a: value };
  if (Array.isArray(value)) {
    return {
      $: "Array",
      a: listFromArray(value.map((item) => fromHost(item, budget, depth + 1))),
    };
  }
  if (typeof value === "object") {
    const fields = Object.entries(value).map(([key, item]) =>
      tuple2(key, fromHost(item, budget, depth + 1)),
    );
    return { $: "Object", a: listFromArray(fields) };
  }
  throw new Error(`JSON.parse produced unsupported ${typeof value}`);
};

const listToArray = (list, name) => {
  const items = [];
  let at = list;
  while (at !== null && typeof at === "object" && at.$ === 1) {
    items.push(at.a);
    at = at.b;
    if (items.length > MAX_NODES) throw new Error(`${name} exceeds ${MAX_NODES} entries`);
  }
  if (at === null || typeof at !== "object" || at.$ !== 0) {
    throw new Error(`${name} is not a well-formed List`);
  }
  return items;
};

const onePayload = (value, tag) => {
  if (value === null || typeof value !== "object" || value.$ !== tag || !("a" in value)) {
    throw new Error(`Wire.Value ${tag} has an invalid representation`);
  }
  return value.a;
};

const toHost = (value, budget, depth) => {
  spend(budget, depth);
  if (value === null || typeof value !== "object" || typeof value.$ !== "string") {
    throw new Error("Wire.Value has an invalid representation");
  }
  switch (value.$) {
    case "Null":
      onePayload(value, "Null");
      return null;
    case "Flag": {
      const flag = onePayload(value, "Flag");
      if (typeof flag !== "boolean") throw new Error("Wire.Flag payload is not Bool");
      return flag;
    }
    case "Number": {
      const number = onePayload(value, "Number");
      if (typeof number !== "number" || !Number.isFinite(number)) {
        throw new Error("JSON cannot print a non-finite number");
      }
      return number;
    }
    case "Text": {
      const text = onePayload(value, "Text");
      if (typeof text !== "string") throw new Error("Wire.Text payload is not String");
      return text;
    }
    case "Array":
      return listToArray(onePayload(value, "Array"), "Wire.Array").map((item) =>
        toHost(item, budget, depth + 1),
      );
    case "Object": {
      const object = Object.create(null);
      for (const pair of listToArray(onePayload(value, "Object"), "Wire.Object")) {
        if (pair === null || typeof pair !== "object" || typeof pair.a !== "string" || !("b" in pair)) {
          throw new Error("Wire.Object entry is not a ( String, Value ) tuple");
        }
        if (Object.hasOwn(object, pair.a)) {
          throw new Error(`Wire.Object contains duplicate key ${JSON.stringify(pair.a)}`);
        }
        object[pair.a] = toHost(pair.b, budget, depth + 1);
      }
      return object;
    }
    default:
      throw new Error(`unknown Wire.Value tag ${value.$}`);
  }
};

const message = (failure) =>
  failure instanceof Error ? failure.message : `foreign JSON failure: ${String(failure)}`;

export const parse = (source) => {
  try {
    if (typeof source !== "string") return err("JSON input is not a String");
    return ok(fromHost(JSON.parse(source), { nodes: 0 }, 0));
  } catch (failure) {
    // Host syntax diagnostics vary by engine/version; this boundary owns its text.
    if (failure instanceof SyntaxError) return err("invalid JSON");
    return err(message(failure));
  }
};

export const print = (value) => {
  try {
    const text = JSON.stringify(toHost(value, { nodes: 0 }, 0));
    if (typeof text !== "string") return err("JSON printer did not produce a String");
    return ok(text);
  } catch (failure) {
    return err(message(failure));
  }
};
