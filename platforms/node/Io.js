// The sibling JavaScript of `Io.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// Each primitive starts one host operation, resumes the waiting fiber once
// with its answer, and returns what cancels it (transparent-effects-proposal.md
// §16.5): a cancelled fiber's timer is cleared and its read aborted.

import process from "node:process";
import { Buffer } from "node:buffer";
import { readFile, readdir } from "node:fs/promises";

// How a fiber `Io.run` started ended: its program's output and exit code,
// or 130 when it was cancelled. `runtime.js` has already run the empty
// program `main` evaluated to.
export const finish = (exit) => {
  if (exit.$ === "Done") {
    const program = exit.a;
    if (program.out.length !== 0) process.stdout.write(program.out);
    process.exitCode = program.code;
  } else {
    process.exitCode = 130;
  }
  return null;
};

// `FileError`'s constructor for each failure Node documents for
// `fs.promises.readFile`, by the error's `code`. `FileError` is all
// nullary, so a constructor is its tag, and a `foreign` names the type,
// so the tag is the same string in a release build (boundary.md §4).
const fileErrors = {
  ENOENT: "NotFound",
  EACCES: "PermissionDenied",
  EPERM: "PermissionDenied",
  EISDIR: "IsADirectory",
  ENOTDIR: "NotADirectory",
  EMFILE: "TooManyOpenFiles",
  ENFILE: "TooManyOpenFiles",
  ELOOP: "SymlinkLoop",
  ENAMETOOLONG: "NameTooLong",
  // A TypeError: the path holds a NUL character.
  ERR_INVALID_ARG_VALUE: "InvalidPath",
  // A RangeError over 2 GiB, and an Error past V8's longest string.
  ERR_FS_FILE_TOO_LARGE: "TooLarge",
  ERR_STRING_TOO_LONG: "TooLarge",
};

export const startRead = (path, resume) => {
  const abort = new AbortController();
  readFile(path, { encoding: "utf8", signal: abort.signal }).then(
    (text) => resume({ $: "Ok", a: text }),
    (error) => {
      // The fiber was cancelled and its canceller aborted the read: no one
      // waits for an answer.
      if (abort.signal.aborted && error instanceof Error && error.name === "AbortError") return;
      const code = error instanceof Error ? error.code : undefined;
      if (typeof code === "string" && Object.hasOwn(fileErrors, code)) {
        resume({ $: "Err", a: fileErrors[code] });
        return;
      }
      // Anything else is a defect (CLAUDE.md rule 9): thrown again, it is
      // a rejection nothing handles, and Node reports it and exits 1
      // (transparent-effects-proposal.md §16.5, *A defect on Node*).
      throw error;
    },
  );
  return (unit) => {
    abort.abort();
    return unit;
  };
};

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
      if (cancelled) return;
      const code = error instanceof Error ? error.code : undefined;
      if (typeof code === "string" && Object.hasOwn(dirErrors, code)) {
        resume({ $: "Err", a: dirErrors[code] });
        return;
      }
      // Anything else is a defect (CLAUDE.md rule 9): see `startRead`.
      throw error;
    },
  );
  return (unit) => {
    cancelled = true;
    return unit;
  };
};
