// Print units of a bundle with their bytes bracketed by construct class:
// ⟦class: text⟧. For checking the classifier by eye.
//   node bench/app-code-size/show.mjs <tea|direct> <regex on owner or orig> [dir]
import {readGz} from '../output-size/lib.mjs';
import {classify} from './classify.mjs';
const [p, re, dir = 'bench/app-code-size/results'] = process.argv.slice(2);
const src = readGz(`${dir}/beni-${p}.mjs.gz`), map = JSON.parse(readGz(`${dir}/beni-${p}.mjs.map.gz`));
const {us, label} = classify(src, map, p);
const rx = new RegExp(re);
for (const u of us) {
  if (!(rx.test(u.owner) || rx.test(u.orig ?? ''))) continue;
  let out = `// ${u.owner} ${u.orig}\n`, cur = null;
  for (let i = u.start; i < u.end; i++) {
    if (label[i] !== cur) { if (cur) out += '⟧'; cur = label[i]; if (cur) out += `⟦${cur}:`; }
    out += src[i];
  }
  if (cur) out += '⟧';
  console.log(out + '\n');
}
