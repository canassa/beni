// The sibling JavaScript of `Io.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// The directory listing starts one host operation, resumes the waiting fiber
// once with its answer, and returns what cancels the wait
// (transparent-effects-proposal.md §16.5).

import { Buffer } from "node:buffer";
import { readdir } from "node:fs/promises";

// `FileError`'s constructor for each failure Node documents for
// `fs.promises.readdir`, by the error's `code`.
const dirErrors = {
  ENOENT: "NotFound",
  EACCES: "PermissionDenied",
  EPERM: "PermissionDenied",
  ENOTDIR: "NotADirectory",
  EMFILE: "TooManyOpenFiles",
  ENFILE: "TooManyOpenFiles",
  ELOOP: "SymlinkLoop",
  ENAMETOOLONG: "NameTooLong",
  // A TypeError: the path holds a NUL character.
  ERR_INVALID_ARG_VALUE: "InvalidPath",
};

// `EntryKind` is all nullary, so a constructor is its tag.
const kindOf = (entry) =>
  entry.isFile()
    ? "File"
    : entry.isDirectory()
      ? "Directory"
      : entry.isSymbolicLink()
        ? "Symlink"
        : "Other";

// Code point order, which is the order of the UTF-8 bytes. `<` on strings
// is UTF-16 code unit order, which differs above U+FFFF.
const byName = (a, b) => Buffer.compare(Buffer.from(a.name), Buffer.from(b.name));

export const startReadDir = (path, resume) => {
  let cancelled = false;
  readdir(path, { withFileTypes: true }).then(
    (entries) => {
      // `fs.promises.readdir` takes no signal: a cancelled fiber's listing
      // finishes and no one waits for it.
      if (cancelled) return;
      const list = entries.map((entry) => ({ name: entry.name, kind: kindOf(entry) }));
      list.sort(byName);
      resume({ $: "Ok", a: list });
    },
    (error) => {
      const code = error instanceof Error ? error.code : undefined;
      if (typeof code === "string" && Object.hasOwn(dirErrors, code)) {
        // A cancelled fiber waits for no answer; an unknown error below is
        // a defect even so.
        if (!cancelled) resume({ $: "Err", a: dirErrors[code] });
        return;
      }
      // Anything else is a defect (CLAUDE.md rule 9).
      throw error;
    },
  );
  return (unit) => {
    cancelled = true;
    return unit;
  };
};
