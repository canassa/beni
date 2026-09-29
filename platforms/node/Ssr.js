// The sibling JavaScript of `Ssr.beni` (docs/design/boundary.md §4). Markup
// under the `ssr` lowering is `{ t: string }`, its HTML already escaped
// (docs/design/backend.md §15.6), which is legal to read here because this
// platform names that lowering (boundary.md §9.3).

export const render = (html) => html.t;
