// Bounded parallel dumps of independent source modules through the real compiler.
import fs from 'node:fs';
import {execFile} from 'node:child_process';
import {promisify} from 'node:util';
import {createHash} from 'node:crypto';
const run=promisify(execFile),here=import.meta.dirname,[root,count]=process.argv.slice(2),n=Number(count),cacheRoot=here+'/.out/bir-cache';
if(!root||!Number.isInteger(n)||n<1)throw Error('dump-bir.mjs app-root component-count');
fs.mkdirSync(cacheRoot,{recursive:true});let next=0;
const settled=await Promise.allSettled(Array.from({length:Math.min(4,n)},async()=>{
 while(next<n){const i=next++,file=root+`/Shape${i}.beni`,key=createHash('sha256').update(fs.readFileSync(file)).digest('hex'),cache=cacheRoot+'/'+key;
  if(!fs.existsSync(cache)){const {stdout}=await run(process.env.BENI||'zig-out/bin/beni',['dump','--stage=bir',file],{maxBuffer:16*1024*1024,encoding:'buffer'});const temp=cache+'.'+process.pid+'.'+i;fs.writeFileSync(temp,stdout);fs.renameSync(temp,cache)}
  // Dumps are immutable and the cache is compiler-pinned. Reuse their inode
  // instead of rewriting every prefix module at each larger component count.
  const dest=root+`/Shape${i}.bir`;
  if(!fs.existsSync(dest)){
   try{fs.linkSync(cache,dest)}catch(e){if(e.code!=='EXDEV')throw e;fs.copyFileSync(cache,dest)}
  }else if(!fs.readFileSync(dest).equals(fs.readFileSync(cache)))throw Error('Stale per-app BIR '+dest);
 }
}));
for(const r of settled)if(r.status==='rejected')throw r.reason;
