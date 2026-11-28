// corpus.mjs: the corpus's programs as a sweep, for run.mjs (research report 140).
//
//   node bench/ownership-sweeps/corpus.mjs <outdir> [filter]
//
// Writes one directory per program under <outdir>, of links to the fixture's files, and <outdir>/LIST:
// `run/` (node, or the fixture's own `platform/`), `browser/` pages (`tests/platforms/page`),
// `browser/inline/` (`browser-inline`), `browser/prerender/` (`browser-inline`, compared by the pages the
// build writes: a `PRERENDER` file), and, to list their faults, `browser/dom/` and `browser/managed/`
// (`browser`) and `browser/tea/` (`browser-tea`). A `run/` server program (`.requests`) and a project
// with no `.beni` file at its top are left out; the count of each is printed.
import fs from 'node:fs';
import path from 'node:path';

const [out, filter] = process.argv.slice(2);
if (!out) {
  console.error('usage: node bench/ownership-sweeps/corpus.mjs <outdir> [filter]');
  process.exit(2);
}
const root = path.resolve(path.dirname(new URL(import.meta.url).pathname), '../..');
const corpus = path.join(root, 'tests/corpus');
const list = [];
const skipped = { requests: 0, nested: 0 };

function add(group, name, files, platform, extra = {}) {
  const dir = path.join(out, group, name);
  if (filter && !dir.includes(filter)) return;
  fs.mkdirSync(dir, { recursive: true });
  for (const [as, from] of Object.entries(files)) {
    const to = path.join(dir, as);
    if (!fs.existsSync(to)) fs.symlinkSync(from, to);
  }
  if (platform) fs.writeFileSync(path.join(dir, 'PLATFORM'), `${platform}\n`);
  for (const [as, text] of Object.entries(extra)) fs.writeFileSync(path.join(dir, as), text);
  list.push(path.resolve(dir));
}

// Each fixture of `kind`: a single file `X.beni` (with `X.steps`), or a project directory.
function collect(group, rel, platform, { page = false, prerender = false } = {}) {
  const at = path.join(corpus, rel);
  if (!fs.existsSync(at)) return;
  for (const entry of fs.readdirSync(at, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(at, entry.name);
    if (entry.isFile() && entry.name.endsWith('.beni')) {
      const name = entry.name.slice(0, -5);
      if (fs.existsSync(path.join(at, `${name}.requests`))) { skipped.requests++; continue; }
      const files = { [entry.name]: full };
      if (page) {
        if (!fs.existsSync(path.join(at, `${name}.steps`))) continue;
        files.steps = path.join(at, `${name}.steps`);
      }
      add(group, name, files, platform);
    } else if (entry.isDirectory()) {
      const names = fs.readdirSync(full);
      if (!names.some((n) => n.endsWith('.beni'))) { skipped.nested++; continue; }
      if (names.some((n) => n.endsWith('.requests'))) { skipped.requests++; continue; }
      const files = {};
      for (const n of names) {
        if (n === 'platform' || n.startsWith('_expected') || n.startsWith('out')) continue;
        files[n] = path.join(full, n);
      }
      if (page && !prerender) {
        if (!names.includes('_expected.steps')) continue;
        files.steps = path.join(full, '_expected.steps');
      }
      const own = names.includes('platform') ? path.relative(root, path.join(full, 'platform')) : platform;
      add(group, entry.name, files, own, prerender ? { PRERENDER: '' } : {});
    }
  }
}

collect('run', 'run', null);
collect('page', 'browser', 'tests/platforms/page', { page: true });
collect('inline', 'browser/inline', 'platforms/browser-inline', { page: true });
collect('prerender', 'browser/prerender', 'platforms/browser-inline', { page: true, prerender: true });
collect('dom', 'browser/dom', 'platforms/browser', { page: true });
collect('managed', 'browser/managed', 'platforms/browser', { page: true });
collect('tea', 'browser/tea', 'platforms/browser-tea', { page: true });
fs.mkdirSync(out, { recursive: true });
fs.writeFileSync(path.join(out, 'LIST'), list.map((l) => `${l}\n`).join(''));
console.log(`${list.length} programs; left out: ${skipped.requests} server programs, ${skipped.nested} projects with no top-level module`);
