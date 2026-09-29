// Report 40 §1: small experiments that show how brotli 11 prices this file. Each prints the
// brotli-11 size of array.min.js after one textual change that breaks the code but isolates one
// effect of the compressor. Run: node min/brotli-probes.mjs
import fs from 'node:fs';
import zlib from 'node:zlib';

const br = (s, extra = {}) => zlib.brotliCompressSync(Buffer.from(s), { params: { [zlib.constants.BROTLI_PARAM_QUALITY]: 11, ...extra } }).length;
const src = fs.readFileSync(new URL('./array.min.js', import.meta.url), 'utf8');
const base = br(src);
const show = (label, s) => console.log(`${label.padEnd(72)} ${String(s.length).padStart(5)} raw  ${String(br(s)).padStart(5)} br  ${br(s) - base >= 0 ? '+' : ''}${br(s) - base}`);
console.log(`array.min.js: ${src.length} raw, ${base} brotli-11, ${zlib.gzipSync(src, { level: 9 }).length} gzip-9\n`);

// 1. The static dictionary. Replace every occurrence of a word that IS in brotli's dictionary by a
//    same-length string that is not; the difference is what the dictionary saved on the word's
//    first occurrence (later ones are ordinary back-references either way). A control word that
//    is not in the dictionary shows the same change's cost without a dictionary hit.
for (const [w, x] of [['length', 'lqngth'], ['slice', 'slqce'], ['push', 'pqsh'], ['return', 'rqturn'], ['Array', 'Arqay'], ['concat', 'cqncat'], ['sortWith', 'sqrtWith']]) {
  show(`dictionary probe: every "${w}" -> "${x}" (${src.split(w).length - 1} occurrences)`, src.split(w).join(x));
}

// 2. Repetition is nearly free, and the nearer the cheaper. Duplicate one statement with its name
//    changed, right after itself, and at the far end of the file.
const stmt = src.match(/let S=[^;]*;/)[0];
const dup = stmt.replace('let S=', 'let Q=').replace(/S\(/g, 'Q(');
show(`one ${stmt.length}-byte statement duplicated, adjacent`, src.replace(stmt, stmt + dup));
show(`the same duplicate, at the far end of the file`, src + dup);
show(`the same statement with every local renamed (x,s,i,v -> p,q,u,w), at the end`, src + dup.replace(/\bx\b/g, 'p').replace(/\bs\b/g, 'q').replace(/\bi\b/g, 'u').replace(/\bv\b/g, 'w'));

// 3. Unique short names do not compress: every top-level name is one literal whichever letter it is.
show('every top-level name made two letters (A -> AA, …)', src.replace(/\b([A-Z])\b/g, '$1$1'));

// 4. Window size is irrelevant below 1 KiB of window; quality matters.
for (const q of [5, 9, 10, 11]) console.log(`quality ${q}: ${br(src, { [zlib.constants.BROTLI_PARAM_QUALITY]: q })}`);
for (const w of [10, 16, 22]) console.log(`quality 11, lgwin ${w}: ${br(src, { [zlib.constants.BROTLI_PARAM_LGWIN]: w })}`);
console.log(`quality 11, text mode hint: ${br(src, { [zlib.constants.BROTLI_PARAM_MODE]: zlib.constants.BROTLI_MODE_TEXT })}`);
