// The sibling JavaScript of `Tea.beni` (docs/design/boundary.md §4): one
// export per `foreign` value. A program constructor is handed the mount the
// `inline` lowering compiled where it is called, a function of the id of the
// element it mounts at, and that mount is the platform's `Program`, which
// `Browser.mountAt` places and `Inline.run` mounts.

export const sandbox = (mount) => mount;

export const element = (mount) => mount;
