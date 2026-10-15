// Descriptive paired-round bootstrap; not a statistical equivalence test.
import fs from 'node:fs';
const root='bench/direct-bytes/results',out={method:'10000 paired-round percentile bootstrap replicates of candidate median minus original median; untraced only; deterministic PRNG; does not model timer quantization or establish an equivalence bound',rows:[]};
const median=a=>{const s=a.toSorted((a,b)=>a-b);return s[(s.length-1)/2]};let seed=123456789;
const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return (seed>>>0)/4294967296};
for(const file of ['path-timing','group-timing']){
 const data=JSON.parse(fs.readFileSync(`${root}/${file}.json`));
 for(const row of data.rows){
  const a=row.subjects.find(s=>s.subject==='direct-original').raw.filter(r=>!r.tracing).toSorted((x,y)=>x.sample-y.sample);
  const b=row.subjects.find(s=>s.subject==='browser-direct-release').raw.filter(r=>!r.tracing).toSorted((x,y)=>x.sample-y.sample);
  if(a.length!==15||b.length!==15||a.some((r,i)=>r.sample!==b[i].sample))throw Error('Unpaired rounds');
  const deltas=[];for(let trial=0;trial<10000;trial++){const aa=[],bb=[];for(let i=0;i<a.length;i++){const j=Math.floor(random()*a.length);aa.push(a[j].ms);bb.push(b[j].ms)}deltas.push(median(bb)-median(aa))}deltas.sort((a,b)=>a-b);
  out.rows.push({file,variant:data.variant,operation:row.operation,medianDifferenceMs:median(b.map(r=>r.ms))-median(a.map(r=>r.ms)),percentile95Ms:[deltas[249],deltas[9749]]});
 }
}
fs.writeFileSync(`${root}/intervals.json`,JSON.stringify(out,null,2)+'\n');console.log(JSON.stringify(out,null,2));
