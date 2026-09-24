// The sibling JavaScript of `Debug.beni` (docs/design/boundary.md §4).
//
// `log` is the one deliberate violation of §4's two-shape rule, exactly as
// it is in Elm: its type is `a, String -> a`, a pure function, and it
// writes to the console. That is stated in boundary.md §4 rather than
// discovered here, and it is why `Debug` is not for shipping code.

const showList = (list, seen) => {
  const parts = [];
  for (let at = list; at.$ === 1; at = at.b) parts.push(show(at.a, seen));
  return `[${parts.join(",")}]`;
};

const show = (value, seen) => {
  if (typeof value === "string") return JSON.stringify(value);
  if (typeof value === "number" || typeof value === "boolean") return String(value);
  if (value === null) return "()";
  if (typeof value !== "object") return String(value);
  if (seen.has(value)) return "<cycle>";
  seen.add(value);
  try {
    if (value.$ === 0 || value.$ === 1) return showList(value, seen);
    const keys = Object.keys(value);
    if (typeof value.$ === "string") {
      const args = keys.filter((k) => k !== "$" && value[k] !== null).map((k) => show(value[k], seen));
      return args.length === 0 ? value.$ : `${value.$} ${args.join(" ")}`;
    }
    // Elm prints the empty record as `{}`, not `{  }`.
    if (keys.length === 0) return "{}";
    return `{ ${keys.map((k) => `${k} = ${show(value[k], seen)}`).join(", ")} }`;
  } finally {
    seen.delete(value);
  }
};

export const log = (value, tag) => {
  console.log(`${tag}: ${show(value, new Set())}`);
  return value;
};

// The one function in core that is allowed to stop the program, because
// saying "this is not written yet" is the whole of what it means.
export const todo = (message) => {
  throw new Error(`TODO: ${message}`);
};

export const toString = (value) => show(value, new Set());
