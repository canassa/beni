// Four views side by side: the units that make each one in tea, direct and
// Solid, their raw bytes and what deleting them alone takes out of the
// response, and a pretty-printed excerpt of each for the report.
// A beni unit belongs to a view when the release map puts its first mapped
// byte inside the view's source lines (markup units carry no beni name).
//   node bench/app-code-size/views.mjs [results dir]
import fs from 'node:fs';
import {TraceMap, originalPositionFor} from '../output-size/node_modules/@jridgewell/trace-mapping/dist/trace-mapping.mjs';
import {minify} from '../output-size/node_modules/terser/main.js';
import {br, readGz} from '../output-size/lib.mjs';
import {units} from '../output-size/units.mjs';

const dir = process.argv[2] ?? 'bench/app-code-size/results';
// [module, first line, last line] of the beni source, and Solid's units by name.
export const VIEWS = {
  'feed list and article preview': {
    beni: [['Feed', 73, 153], ['Article', 231, 238], ['Article', 246, 272], ['Author', 101, 129]],
    solid: ['$t', 'pt', 'gt', 'vt', 'at', 'ct', 'ut', 'dt', 'ft', 'ht', 'mt', 'bt', 'yt', 'wt'],
  },
  'article page with comments': {
    beni: [['ArticlePage', 215, 407], ['Article', 239, 245], ['Author', 130, 146]],
    solid: ['Yt', 'Wt', 'qt', 'Ft', 'Vt', 'Mt', 'It', 'Rt', 'Ht', 'Gt', 'Kt', 'Bt', 'zt', 'Ut', 'jt', 'Dt', 'Lt', 'Et', 'Tt', 'Qt'],
  },
  'editor form': {
    beni: [['Editor', 241, 357]],
    solid: ['nn', 'en', 'tn'],
  },
  'header, navigation and footer': {
    beni: [['Page', 26, 94]],
    solid: ['Ye', 'Re', 'We', 'Ge', 'He', 'Ke', 'Me'],
  },
};
const lineOf = (tm, src, off) => {
  let line = 1, col = 0; for (let i = 0; i < off; i++) { if (src[i] === '\n') { line++; col = 0; } else col++; }
  return originalPositionFor(tm, {line, column: col});
};
const pretty = async code => (await minify(code, {compress: false, mangle: false, module: true, format: {beautify: true, indent_level: 2, comments: false}})).code;
const out = {};
fs.mkdirSync(`${dir}/excerpts`, {recursive: true});
for (const p of ['tea', 'direct', 'solid']) {
  const src = p === 'solid' ? readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.gz') : readGz(`${dir}/beni-${p}.mjs.gz`);
  const mapJson = JSON.parse(p === 'solid' ? readGz('bench/conduit-floor/results/solid-paragraphs-single--index.js.map.gz') : readGz(`${dir}/beni-${p}.mjs.map.gz`));
  const tm = new TraceMap(mapJson);
  const {units: us} = units(src, mapJson);
  const base = br(src);
  for (const [view, spec] of Object.entries(VIEWS)) {
    let picked;
    if (p === 'solid') picked = us.filter(u => spec.solid.includes(u.js));
    else picked = us.filter(u => {
      if (!u.owner.startsWith('app/') || /\$\$/.test(u.orig ?? '')) return false;
      const pos = lineOf(tm, src, u.start); const m = u.owner.slice(4);
      return spec.beni.some(([mod, a, b]) => mod === m && pos.line >= a && pos.line <= b);
    });
    picked.sort((a, b) => b.start - a.start);
    let s = src; for (const u of picked) s = s.slice(0, u.start) + s.slice(u.end);
    const raw = picked.reduce((n, u) => n + u.raw, 0);
    (out[view] ??= {})[p] = {units: picked.length, raw, alone: base - br(s), names: picked.map(u => `${u.js}${u.orig ? `(${u.orig})` : ''}`).reverse()};
    const parts = [];
    for (const u of picked.slice().reverse()) {
      const t = src.slice(u.start, u.end), code = u.js === '(stmt)' || /^(async )?function/.test(t) ? t : `let ${t};`;
      parts.push(`// ${u.js}${u.orig ? ` (${u.orig})` : ''}: ${u.raw} B raw\n` + await pretty(code).catch(() => code));
    }
    fs.writeFileSync(`${dir}/excerpts/${view.replace(/[^a-z]+/g, '-')}.${p}.js`, parts.join('\n'));
    console.log(p, view, out[view][p].units, raw, out[view][p].alone);
  }
}
fs.writeFileSync(`${dir}/views.json`, JSON.stringify(out, null, 2) + '\n');
