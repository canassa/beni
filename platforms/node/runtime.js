// The Node platform's output shape (docs/design/boundary.md §5.2): what the
// emitted entry file hands `main` to.
//
// A platform declares how its artifact is shaped and how `main` is invoked,
// and the emitter is parameterised by it rather than hardcoding one. For
// Node that is an entry module that imports `main`, writes what it says to
// standard output and leaves the exit code behind.
//
// `process` is imported rather than taken from the global scope, because
// boundary.md §4's third check reads this file's own imports to decide what
// its references are covered by — the mechanism that keeps dead-code
// elimination declaration-granular (§7.1).

import process from "node:process";

export const run = (program) => {
  if (program.out.length !== 0) process.stdout.write(program.out);
  process.exitCode = program.code;
};
