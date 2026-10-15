// Validation is serial and outside all comparison timing.
import fs from 'node:fs';
import {spawnSync} from 'node:child_process';
const dir='bench/s8/results',rows=[];
for(const step of ['gates','test-browser']){
 const file=`${dir}/${step==='gates'?'gates':'chrome-tests'}.log`,fd=fs.openSync(file,'w');
 const started=new Date().toISOString();
 const result=spawnSync('zorg',['build',step],{stdio:['ignore',fd,fd]});fs.closeSync(fd);
 rows.push({command:['zorg','build',step],started,finished:new Date().toISOString(),status:result.status,signal:result.signal,error:result.error?.message??null,log:file});
 fs.writeFileSync(`${dir}/validation.json`,JSON.stringify(rows,null,2)+'\n');
 if(result.status!==0)process.exit(result.status??1);
}
