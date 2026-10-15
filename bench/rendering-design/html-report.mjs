// Standalone, offline report. Re-run as checkpoints arrive; no network/CDN.
import fs from 'node:fs';
const here=import.meta.dirname,read=f=>JSON.parse(fs.readFileSync(here+'/'+f));
const original=[...read('results/sizes.json').observations,...read('results/solid-sizes.json').observations];
const stressFile=here+'/results/stress/observations.jsonl',stress=fs.existsSync(stressFile)?fs.readFileSync(stressFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const compact=r=>({name:r.name,n:r.n,seed:r.seed,family:r.shape||'mixed',mode:r.mode,raw:r.rendering.raw,brotli:r.rendering.brotli,gzip:r.rendering.gzip,runtime:r.runtime.brotli,full_brotli:r.full.brotli,app_increment:r.app_in_rendering_context,sha256:r.sha256,compiler_release_brotli:r.compiler_release?.rendering.brotli??null,source_bytes:r.source_bytes??null});
const stopFile=here+'/results/stress/stopped.jsonl',stopped=fs.existsSync(stopFile)?fs.readFileSync(stopFile,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const data={stopped,generated:new Date().toISOString(),target:512000,unit:'kB = 1,000 bytes',rows:[...original,...stress].map(compact),protocol:fs.existsSync(here+'/results/stress/protocol.json')?read('results/stress/protocol.json'):null};
const html=fs.readFileSync(here+'/report-template.html','utf8').replace('/*REPORT_DATA*/',JSON.stringify(data).replaceAll('<','\\u003c'));
fs.writeFileSync(here+'/report.html',html);
fs.writeFileSync(here+'/results/stress-report-data.json',JSON.stringify(data,null,2)+'\n');
console.log('HTML report:',data.rows.length,'measured bundles; maximum N',Math.max(...data.rows.map(r=>r.n)));
