// The sibling JavaScript of `Html.beni` (docs/design/boundary.md §4, §9.3):
// the payload extractors its events name with `via`, one export per
// `foreign` value. Each reads the event object a handler is handed and
// touches nothing else of the host. The parameter is not called `event`:
// that is a global of the window, which the release minifier never renames.

export const targetValue = (e) => e.target.value;

export const targetChecked = (e) => e.target.checked;
