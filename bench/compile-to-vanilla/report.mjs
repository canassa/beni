import {readFileSync,writeFileSync,existsSync} from 'node:fs';
const here=new URL('.',import.meta.url),read=name=>JSON.parse(readFileSync(new URL('results/'+name+'.json',here)));
const sizes=read('sizes'),timing=read('timing'),edits=read('edits');
export const quantile=(xs,p)=>{const a=xs.toSorted((a,b)=>a-b),i=(a.length-1)*p;return a[Math.floor(i)]+(a[Math.ceil(i)]-a[Math.floor(i)])*(i%1)};
const fmt=a=>`${quantile(a,.5).toFixed(3)} [${quantile(a,.25).toFixed(3)}–${quantile(a,.75).toFixed(3)}]`;
let md='# Generated measurements\n\nAll sizes are bytes, timings milliseconds. Interquartile ranges use linear interpolation.\n\n';
for(const shape of ['repeated','varied']){
 md+=`## ${shape} feature growth\n\n| Family | Mode | N=1 | N=4 | N=16 | N=64 | Intercept | B/feature | R² |\n|---|---|---:|---:|---:|---:|---:|---:|---:|\n`;
 for(const f of sizes.fits.filter(x=>x.shape===shape)){const points=sizes.observations.filter(p=>p.family===f.family&&p.shape===shape&&p.mode===f.mode);md+=`| ${f.family} | ${f.mode} | ${points.map(p=>p.brotli).join(' | ')} | ${f.intercept.toFixed(1)} | ${f.slope.toFixed(2)} | ${f.r2.toFixed(3)} |\n`}
 md+='\n';
}
md+='## Event batches\n\n| Family | Shape | N | Mode | Operation | Events/batch | Median [Q1–Q3], ms |\n|---|---|---:|---|---|---:|---:|\n';
const keys=[...new Set(timing.samples.map(s=>s.name+'/'+s.operation))].sort();
for(const key of keys){const a=timing.samples.filter(s=>s.name+'/'+s.operation===key),p=a[0];md+=`| ${p.family} | ${p.shape} | ${p.count} | ${p.mode} | ${p.operation} | ${p.batch} | ${fmt(a.map(x=>x.ms))} |\n`}
md+='\n## Owned-array edits\n\n| Rows | Mode | Brotli | Edit | Swap | Select | Append/remove |\n|---:|---|---:|---:|---:|---:|---:|\n';
for(const v of edits.variants){const a=edits.samples.filter(s=>s.name===v.name);md+=`| ${v.count} | ${v.mode} | ${v.brotli} | ${['edit','swap','select','appendRemove'].map(k=>fmt(a.map(x=>x.ms[k]))).join(' | ')} |\n`}
if(existsSync(new URL('results/table.json',here))){
 const r=read('table');md+='\n## Table, real clicks and traces\n\n| Operation | Subject | Script ms | Total ms |\n|---|---|---:|---:|\n';
 for(const op of [...new Set(r.samples.map(x=>x.operation))])for(const subject of ['vanillajs','candidate','solid2']){const a=r.samples.filter(x=>x.operation===op&&x.subject===subject);md+=`| ${op} | ${subject} | ${fmt(a.map(x=>x.script))} | ${fmt(a.map(x=>x.total))} |\n`}
}
if(existsSync(new URL('results/static.json',here))){
 const r=read('static');md+='\n## Static-heavy page\n\nMedian of each fresh page’s ten batch samples, then quartiles across nine pages. 100 events/batch.\n\n| Subject | Script ms/batch | Forced layout after each event, ms/batch | Mount ms |\n|---|---:|---:|---:|\n';
 for(const subject of ['vanilla','lexical','solid2']){const a=r.samples.filter(x=>x.subject===subject);md+=`| ${subject} | ${fmt(a.map(x=>quantile(x.script,.5)))} | ${fmt(a.map(x=>quantile(x.layout,.5)))} | ${fmt(a.map(x=>x.mount))} |\n`}
}
writeFileSync(new URL('results/tables.md',here),md);console.log('Wrote results/tables.md');
