// The sibling JavaScript of `Tea.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name. A program constructor is
// handed the mount the `direct` lowering compiled where it is called
// (boundary.md §9.4.6, version 1.6), never the record, and makes of it the
// platform's `Program`: one mount, `{ a, n }`, which `Browser.mountAt` and
// `Browser.programs` rewrite and `Direct.run` mounts.

export const sandbox = (mount) => [{ a: mount, n: null }];

export const element = (mount) => [{ a: mount, n: null }];

export const document = (mount) => [{ a: mount, n: null }];

export const application = (mount) => [{ a: mount, n: null }];
