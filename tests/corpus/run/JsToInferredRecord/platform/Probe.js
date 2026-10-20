// The sibling builds a host object and reads one field by its source name
// (boundary.md §4). The names are not pinned by any annotation in this
// program, so a release build keeps them only when the inferred cast does.

export const made = () => ({ missed: "missed", hole: { buried: "buried" } });

export const take = (v) => v.sent;
