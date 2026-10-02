// The shipped runtime behind the hooks claim-prepend-test.mjs reads of a prototype port. Since the
// list runtime moved to beni (core/List.beni, research 50) there is no JavaScript file to import:
// this builds compiled/Lists.beni with `--library` in development (the beni binary is $BENI, or
// zig-out/bin/beni) and loads the `_core/List.mjs` it writes — the runtime exactly as a program
// ships it. `$cons` is `cons`, `$tl` a pattern's tail (`view(xs, 1)`), `$hd` element 0, and the
// plain copy, the walk and the chunks all go through the reader protocol (`length`,
// `Array.isArray`, `$plain()`), which is all any code outside core/List may use (backend.md §4).
import { execFileSync } from 'node:child_process';
import { mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const beni = process.env.BENI ? resolve(process.env.BENI) : resolve(here, '../../../zig-out/bin/beni');
const out = mkdtempSync(join(tmpdir(), 'claim-core-'));
execFileSync(beni, ['build', '--library', '--no-cache', '--platform=node', `--out=${out}`, 'Lists.beni'], { cwd: join(here, 'compiled'), stdio: 'inherit' });
const L = await import(pathToFileURL(join(out, '_core/List.mjs')).href);
const f = (n) => {
  const v = L[`List$${n}`];
  if (typeof v !== 'function') throw new Error(`_core/List.mjs exports no List$${n}`);
  return v;
};
export const length = (xs) => xs.length;
export const push = f('push');
export const pop = f('pop');
export const set = f('set');
export const append = f('append');
export const slice = f('slice');
export const view = f('view');
export const unsafeGet = f('unsafeGet');
const cons = f('cons');
export const $nil = [];
export const $cons = (x, xs) => cons(x, xs);
export const $tl = (xs) => view(xs, 1);
export const $hd = (xs) => unsafeGet(xs, 0);
export const $isNil = (xs) => xs.length === 0;
const plain = (xs) => (Array.isArray(xs) ? xs : xs.$plain());
export const toJs = (xs) => plain(xs).slice();
export const walk = (xs, visit) => plain(xs).forEach((x, i) => visit(x, i));
export const kind = (xs) => (Array.isArray(xs) ? 'plain' : xs.o !== undefined ? 'view' : 'trie');
export const chunksOf = (xs) => [plain(xs)];
