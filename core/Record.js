// The sibling JavaScript of `Record.beni` (docs/design/boundary.md §4). A
// spread copies the keys in their order into an object of the record's own
// hidden class, which `Object.assign({}, r)` does not (V8 builds the second
// from the empty object's map), and under `--release` the keys are already
// the short names (docs/design/ownership-checker.md §31.15).
export const copy = (r) => ({ ...r });
