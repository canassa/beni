// The sibling of `Probe.beni`: it reads and builds beni values by the
// names their annotations give them (boundary.md §4).

export const describe = (p) => `${p.label}@${p.x}`;

export const origin = () => ({ label: "origin", x: 0 });

export const area = (s) => (s.$ === "Circle" ? 3 * s.a * s.a : s.$ === "Square" ? s.a * s.a : -1);

export const keep = (v) => v;

export const made = () => ({ count: 2, kind: "made" });
