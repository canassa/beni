// The sibling JavaScript of `Tea.beni` (docs/design/boundary.md §4): one
// export per `foreign` value. A program is the mount the `inline` lowering
// compiled where the constructor is called, a function of the id of the
// element it mounts at, and the lowering compiles the call as that mount
// alone (`Lowering.constructs`, version 1.14), so these are never called.

export const sandbox = (mount) => mount;

export const element = (mount) => mount;
