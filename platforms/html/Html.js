// The sibling JavaScript of `Html.beni` (docs/design/boundary.md §4, §9.3):
// the payload extractors its events name with `via`, one export per
// `foreign` value. Each reads the event object a handler is handed and
// touches nothing else of the host.

export const targetValue = (event) => event.target.value;

export const targetChecked = (event) => event.target.checked;
