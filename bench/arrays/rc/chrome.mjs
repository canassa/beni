// research/42 §6.8: a spot check of the array scenarios in headless Chrome, through
// bench/ui/lib/cdp.mjs. One page per variant, each running the same IIFE bundle rc/rc.mjs's
// `bench` runs under Node (the `memory` scenario needs Node and is skipped). Results go to
// results/rc-chrome.jsonl with engine "chrome".
//
//   CHROME=<path to chromium> node rc/chrome.mjs [taskset cpu] [variant[:sc,…]…]
import * as esbuild from 'esbuild';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { launch } from '../../ui/lib/cdp.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, '..');
process.chdir(root);
const cpu = process.argv[2] ?? null;
const specs = process.argv.slice(3).length ? process.argv.slice(3) : ['adaptive', 'R0', 'R1', 'R2', 'R2plain'];
// bundle through rc.mjs's own plugin: reuse it by importing the module would run its CLI, so the
// bundles are the ones `node rc/rc.mjs bench` leaves in dist/ (build them first)
const browser = await launch({ taskset: cpu });
console.log(browser.version);
for (const spec of specs) {
  const [name, scs] = spec.split(':');
  const sc = scs ? scs.split(',') : ['table', 'decoded', 'grid', 'build', 'history', 'interop'];
  const bundleFile = path.join(root, 'dist', `rc-chrome-${name}.js`);
  const src = fs.readFileSync(path.join(root, 'dist', `rc-bench-2-${name}.js`), 'utf8')
    .replace(/run\("[^"]+", \[[^\]]*\]\);/, `run(${JSON.stringify(name)}, ${JSON.stringify(sc)});`);
  if (!src.includes(`run(${JSON.stringify(name)}, ${JSON.stringify(sc)});`)) throw new Error('could not retarget the bundle');
  fs.writeFileSync(bundleFile, src);
  const page = await browser.newPage('about:blank');
  const lines = [];
  const off = browser.on((msg) => {
    if (msg.sessionId === page.sessionId && msg.method === 'Runtime.consoleAPICalled') {
      const t = msg.params.args.map((a) => a.value).join(' ');
      if (t.startsWith('{')) lines.push(JSON.parse(t));
    }
  });
  const t0 = Date.now();
  await page.eval(`globalThis.process = { env: {} }; ${src}; 1`);
  off();
  await page.close();
  fs.appendFileSync('results/rc-chrome.jsonl', lines.map((l) => JSON.stringify({ ...l, engine: 'chrome' })).join('\n') + '\n');
  console.log(name, lines.length, 'cells', ((Date.now() - t0) / 1000).toFixed(1) + ' s');
}
await browser.close();
