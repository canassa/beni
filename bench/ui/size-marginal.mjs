// Research 59 Q4(b): what one more model field, level of depth or hole adds
// to a beni `--release` bundle, by kind of emitted code. For two points of a
// sweep (built by `node scaling.mjs --build-only --full --sweeps=<s>
// --params=<a>,<b> --subjects=beni,beni-release`), the bundle is minified as
// sizes.mjs minifies it (terser `--compress --mangle --module`); each kind of
// per-element code is then cut out of the minified text by a pattern, and
// brotli 11 is taken with and without it. A kind's bytes per element are
// (its bytes at b − its bytes at a) / (b − a), the whole's likewise; the
// kinds need not sum to the whole, since brotli is not additive, and the
// rest is printed.
//
// `short-slots` is not a cut but a rename: every instance slot name
// (`w123`, `g45_0`, `a3`, `c1`) replaced by a short name of its own, as a
// renamer of instance slots would write them, to price their length.
//
//   node size-marginal.mjs [--sweeps=width,depth,holes]

import { readdirSync, readFileSync, statSync } from "node:fs";
import { createRequire } from "node:module";
import { join } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";
import { root } from "./lib/serve.mjs";

const require = createRequire(join(root, "apps/solid2/package.json"));
const { minify } = require("terser");
const arg = (name, fallback) => process.argv.find((a) => a.startsWith(`--${name}=`))?.slice(name.length + 3) ?? fallback;

const br = (s) => brotliCompressSync(Buffer.from(s), { params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: s.length } }).length;
const walk = (dir) =>
  readdirSync(dir)
    .sort()
    .flatMap((f) => {
      const p = join(dir, f);
      return statSync(p).isDirectory() ? walk(p) : /\.(m?js)$/.test(f) ? [p] : [];
    });
const minified = async (dir) => {
  const out = [];
  for (const f of walk(dir)) out.push((await minify(readFileSync(f, "utf8"), { compress: true, mangle: true, module: true })).code);
  return out.join("\n");
};

// A short name per distinct match, in order of first appearance.
const shortNames = (re) => (text) => {
  const names = new Map();
  const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
  const name = (i) => (i < 52 ? `$${letters[i]}` : `$${letters[i % 52]}${name(Math.floor(i / 52) - 1).slice(1)}`);
  return text.replace(re, (m) => {
    if (!names.has(m)) names.set(m, name(names.size));
    return names.get(m);
  });
};
const slotRe = /(?<=[.,{(]|\b)(?:w\d+|g\d+_\d+|a\d+|c\d+)(?=[:=!.,;)}\s])/g;

const sweeps = {
  width: {
    points: [128, 256],
    kinds: [
      // `let x=m.f;x!==i.gN_0&&(i.gN_0=x,i.wM.data=x)` in the root's patch
      ["patch: read, compare, remember, write", /let [\w$]+=[\w$]+\.[\w$]+;([\w$]+)!==[\w$]+\.g\d+_0&&\([\w$]+\.g\d+_0=\1,[\w$]+\.w\d+\.data=\1\);?/g],
      // the instance's slots: `wM:node,` and `gN_0:NaN,`
      ["instance slots: node and last value", /(?:w\d+:[\w$]+|g\d+_0:NaN),?/g],
      // the mount's walk to each hole: `a=b.nextSibling,c=a.firstChild,`
      ["mount: walk to the hole", /[\w$]+=[\w$]+(?:\.nextSibling)?\.(?:nextSibling|firstChild),/g],
      // `init`'s field: `ab:12,`
      ["init: the field's initial value", /(?<=[{,])[\w$]+:\d+(?=[,}])/g],
      // the template's `<p> </p>`
      ["template text", /<p> <\/p>/g],
    ],
    rename: true,
  },
  depth: {
    points: [64, 128],
    kinds: [
      // a level's patch: label compare and write, child compare, child slot render or refresh
      ["patch function (one per level)", /[\w$]+=\([\w$]+,[\w$]+\)=>\{let [\w$]+=[\w$]+\[0\],[\w$]+=[\w$]+\.e;.*?\.l=[\w$]+\.c1\.l\},?/g],
      // a level's kind: `{m:(…)=>{clone, instance with its walk and slot, patch},p:…,l:!0}`
      ["kind: mount and instance (one per level)", /[\w$]+=\{m:\([\w$]+,[\w$]+\)=>\{let .*?return [\w$]+\([\w$]+,[\w$]+\),[\w$]+\},p:[\w$]+,l:!0\},?/g],
      // a level's template: `x=g("<div class=level><span> ")`
      ["template (one per level, the same text)", /[\w$]+=[\w$]+\("<div class=level><span> "\),?/g],
      // a level's update helper: `x=a=>({...a,c:y(a.c)})`
      ["bump: the update helper", /[\w$]+=[\w$]+=>\(\{\.\.\.[\w$]+,[\w$]+:[\w$]+\([\w$]+\.[\w$]+\)\}\),?/g],
      // a level's initial record, which terser nests into one literal: its label
      ["init: the level's label", /,?[\w$]+:"level \d+"/g],
    ],
    rename: true,
  },
  holes: {
    points: [100, 1000],
    kinds: [
      // the write in its value's group: `i.wN.data=x,` or `i.wN.setAttribute("class",x),`
      ["patch: the write in its group", /[\w$]+\.w\d+\.(?:data=[\w$]+|setAttribute\("class",[\w$]+\))[,;]?/g],
      ["instance slot: the node", /w\d+:[\w$]+,?/g],
      ["mount: walk to the hole", /[\w$]+=[\w$]+(?:\.nextSibling)?\.(?:nextSibling|firstChild),/g],
      ["template text", /<p> <\/p>|<p>x<\/p>/g],
    ],
    rename: true,
  },
};

for (const id of arg("sweeps", "width,depth,holes").split(",")) {
  const s = sweeps[id];
  const [a, b] = s.points;
  const texts = [await minified(join(root, `out/scaling/${id}/${a}/beni-rel`)), await minified(join(root, `out/scaling/${id}/${b}/beni-rel`))];
  const whole = texts.map(br);
  const per = (x) => (x[1] - x[0]) / (b - a);
  console.log(`\n### ${id}, ${a} → ${b}: ${whole[0]} → ${whole[1]} B, ${per(whole).toFixed(1)} B per element\n`);
  console.log("| kind | matches at a, b | raw chars per element | brotli B per element |");
  console.log("|---|--:|--:|--:|");
  let sum = 0;
  for (const [name, re] of s.kinds) {
    const counts = texts.map((t) => (t.match(re) ?? []).length);
    const raw = texts.map((t) => (t.match(re) ?? []).join("").length);
    const saved = texts.map((t, i) => whole[i] - br(t.replace(re, "")));
    sum += per(saved);
    console.log(`| ${name} | ${counts.join(", ")} | ${per(raw).toFixed(1)} | ${per(saved).toFixed(1)} |`);
  }
  console.log(`| (the rest, by difference) | | | ${(per(whole) - sum).toFixed(1)} |`);
  const allCut = texts.map((t, i) => whole[i] - br(s.kinds.reduce((x, [, re]) => x.replace(re, ""), t)));
  console.log(`| every kind above, cut together | | | ${per(allCut).toFixed(1)} |`);
  if (s.rename) {
    const renamed = texts.map((t) => br(shortNames(slotRe)(t)));
    console.log(`\nshort-slots: ${renamed[0]} → ${renamed[1]} B, ${per(renamed).toFixed(1)} B per element (saves ${(per(whole) - per(renamed)).toFixed(1)})`);
  }
}
