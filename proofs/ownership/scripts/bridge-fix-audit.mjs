#!/usr/bin/env node
// Judge original program leads from a completed bridge campaign and replay the
// retained reverse leads. Neither interpreter is gated on a checker verdict.
import {readFile, writeFile, mkdir, mkdtemp, rm, readdir} from 'node:fs/promises';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {resolve, dirname} from 'node:path';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {gzipSync, gunzipSync} from 'node:zlib';
import assert from 'node:assert/strict';
import {translate} from './bridge-translate.mjs';
import {historicalFixedPrefix} from './bridge-fixed-prefix.mjs';
const [campaignArg, compilerArg, outputArg] = process.argv.slice(2);
assert(campaignArg && compilerArg && outputArg && process.argv.length === 5,
  'usage: bridge-fix-audit.mjs campaign-directory compiler output-directory');
const own = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const campaign = resolve(campaignArg), compiler = resolve(compilerArg), output = resolve(outputArg);
const exec = promisify(execFile), hash = x => createHash('sha256').update(x).digest('hex');
// The export stream an id belongs to (Bridge.writeExport's ids).
const streamOf = id => {
  let m = id.match(/^(seed|v6)-(\d+)-\d+$/);
  if (m) return `${m[1] === 'seed' ? 'generator' : 'generator6'}-${m[2]}.jsonl`;
  return /^enum-/.test(id) ? 'enumerate-0.jsonl' : 'fixtures-0.jsonl';
};
const report = JSON.parse(await readFile(resolve(campaign, 'report.json'), 'utf8'));
assert.equal(hash(await readFile(compiler)), report.environment.compilerSha256, 'campaign compiler changed');
await mkdir(output, {recursive: true});
await rm(resolve(output, 'audit.json'), {force: true});
const leads = report.cases.filter(c => c.programLead);
assert.equal(leads.length, report.leads);
const work = await mkdtemp(resolve(campaign, 'audit-'));
try {
  const inputs = [], originalSources = new Map();
  for (const c of leads) {
    const e = JSON.parse(await readFile(resolve(campaign, 'cases', c.id, 'evidence.json'), 'utf8'));
    assert.equal(e.id, c.id);
    assert.equal(e.record[5], false);
    assert.equal(e.record[8], c.lean);
    const dir = resolve(campaign, 'cases', c.id);
    const sources = (await readdir(dir)).filter(n => n.endsWith('.beni') && n !== 'Minimal.beni');
    assert.equal(sources.length, 1);
    const source = await readFile(resolve(dir, sources[0]), 'utf8');
    assert.equal(source, translate(e.declarations, e.record[4]).source, 'original source fidelity');
    originalSources.set(c.id, source);
    inputs.push(c.id + '\t' + JSON.stringify([e.declarations, e.record[4]]));
  }
  const input = resolve(work, 'originals.tsv'), judged = resolve(work, 'judgments.jsonl');
  await writeFile(input, inputs.join('\n') + (inputs.length ? '\n' : ''));
  await exec(resolve(own, '.lake/build/bin/triage'), [input, judged, '--only'], {maxBuffer: 32 * 1024 * 1024});
  const judgments = (await readFile(judged, 'utf8')).trim().split('\n').filter(Boolean).map(JSON.parse);
  assert.equal(judgments.length, leads.length);
  const byId = new Map(leads.map(c => [c.id, c]));
  const seen = new Set();
  for (const row of judgments) {
    assert(byId.has(row.id) && !seen.has(row.id)); seen.add(row.id);
    assert.equal(row.lean, byId.get(row.id).lean);
    assert.equal(translate(...row.core).source, originalSources.get(row.id), 'judge core source fidelity');
    assert.equal(row.diverges, JSON.stringify(row.value) !== JSON.stringify(row.inPlace));
  }
  const confirmed = judgments.filter(r => r.diverges).map(r => r.id);
  // These 401 sources include every original Zig-refuses/Lean-accepts lead.
  const old = JSON.parse(gunzipSync(await readFile(resolve(own, 'evidence/bridge-triage/precision.json.gz'))));
  assert.equal(old.leads.length, 401);
  const reverse = [];
  for (let offset = 0; offset < old.leads.length; offset += 64) {
    const batch = old.leads.slice(offset, offset + 64), dir = resolve(work, 'reverse-' + offset);
    await mkdir(dir);
    for (const p of batch) await writeFile(resolve(dir, p.module + '.beni'), p.source);
    const {stdout} = await exec(compiler, ['dump', '--stage=ownership', '--platform=browser-direct', '--jobs=1', dir], {maxBuffer: 32 * 1024 * 1024});
    const rows = new Map(); let current;
    for (const line of stdout.split('\n')) {
      if (!line) continue;
      const module = line.match(/^module (\S+)$/);
      if (module) { assert(!rows.has(module[1])); current = []; rows.set(module[1], current); continue; }
      const demand = line.match(/^  (\d+):(\d+) (.+?): (accepted|rejected|pending)(?:(?: |: ?)(.*))?$/);
      if (demand) {
        assert(current);
        if (demand[4] !== 'accepted') current.push({row: +demand[1], col: +demand[2], operation: demand[3], verdict: demand[4], detail: demand[5] ?? ''});
      } else assert(/^  (summary |value |demands )|^(total |cause |pending )/.test(line), 'unparsed dump: ' + line);
    }
    assert.equal(rows.size, batch.length);
    for (const p of batch) {
      assert(rows.has(p.module)); const refusals = rows.get(p.module);
      reverse.push({id: p.id, before: p.refusals, after: refusals, accepted: refusals.length === 0,
        changed: JSON.stringify(p.refusals) !== JSON.stringify(refusals)});
    }
  }
  const clusters = JSON.parse(await readFile(resolve(own, 'evidence/bridge-triage/clusters.json'), 'utf8'));
  // The canonical campaigns: CI (bound 1, 128 programs per generator) and
  // long (bound 2, 20,000 programs per generator and seed, three seeds).
  const isLong = report.streams.some(s => s.name === 'generator-314159.jsonl');
  const isCi = !isLong && report.streams.some(s => s.name === 'generator-17.jsonl') &&
    report.streams.find(s => s.name === 'generator-17.jsonl').programs === 128;
  // The historical streams: the oracle extension's campaign of 2026-10-15
  // (116,650 / 960 inputs), before function-valued results were translated
  // and before generator v6. Its generator and enumeration streams must be
  // byte exact here; their translation counts change with the translator.
  const baseline = JSON.parse(await readFile(resolve(own,
    isLong ? 'evidence/oracle-extension/long/report.json' : 'evidence/oracle-extension/ci/report.json'), 'utf8'));
  let fixedPrefix = null;
  if (isLong || isCi) {
    const stream = report.streams.find(s => s.name === 'fixtures-0.jsonl');
    const previous = JSON.parse(await readFile(resolve(own,
      isLong ? 'evidence/bridge-long/report.json' : 'evidence/bridge-ci/report.json'), 'utf8'))
      .streams.find(s => s.name === 'fixtures-0.jsonl');
    assert(stream && previous);
    fixedPrefix = historicalFixedPrefix(await readFile(resolve(campaign, stream.name), 'utf8'), previous.sha256);
    assert.equal(fixedPrefix.programs, previous.programs);
    for (const oldStream of baseline.streams.filter(s => !s.name.startsWith('fixtures-'))) {
      const stream = report.streams.find(s => s.name === oldStream.name);
      assert(stream, oldStream.name);
      for (const key of ['programs', 'sha256']) assert.equal(stream[key], oldStream[key], stream.name + ':' + key);
    }
  }
  assert.equal(hash(await readFile(compiler)), report.environment.compilerSha256, 'compiler changed during audit');
  const survivingOriginals = isLong ? Object.fromEntries(Object.entries(clusters).map(([k, ids]) => [k, ids.filter(id => byId.has(id))])) : null;
  const audit = {fixedPrefix, judgeSha256: hash(await readFile(resolve(own, '.lake/build/bin/triage'))),
    observation: 'Original programs; complete final value, reads and externalReads in both unchanged Lean interpreters. The judge labels the supplied original core minimum under --only; no reduction is used.',
    campaign: {programs: report.programs, translated: report.translated, skipped: report.skipped,
    valueChecked: report.valueChecked, leads: report.leads, precision: report.precision,
    environment: report.environment, streams: report.streams},
    confirmed: confirmed.length, confirmedIds: confirmed, agreeingOriginalLeads: judgments.length - confirmed.length,
    // A lead whose in-place run writes no list cannot diverge: the count
    // that matters is of leads that write (the oracle review, F7).
    meaningfulLeads: judgments.filter(r => r.writes > 0).length,
    meaningfulByStream: Object.fromEntries(report.streams.map(s => [s.name, judgments.filter(r => r.writes > 0 &&
      streamOf(r.id) === s.name).length])),
    originalClusterLeadsStillAccepted: survivingOriginals,
    reverse: {before: 401, nowAccepted: reverse.filter(r => r.accepted).length,
      stillRefused: reverse.filter(r => !r.accepted).length, refusalDetailsChanged: reverse.filter(r => r.changed).length}};
  await writeFile(resolve(output, 'judgments.json.gz'), gzipSync(JSON.stringify({audit, judgments, reverse}), {level: 9}));
  await writeFile(resolve(output, 'audit.json'), JSON.stringify(audit, null, 2) + '\n');
  console.log(JSON.stringify(audit, null, 2));
  // A confirmed lead is a shipping defect. One already pinned by a red pending
  // fixture (bridge-known-unsafe.json) is reported; any other fails the audit.
  const known = JSON.parse(await readFile(resolve(own, 'scripts/bridge-known-unsafe.json'), 'utf8'));
  const unknown = confirmed.filter(id => !Object.hasOwn(known, id));
  // A pin names a generated id, valid only while its generator and seed are
  // frozen. A pinned id this campaign judged must still be confirmed: once
  // its defect is fixed (it is no longer a lead) or the stream changes, the
  // pin is stale and must be removed with its fixture's promotion.
  const judgedIds = new Set(judgments.map(r => r.id));
  const exported = id => report.streams.some(s => s.name === streamOf(id) &&
    !(/^(seed|v6)-/.test(id) && Number(id.split('-').at(-1)) >= s.programs));
  const stale = Object.keys(known).filter(id => exported(id) && !(judgedIds.has(id) && confirmed.includes(id)));
  assert.equal(stale.length, 0, `stale known-unsafe pins: ${stale.join(', ')}`);
  if (confirmed.length) console.log(`confirmed unsafe: ${confirmed.join(', ')} (pinned: ${confirmed.filter(id => Object.hasOwn(known, id)).join(', ') || 'none'})`);
  assert.equal(unknown.length, 0, 'interpreter-confirmed unsafe original programs without a pending fixture');
  if (isLong) assert(Object.values(survivingOriginals).every(ids => ids.length === 0), 'an original defect cluster remains accepted');
} finally {
  await rm(work, {recursive: true, force: true});
}
