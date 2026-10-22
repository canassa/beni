// The sibling JavaScript of `Worker/Object.beni` (docs/design/boundary.md
// §4): one export per `foreign` value, under the same name, and nothing
// else.

// The ids of the `Reply` handles a value holds, by a walk of its arrays and
// plain objects: a handle is `{ id, instance, schema }` whose `instance`
// is an object record. The walk stops at host objects, which a beni value
// never holds.
export const repliesIn = (value) => {
  const ids = [];
  const seen = new Set();
  const walk = (v) => {
    if (v === null || typeof v !== "object" || seen.has(v)) return;
    seen.add(v);
    if (typeof v.id === "string" && v.instance !== undefined && v.schema !== undefined && v.instance !== null && typeof v.instance === "object" && Array.isArray(v.instance.mailbox)) {
      ids.push(v.id);
      return;
    }
    if (Array.isArray(v)) {
      for (const x of v) walk(x);
      return;
    }
    const proto = Object.getPrototypeOf(v);
    if (proto !== Object.prototype && proto !== null) return;
    for (const k of Object.keys(v)) walk(v[k]);
  };
  walk(value);
  return ids;
};
