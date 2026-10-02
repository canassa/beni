// The sibling JavaScript of `Browser/Events.beni` (docs/design/boundary.md
// §4): one export per `foreign` value, under the same name.

export const size = (unit) => ({ height: globalThis.innerHeight, width: globalThis.innerWidth });

export const hidden = (unit) => globalThis.document.visibilityState === "hidden";
