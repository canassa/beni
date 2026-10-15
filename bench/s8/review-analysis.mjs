// Recompute review diagnostics from retained evidence; never launch a browser.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const root='bench/s8/results',read=p=>JSON.parse(fs.readFileSync(root+'/'+p));
const sha=p=>createHash('sha256').update(fs.readFileSync(p)).digest('hex');
const q=(xs,p)=>{const a=xs.toSorted((a,b)=>a-b),x=(a.length-1)*p,i=Math.floor(x);return a[i]+(a[Math.min(i+1,a.length-1)]-a[i])*(x-i)};
const stat=xs=>({median:q(xs,.5),q1:q(xs,.25),q3:q(xs,.75),samples:xs.length});
const sw=read('sweeps.json'),stats=read('stats.json'),apps=read('apps-timing.json');
const subjects=['vanillajs','solid1','solid2','beni-release','beni-direct-release','p3'];
const endpoints=[['holes','tick',10000],['rows','change',30000],['rows','swap',30000],['width','field',1024],['depth','leaf',128],['derived','tick',100000],['live','tick',10000],['helperRows','tick',10000],['tree','tick',12]];
const pages=[];
for(const [sweep,op,param]of endpoints)for(const page of [0,1])for(const subject of subjects){
 const xs=sw.samples.filter(x=>x.sweep===sweep&&x.op===op&&x.param===param&&x.page===page&&x.subject===subject).map(x=>x.script);
 if(xs.length)pages.push({sweep,op,param,page,subject,...stat(xs)});
}
const extra=p=>p.startsWith('examples/sternhalma/')||p.startsWith('examples/bike-wars/');
const staticDefault=stats.static.rows.filter(x=>!extra(x.program)),rootsDefault=stats.roots.rows.filter(x=>!extra(x.program));
const series=stats.pairs.series.filter(x=>!extra(x.program)),median=series[Math.floor((series.length-1)/2)];
const appDurationMs=Date.parse(apps.finished)-Date.parse(apps.started);
const result={
 method:'Read-only analysis of existing rows. Page samples stay clustered; order is not balanced across all sweep positions. Default census excludes only the two explicit extra-app projects, not fixtures with inconvenient results.',
 inputs:Object.fromEntries(['sweeps.json','stats.json','apps-timing.json'].map(p=>[p,sha(root+'/'+p)])),
 analysisSourceSha256:sha(new URL(import.meta.url)),
 measurementEvidenceCommit:'95d875e7b',
 census:{defaultPrograms:stats.programs-2,defaultStaticRows:staticDefault.length,defaultStaticOver:staticDefault.filter(x=>x.share>5).length,defaultRootsOver:rootsDefault.filter(x=>x.value>3||x.share>5),defaultPairPrograms:series.length,defaultPairMedian:median,defaultLargestPair:series.at(-1),extraStatic:stats.static.rows.filter(x=>extra(x.program)),extraRoots:stats.roots.rows.filter(x=>extra(x.program))},
 apps:{started:apps.started,finished:apps.finished,pages:apps.rows.length,wallMs:appDurationMs,wallMsPerPage:appDurationMs/apps.rows.length,sternhalma:apps.rows.filter(x=>x.app==='sternhalma').reduce((o,x)=>{const key=x.operation+'/'+x.subject;(o[key]??=[]).push(x.ms);return o},{})},
 endpoints:pages,
};
for(const xs of Object.values(result.apps.sternhalma))xs.sort((a,b)=>a-b);
fs.writeFileSync(root+'/review-analysis.json',JSON.stringify(result,null,2)+'\n');
let md='Per-page medians, ms; twelve clicks per page. No new observations.\n';
for(const page of [0,1]){
 md+='\n### Page '+page+'\n\n| Endpoint | Vanilla | Solid 1 | Solid 2 | Tea | Direct | P3 |\n|---|--:|--:|--:|--:|--:|--:|\n';
 for(const [sweep,op,param]of endpoints)md+='| '+[sweep+'/'+op+'/'+param,...subjects.map(subject=>{const s=pages.find(x=>x.sweep===sweep&&x.op===op&&x.param===param&&x.page===page&&x.subject===subject);return s?s.median.toFixed(4):'—'})].join(' | ')+' |\n';
}
fs.writeFileSync(root+'/review-page-medians.md',md);
console.log({census:result.census,appWallMs:appDurationMs});
