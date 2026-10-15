// Price named groups of units "alone" (stub them in the original bundle and
// recompress), for the guarantee and opportunity tables. A group is a list
// of [source, original-name regex]. Nonexecutable; a cost in context.
// usage: node price.mjs   (subjects: baseline tea/direct and the jsonbody prototype)
import fs from 'node:fs';
import * as acorn from 'acorn';
import {br, readGz, apply} from './lib.mjs';
import {units} from './units.mjs';

const results = 'bench/output-size/results';
const groups = {
  'core/Schema, all': [['core/Schema', /./]],
  'core/Schema interpreter only (absent from the jsonbody prototype)': 'interpreter',
  'app schema readers ($$read)': [['app/', /\$\$read/]],
  'app schema printers ($$write)': [['app/', /\$\$write/]],
  'app schema descriptions ($$description)': [['app/', /\$\$description/]],
  'Http, all': [['platforms/browser/Http', /./]],
  'Http request checks: method, headers (no TypeError from fetch)': [['platforms/browser/Http', /^(problemOf|isToken|isForbiddenMethod|headerProblem|forbiddenHeaders|isForbiddenHeader|isHeaderValue|bodyProblem)$/]],
  'Http streamed body with progress (Http.track)': [['platforms/browser/Http', /^(chunks\$s|tracked\$s|transfer\$s|readingOf|size|utf8|received)$/]],
  'core/Task, all (fiber runtime)': [['core/Task', /./]],
  'Defect teardown: Task shutdown/teardown + Rt stop': [['core/Task', /^(shutdown|closeAll|teardown|recover|expire|deadlineTimer|culprit|torn|swept|sweeping|stopping|releaseAll|releasing|onShutdown|guard|halt|defect|onDefect)$/], ['platforms/browser/Rt', /^(stop|dead|deadline|stopped)$/]],
  'core/Dict, all': [['core/Dict', /./]],
  'core/Dict removal (remove, moveRed*, removeMin…)': [['core/Dict', /^(remove|removeHelp|removeHelpPrepEQGT|removeHelpEQGT|removeMin|moveRedLeft|moveRedRight|getMin)$/]],
  'core/List trie (trie*, putLeaf, pushedLeaves…)': [['core/List', /^(trie|putLeaf|pushedLeaves|rightGrow|treeRight|claim|header|chunks)/]],
  'core/List, all': [['core/List', /./]],
  'Navigation, all': [['platforms/browser/Browser/Navigation', /./]],
  'Url + Url.Parser + Url.Builder': [['core/Url', /./]],
  'Rt keyed rows (forKeyed, trimmed, reconcile)': [['platforms/browser/Rt', /^(forKeyed|trimmed|reconcile|forPosition|mountRow|patchRow|restateRows|putBackMarked|markEdit|markAndHold|putBack|edits)$/]],
};
const out = {};
const subjects = {tea: 'beni-tea', direct: 'beni-direct', 'jsonbody tea': 'proto-jsonbody-tea', 'jsonbody direct': 'proto-jsonbody-direct'};
const loaded = {};
for (const [name, prefix] of Object.entries(subjects)) {
  const src = readGz(`${results}/${prefix}.mjs.gz`), map = JSON.parse(readGz(`${results}/${prefix}.mjs.map.gz`));
  loaded[name] = {src, us: units(src, map).units};
}
const schemaNames = sub => new Set(loaded[sub].us.filter(u => u.owner === 'core/Schema').map(u => u.orig));
for (const [name, {src, us}] of Object.entries(loaded)) {
  const base = br(src), rows = {};
  for (const [g, spec] of Object.entries(groups)) {
    let pick;
    if (spec === 'interpreter') {
      if (name.startsWith('jsonbody')) continue;
      const kept = schemaNames(`jsonbody ${name}`);
      pick = us.filter(u => u.owner === 'core/Schema' && !kept.has(u.orig));
    } else pick = us.filter(u => spec.some(([o, re]) => u.owner.startsWith(o) && re.test(u.orig ?? '')));
    const edits = pick.map(u => u.stub).filter(s => s.node);
    const s = apply(src, edits); acorn.parse(s, {ecmaVersion: 'latest', sourceType: 'module'});
    rows[g] = {units: pick.length, raw: pick.reduce((n, u) => n + u.raw, 0), alone: base - br(s)};
  }
  out[name] = {baseline: base, rows};
  console.log(name, base); for (const [g, r] of Object.entries(rows)) console.log(`  ${g.padEnd(70)} ${String(r.units).padStart(4)} ${String(r.raw).padStart(6)} ${String(r.alone).padStart(6)}`);
}
fs.writeFileSync(`${results}/price.json`, JSON.stringify(out, null, 2) + '\n');
