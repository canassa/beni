// The sibling JavaScript of `Prerender.beni` (docs/design/boundary.md §4):
// one export per `foreign` value, under the same name, and nothing else.

import process from "node:process";
import { writeFileSync } from "node:fs";

// A data program's records (docs/design/prerender.md §8.3), in one write:
// to the file its first argument names, which the build reads, or to
// standard output when it has none. A failure to write is not caught: an
// unknown failure crashes (CLAUDE.md rule 9).
export const writeRecords = (text) => {
  const file = process.argv[2];
  if (file === undefined) process.stdout.write(text);
  else writeFileSync(file, text);
  return null;
};
