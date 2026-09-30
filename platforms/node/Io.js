// The sibling JavaScript of `Io.beni` (docs/design/boundary.md §4): one
// export per `foreign` value, under the same name, and nothing else.
//
// Each primitive starts one host operation, resumes the waiting fiber once
// with its answer, and returns what cancels it (transparent-effects-proposal.md
// §16.5): a cancelled fiber's timer is cleared and its read aborted.

import process from "node:process";
import { readFile } from "node:fs/promises";

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

export const startTimer = (ms, resume) => {
  const timer = setTimeout(() => resume(null), ms);
  return (unit) => {
    clearTimeout(timer);
    return unit;
  };
};

export const startRead = (path, resume) => {
  const abort = new AbortController();
  readFile(path, { encoding: "utf8", signal: abort.signal }).then(
    (text) => resume({ $: "Ok", a: text }),
    (error) => resume({ $: "Err", a: String(error && error.code ? error.code : error) }),
  );
  return (unit) => {
    abort.abort();
    return unit;
  };
};
