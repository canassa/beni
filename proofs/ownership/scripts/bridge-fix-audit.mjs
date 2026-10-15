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
const [campaignArg, compilerArg, outputArg] = process.argv.slice(2);
assert(campaignArg && compilerArg && outputArg && process.argv.length === 5,
  'usage: bridge-fix-audit.mjs campaign-directory compiler output-directory');
const own = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const campaign = resolve(campaignArg), compiler = resolve(compilerArg), output = resolve(outputArg);
const exec = promisify(execFile), hash = x => createHash('sha256').update(x).digest('hex');
const report = JSON.parse(await readFile(resolve(campaign, 'report.json'), 'utf8'));
assert.equal(hash(await readFile(compiler)), report.environment.compilerSha256, 'campaign compiler changed');
await mkdir(output, {recursive: true});
await rm(resolve(output, 'audit.json'), {force: true});
const leads = report.cases.filter(c => c.programLead);
assert.equal(leads.length, report.leads);
const work = await mkdtemp(resolve(campaign, 'audit-'));
try {
  const inputs = [];
  for (const c of leads) {
    const e = JSON.parse(await readFile(resolve(campaign, 'cases', c.id, 'evidence.json'), 'utf8'));
    assert.equal(e.id, c.id);
    assert.equal(e.record[5], false);
    assert.equal(e.record[8], c.lean);
    const dir = resolve(campaign, 'cases', c.id);
    const sources = (await readdir(dir)).filter(n => n.endsWith('.beni') && n !== 'Minimal.beni');
    assert.equal(sources.length, 1);
    assert.equal(await readFile(resolve(dir, sources[0]), 'utf8'),
      translate(e.declarations, e.record[4]).source, 'original source fidelity');
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
  const isLong = report.programs === 116456;
  const survivingOriginals = isLong ? Object.fromEntries(Object.entries(clusters).map(([k, ids]) => [k, ids.filter(id => byId.has(id))])) : null;
  const audit = {campaign: {programs: report.programs, translated: report.translated, skipped: report.skipped,
    valueChecked: report.valueChecked, leads: report.leads, precision: report.precision,
    environment: report.environment, streams: report.streams},
    confirmed: confirmed.length, confirmedIds: confirmed, agreeingOriginalLeads: judgments.length - confirmed.length,
    originalClusterLeadsStillAccepted: survivingOriginals,
    reverse: {before: 401, nowAccepted: reverse.filter(r => r.accepted).length,
      stillRefused: reverse.filter(r => !r.accepted).length, refusalDetailsChanged: reverse.filter(r => r.changed).length}};
  await writeFile(resolve(output, 'judgments.json.gz'), gzipSync(JSON.stringify({audit, judgments, reverse}), {level: 9}));
  await writeFile(resolve(output, 'audit.json'), JSON.stringify(audit, null, 2) + '\n');
  console.log(JSON.stringify(audit, null, 2));
  assert.equal(confirmed.length, 0, 'interpreter-confirmed unsafe original programs remain');
  if (isLong) assert(Object.values(survivingOriginals).every(ids => ids.length === 0), 'an original defect cluster remains accepted');
} finally {
  await rm(work, {recursive: true, force: true});
}
