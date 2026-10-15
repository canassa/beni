// Every byte of Conduit's app code by construct, for tea and direct.
//
// classify.mjs paints each byte of the two areas (views; update/init/
// requests) with a construct. Here each construct is priced in the whole
// response, research 99's two accounts on bytes rather than on units:
//   alone:   delete that construct's bytes from the full bundle, recompress;
//   ordered: delete the constructs cumulatively in table order.
// The ordered rows of an area sum exactly to the area's cost: the full bundle
// minus the bundle with every byte of that area deleted (core, platform and
// schemas stay as context). Deleted variants are not JavaScript any more; they
// locate a cost in context and are never run, as 99/102's stubs were not.
//   node bench/app-code-size/account.mjs [results dir]
import fs from 'node:fs';
import {size, br, readGz} from '../output-size/lib.mjs';
import {classify, VIEW_CLASSES, LOGIC_CLASSES, subAreaOf} from './classify.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
const out = {method: 'brotli 11 with size hint, one response. Bytes painted by construct (classify.mjs); alone = delete one construct; ordered = delete cumulatively in table order; area = full minus full-without-area.', subjects: {}};
const without = (src, keep) => { let s = ''; for (let i = 0; i < src.length; i++) if (keep(i)) s += src[i]; return s; };
for (const p of ['tea', 'direct']) {
  const src = readGz(`${dir}/beni-${p}.mjs.gz`), map = JSON.parse(readGz(`${dir}/beni-${p}.mjs.map.gz`));
  const {us, label, area} = classify(src, map, p);
  const base = size(src);
  const subj = {baseline: base, areas: {}};
  // raw bytes per sub-area (102's rows)
  const sub = {};
  for (const u of us) { const a = area[u.start]; if (!a) continue; const k = subAreaOf(u); sub[k] = (sub[k] ?? 0) + u.raw; }
  subj.subAreaRaw = sub;
  for (const [ar, classes] of [['views', VIEW_CLASSES], ['logic', LOGIC_CLASSES]]) {
    const raw = {}; for (let i = 0; i < src.length; i++) if (area[i] === ar) raw[label[i]] = (raw[label[i]] ?? 0) + Buffer.byteLength(src[i]);
    for (const k of Object.keys(raw)) if (!classes.some(c => c[0] === k)) throw Error(`unlisted class ${k} in ${ar}`);
    const areaCost = base.brotli - br(without(src, i => area[i] !== ar));
    const rows = []; const gone = new Set(); let prev = base.brotli;
    for (const [k, title] of classes) {
      if (!raw[k]) continue;
      const alone = base.brotli - br(without(src, i => !(area[i] === ar && label[i] === k)));
      gone.add(k);
      const now = br(without(src, i => !(area[i] === ar && gone.has(label[i]))));
      rows.push({class: k, title, raw: raw[k], alone, ordered: prev - now}); prev = now;
    }
    subj.areas[ar] = {raw: Object.values(raw).reduce((a, b) => a + b, 0), cost: areaCost, rows};
    console.log(`${p} ${ar}: raw ${subj.areas[ar].raw}, cost ${areaCost}`);
    for (const r of rows) console.log(`  ${r.title.padEnd(78)} ${String(r.raw).padStart(7)} ${String(r.alone).padStart(6)} ${String(r.ordered).padStart(6)}`);
  }
  subj.appCost = base.brotli - br(without(src, i => area[i] === null)); // both areas together
  console.log(`${p} app (views + logic) cost ${subj.appCost}`);
  out.subjects[p] = subj;
}
fs.writeFileSync(`${dir}/account.json`, JSON.stringify(out, null, 2) + '\n');
