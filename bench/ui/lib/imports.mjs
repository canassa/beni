// The files a module page loads: the module and, transitively, every file
// it imports by a relative path, in first-seen order. P3's pages (research
// 60) import core's modules from a beni development build, and their size
// is all of it.

import { readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";

// The closure as one scope-hoisted module, the shape beni's `--release`
// build ships (backend.md §9): every imported file first, its `export`
// list and every relative `import` removed. Names never collide: beni
// prefixes each top-level name with its module.
export function hoisted(entry) {
  const files = importClosure(entry).reverse();
  return files
    .map((f) =>
      readFileSync(f, "utf8")
        .replace(/^import\s*\{[^}]*\}\s*from\s*"\.\.?\/[^"]+";\s*$/gm, "")
        .replace(/^export\s*\{[^}]*\};?\s*$/gm, "")
        .replace(/^\/\/# sourceMappingURL=.*$/gm, ""),
    )
    .join("\n");
}

export function importClosure(entry) {
  const seen = [];
  const visit = (file) => {
    if (seen.includes(file)) return;
    seen.push(file);
    const text = readFileSync(file, "utf8");
    for (const m of text.matchAll(/\bfrom\s*"(\.\.?\/[^"]+)"/g)) visit(resolve(dirname(file), m[1]));
  };
  visit(resolve(entry));
  return seen;
}
