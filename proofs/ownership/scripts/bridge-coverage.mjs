#!/usr/bin/env node
// Verify completed accounting and replay eligibility from the exact input
// streams. This also recovers per-stream coverage for reports predating those
// counters; completed disjoint batches establish the inferred value coverage.
import { readFile, writeFile } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createInterface } from 'node:readline';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';
import assert from 'node:assert/strict';
import { translate, Skip } from './bridge-translate.mjs';
const [directory,output]=process.argv.slice(2);
if(!directory || !output || process.argv.length!==4) throw Error('usage: bridge-coverage.mjs <raw-campaign-dir> <output.json>');
const report=JSON.parse(await readFile(resolve(directory,'report.json'),'utf8'));
assert.equal(report.valueChecked,report.translated);
assert.equal(report.agreements+report.precision+report.leads,report.translated);
assert.equal(report.cases.filter(c=>c.programLead).length,report.leads);
assert.equal(report.cases.reduce((n,c)=>n+c.siteLeads.length,0),report.sites.lead);
const streams=[], families={};
for(const s of report.streams) {
  const tables=new Map(),hash=createHash('sha256'),stream=createReadStream(resolve(directory,s.name));
  stream.on('data',chunk=>hash.update(chunk));
  const row={name:s.name,programs:0,translated:0,skipped:0,leanAccepted:0,leanRejected:0};
  for await(const line of createInterface({input:stream,crlfDelay:Infinity})) {
    const r=JSON.parse(line);
    if(r[0]==='table'){tables.set(r[1],r[2]);continue;}
    assert(r[0]==='program' && r.length===14,'obsolete stream'); row.programs++;
    try {
      if(r[12][0]==='invalid' || r[13] || JSON.stringify(r[12]).includes('"fn"') || r[11]===null) throw new Skip('observation');
      translate(tables.get(r[3]),r[4]);row.translated++;
      const key=r[5]?'leanAccepted':'leanRejected';row[key]++;
      families[r[1]]??={leanAccepted:0,leanRejected:0};families[r[1]][key]++;
    } catch(e){if(!(e instanceof Skip))throw e;row.skipped++;}
  }
  assert.equal(hash.digest('hex'),s.sha256);assert.equal(row.programs,s.programs);streams.push(row);
}
assert.equal(streams.reduce((n,s)=>n+s.programs,0),report.programs);
assert.equal(streams.reduce((n,s)=>n+s.translated,0),report.translated);
const leanAccepted=streams.reduce((n,s)=>n+s.leanAccepted,0);
const verdicts={bothAccept:leanAccepted-report.precision,leanAcceptZigRefuse:report.precision,leanRefuseZigAccept:report.leads,bothRefuse:report.translated-leanAccepted-report.leads};
assert.equal(verdicts.bothAccept+verdicts.bothRefuse,report.agreements);
for(const [family,counts] of Object.entries(families)) {
  const f=report.families[family];
  counts.bothAccept=counts.leanAccepted-(f.precision??0);
  counts.bothRefuse=counts.leanRejected-(f.leads??0);
  assert(counts.bothAccept>=0 && counts.bothRefuse>=0);
  assert.equal(counts.bothAccept+counts.bothRefuse,f.agreements??0);
}
await writeFile(output,JSON.stringify({derivation:'Eligibility replayed from SHA-256-verified input streams. Complete disjoint-batch value/verdict accounting establishes a value check for every translated program; per-stream value coverage is inferred where the original report lacks counters.',streams,verdicts,families},null,2)+'\n');
console.log(JSON.stringify({streams,verdicts}));
