// The browser platform's runtime file (docs/design/backend.md §15.3–§15.5,
// §15.11; boundary.md §9.2): the program runtime and the `dom` lowering's
// markup runtime at once. **All of it is written in beni**, in `Rt.beni`,
// this platform's runtime module (boundary.md §9.2, *A runtime module*;
// `plans/runtime-in-beni.md`), whose `pub` values stand in for this file's
// exports of their names; the file stays because a manifest names one.
