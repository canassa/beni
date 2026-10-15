// Run every bundle-edit prototype on the archived bundles (and the stack on
// the jsonbody prototype), price each, run Conduit's three corpus scripts
// against each edited bundle, and write results/edits.json.
// Needs build.mjs's output tree (zig-out/output-size/<platform>/) for verify.
import fs from 'node:fs';
import {execFileSync, spawnSync} from 'node:child_process';
import {br, readGz} from './lib.mjs';

const R = 'bench/output-size/results', W = 'zig-out/output-size/edits';
fs.mkdirSync(W, {recursive: true});
const node = (script, ...args) => execFileSync('node', [`bench/output-size/${script}`, ...args], {encoding: 'utf8'});
const verify = (p, file, label) => spawnSync('node', ['bench/output-size/verify.mjs', p, file, label], {encoding: 'utf8'});
const out = {};
for (const p of ['tea', 'direct']) {
  const base = `${W}/${p}.mjs`;
  fs.writeFileSync(base, readGz(`${R}/beni-${p}.mjs.gz`));
  const s = fs.readFileSync(base, 'utf8');
  fs.writeFileSync(`${W}/${p}.andtrue.mjs`, s.replaceAll('&&true)', ')'));
  node('inline-toplevel.mjs', base, `${W}/${p}.inline.mjs`);
  node('schema-outline.mjs', base, `${W}/${p}.schema.mjs`);
  node('quotes.mjs', base, `${W}/${p}.quotes.mjs`);
  fs.writeFileSync(`${W}/${p}.jsonbody.mjs`, readGz(`${R}/proto-jsonbody-${p}.mjs.gz`));
  // The prototype helper maps an unprintable value to the empty body; put back
  // Http.jsonBody's typed `Unprintable issues` (tag 3, as the baseline builds it).
  const helper = /(=\(a,b\)=>\{let c=a\(b\);return c\.\$===0\?\{\$:1,a:"application\/json",b:c\.a\}:)[\w$]+\}/;
  const jb = fs.readFileSync(`${W}/${p}.jsonbody.mjs`, 'utf8');
  if (!helper.test(jb)) throw Error('jsonText helper not found');
  fs.writeFileSync(`${W}/${p}.jsontyped.mjs`, jb.replace(helper, (m, head) => `${head}{$:3,a:c.a,b:null}}`));
  node('inline-toplevel.mjs', `${W}/${p}.jsontyped.mjs`, `${W}/${p}.stack.mjs`);
  const b = br(s);
  out[p] = {baseline: b};
  for (const v of ['andtrue', 'inline', 'schema', 'quotes', 'jsonbody', 'jsontyped', 'stack']) {
    const f = `${W}/${p}.${v}.mjs`, r = verify(p, f, `edit-${v}`);
    out[p][v] = {brotli: br(fs.readFileSync(f, 'utf8')), saved: b - br(fs.readFileSync(f, 'utf8')), corpusScripts: r.status === 0 ? 'all three match the golden' : r.stdout};
    console.log(p, v, out[p][v].saved, out[p][v].corpusScripts);
  }
}
fs.writeFileSync(`${R}/edits.json`, JSON.stringify({note: 'saved = brotli bytes saved against the unchanged release bundle; jsontyped = jsonbody with the typed Unprintable error put back; stack = jsontyped + top-level single-use inlining. Every variant was run through ConduitEditor, ConduitReader and ConduitTour.', ...out}, null, 2) + '\n');
