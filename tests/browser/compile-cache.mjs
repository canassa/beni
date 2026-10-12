// Pruning of the driver's V8 compile cache (`driver.mjs`, *happy-dom is one
// 890 kB file*). Its own file so a test can run it on a cache of its own.
//
// Every page program is compiled from a directory no later run repeats, so
// its cache entry is never read again, and a sweep of the page fuzzer leaves
// a hundred thousand of them. Reading and statting a directory that size
// cost each page 85 million instructions, and the gates count a page's.
// What a run does here therefore never depends on how many entries there
// are: it reads at most `entries + 1` names of a version's directory, and
// looks at no more than `examine` of them. A cache of `entries` or fewer
// is left alone; a larger one loses the old entries among the names looked
// at, so a cache far over the cap shrinks by `examine` a run — gradually,
// over the many runs of the gates, rather than all at once in one page's.
import { opendirSync, readdirSync, statSync, unlinkSync } from "node:fs";
import { join } from "node:path";

export const defaults = { entries: 1024, age: 60 * 60 * 1000, examine: 128 };

// One directory per Node version holds the entries. Another driver may be
// pruning the same files: one already gone is what was wanted.
export function pruneCompileCache(dir, options = {}) {
  const { entries, age, examine } = { ...defaults, ...options };
  let versions;
  try {
    versions = readdirSync(dir);
  } catch (error) {
    if (error.code === "ENOENT") return;
    throw error;
  }
  const now = Date.now();
  for (const version of versions) {
    const names = firstNames(join(dir, version), entries + 1);
    if (names.length <= entries) continue;
    for (const name of names.slice(0, examine)) {
      const path = join(dir, version, name);
      try {
        if (now - statSync(path).mtimeMs > age) unlinkSync(path);
      } catch (error) {
        if (error.code !== "ENOENT") throw error;
      }
    }
  }
}

// At most `limit` names of `dir`, read in batches: a directory of a hundred
// thousand files is never listed whole.
function firstNames(dir, limit) {
  const handle = opendirSync(dir, { bufferSize: 1025 });
  const names = [];
  try {
    for (let entry; names.length < limit && (entry = handle.readSync()) !== null; ) names.push(entry.name);
  } finally {
    handle.closeSync();
  }
  return names;
}
