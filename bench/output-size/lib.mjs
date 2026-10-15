// Shared helpers: the research 97/99/101 byte protocol.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
import {brotliCompressSync, gzipSync, gunzipSync, constants} from 'node:zlib';

export const size = s => {
  const b = Buffer.from(s);
  return {
    raw: b.length,
    gzip: gzipSync(b, {level: 9}).length,
    brotli: brotliCompressSync(b, {params: {[constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: b.length}}).length,
  };
};
export const br = s => size(s).brotli;
export const hash = s => createHash('sha256').update(s).digest('hex');
export const readGz = p => gunzipSync(fs.readFileSync(p)).toString();
export const writeGz = (p, s) => fs.writeFileSync(p, gzipSync(s, {level: 9}));
export const walk = (n, fn, parent) => {
  if (!n?.type) return;
  if (fn(n, parent) === false) return;
  for (const v of Object.values(n)) {
    if (Array.isArray(v)) v.forEach(x => walk(x, fn, n));
    else if (v?.type) walk(v, fn, n);
  }
};
// Apply non-overlapping edits {start,end,text}; returns the new text.
export const apply = (s, edits) => {
  let end = s.length;
  for (const e of [...edits].sort((a, b) => b.start - a.start)) {
    if (e.end > end) throw Error('Overlapping edits');
    s = s.slice(0, e.start) + e.text + s.slice(e.end);
    end = e.start;
  }
  return s;
};
