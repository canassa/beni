import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
const here=import.meta.dirname,beni=process.env.BENI||'zig-out/bin/beni';
const cases=JSON.parse(fs.readFileSync(here+'/out/cases.json'));
for(const c of cases){
 for(const platform of ['tea','direct']){
  try{execFileSync(beni,['build',`--platform=browser-${platform}`,'--release','--source-maps',`--out=${here}/out/smoke/${c.name}/${platform}`,c.path],{stdio:['ignore','pipe','pipe']});console.log(c.name,platform,'built');}
  catch(e){fs.writeFileSync(here+`/out/smoke-${c.name}-${platform}.log`,e.stderr);console.log(c.name,platform,'FAILED');process.exitCode=1;}
 }
 for(let i=0;i<c.n;i++)fs.writeFileSync(c.path+`/Shape${i}.bir`,execFileSync(beni,['dump','--stage=bir',c.path+`/Shape${i}.beni`]));
}
