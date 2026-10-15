// Cut a --release bundle into top-level units and give each its provenance
// from the release source map: the source owning most of its raw bytes, the
// original beni name at its binding, and its raw bytes per source.
import * as acorn from 'acorn';
import {TraceMap, eachMapping} from '@jridgewell/trace-mapping';

export const shortSource = s => s == null ? 'unmapped' : (s.startsWith('beni:///') ? s.replace('beni:///', '') : 'app/' + s.replace(/^.*\//, '')).replace(/\.beni$/, '');

export function units(src, mapJson) {
  const map = new TraceMap(mapJson);
  const lines = [0]; for (let i = 0; i < src.length; i++) if (src[i] === '\n') lines.push(i + 1);
  const segs = [];
  eachMapping(map, m => segs.push({offset: lines[m.generatedLine - 1] + m.generatedColumn, source: shortSource(m.source), name: m.name}));
  segs.sort((a, b) => a.offset - b.offset);
  // segment i covers [offset_i, offset_{i+1})
  const segAt = off => { let l = 0, h = segs.length - 1; while (l < h) { const m = (l + h + 1) >> 1; if (segs[m].offset <= off) l = m; else h = m - 1; } return l; };
  const bytesBySource = (start, end) => {
    const r = {};
    if (!segs.length || start >= end) return r;
    if (start < segs[0].offset) { const e = Math.min(end, segs[0].offset); r.unmapped = (r.unmapped ?? 0) + Buffer.byteLength(src.slice(start, e)); start = e; }
    for (let i = segAt(start); i < segs.length && segs[i].offset < end; i++) {
      const a = Math.max(start, segs[i].offset), b = Math.min(end, segs[i + 1]?.offset ?? src.length);
      if (b > a) r[segs[i].source] = (r[segs[i].source] ?? 0) + Buffer.byteLength(src.slice(a, b));
    }
    return r;
  };
  const nameAt = off => { const i = segAt(off); return segs[i]?.offset === off ? segs[i].name : undefined; };
  const ast = acorn.parse(src, {ecmaVersion: 'latest', sourceType: 'module'});
  const out = [];
  const push = (node, stub, js, decl) => {
    const by = bytesBySource(node.start, node.end);
    const total = Object.values(by).reduce((a, b) => a + b, 0);
    const [owner, ownBytes] = Object.entries(by).sort((a, b) => b[1] - a[1])[0] ?? ['unmapped', 0];
    out.push({js, orig: decl ? (nameAt(decl.start) ?? nameAt(stub.start)) : undefined, start: node.start, end: node.end, raw: total,
      owner, purity: total ? ownBytes / total : 1, by, stub, node: stub.node});
  };
  for (const s of ast.body) {
    if (s.type === 'VariableDeclaration') {
      for (const d of s.declarations) push(d, d.init ? {start: d.init.start, end: d.init.end, text: '0', node: d.init} : {start: d.end, end: d.end, text: '', node: null}, d.id.name, d.id);
    } else if (s.type === 'FunctionDeclaration') {
      push(s, {start: s.body.start, end: s.body.end, text: '{}', node: s.body}, s.id.name, s.id);
    } else if (s.type === 'ExpressionStatement') {
      push(s, {start: s.start, end: s.end, text: '0;', node: s}, '(stmt)');
    } else {
      push(s, {start: s.end, end: s.end, text: '', node: null}, `(${s.type})`);
    }
  }
  // gaps between statements (keywords `const`/`let`, commas) are charged by bytesBySource too
  const whole = bytesBySource(0, src.length);
  return {units: out, whole, ast, segs};
}
