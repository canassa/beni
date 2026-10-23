// The sibling JavaScript of `Html.beni` (docs/design/boundary.md §4, §9.3):
// the payload extractors its events name with `via`, one export per
// `foreign` value. Each reads the event object a handler is handed and
// touches nothing else of the host. The parameter is not called `event`:
// that is a global of the window, which the release minifier never renames.

export const targetValue = (e) => e.target.value;

export const targetChecked = (e) => e.target.checked;

// A pointer event and its position in the border box of the element whose
// handler runs, its `currentTarget` (a delegated walk defines it as that
// element): read now, while the event is dispatched, since `currentTarget`
// is null after it (boundary.md §9.8.20). The key is `ev`,
// not `e`: the release minifier keeps the spelling of a name that is ever a
// key in this file, so a key `e` would keep every parameter `e` long.
export const pointer = (v) => {
  const r = v.currentTarget.getBoundingClientRect();
  return { ev: v, x: v.clientX - r.left, y: v.clientY - r.top };
};
