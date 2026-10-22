// The sibling of `Probe.beni` (boundary.md §4, §9.3). `probe` is `pub`.
// The parameter is not called `event`. That is a global of the window, which
// the release minifier never renames.

export const probe = (e) => e.detail;
