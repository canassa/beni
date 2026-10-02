// The sibling of `Wrap.beni`: it reads and builds a `Meters` by the tag
// and field its annotation gives it (boundary.md §4).

export const double = (m) => (m.$ === "Meters" ? { $: "Meters", a: m.a * 2 } : null);

export const keep = (v) => v;
