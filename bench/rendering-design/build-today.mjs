import fs from 'node:fs';import {execFileSync} from 'node:child_process';import {createHash} from 'node:crypto';import {brotliCompressSync,gzipSync,constants} from 'node:zlib';
const prefix=process.env.RESULT_PREFIX||'';
const here=import.meta.dirname,beni=process.env.BENI||'zig-out/bin/beni';
const hash=b=>createHash('sha256').update(b).digest('hex');
const measure=s=>{const b=Buffer.from(s);return {raw:b.length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length,gzip:gzipSync(b,{level:9}).length,sha256:hash(b)}};
fs.mkdirSync(here+'/results',{recursive:true});fs.mkdirSync(here+'/.out/bir-cache',{recursive:true});
const manifest={started:new Date().toISOString(),source_commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),compiler:execFileSync(beni,['version'],{encoding:'utf8'}).trim(),compiler_sha256:hash(fs.readFileSync(beni)),node:process.version};
fs.writeFileSync(here+'/results/'+prefix+'today-protocol.json',JSON.stringify(manifest,null,2)+'\n');
const checkpoint=here+'/results/'+prefix+'today.jsonl';
const old=fs.existsSync(checkpoint)?fs.readFileSync(checkpoint,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const cases=JSON.parse(fs.readFileSync(here+(process.env.CASES_FILE||'/.out/cases.json')));
for(const c of cases){
 const root=here+'/.out/apps/'+c.name;
 const inputHash=hash(fs.readdirSync(root).filter(n=>n.endsWith('.beni')).sort().map(n=>n+'\n'+fs.readFileSync(root+'/'+n,'utf8')).join('\n'));
 let platforms=(process.env.PLATFORMS||'tea,direct').split(',');
 // Each native curve stops at its measured target or a recorded resource
 // failure. Remaining prototype points still consume fresh real compiler BIR.
 const stressLog=here+'/results/stress/observations.jsonl';
 if(prefix==='stress-'&&fs.existsSync(stressLog)){
  const target=JSON.parse(fs.readFileSync(here+'/results/stress/protocol.json')).target_brotli_bytes;
  const completed=new Set(fs.readFileSync(stressLog,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse).filter(r=>r.shape===c.shape&&r.rendering.brotli>=target).map(r=>r.mode));
  const stopped=here+'/results/stress/stopped.jsonl';
  if(fs.existsSync(stopped))for(const r of fs.readFileSync(stopped,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse))if(r.family===(c.shape||'mixed'))completed.add(r.mode);
  platforms=platforms.filter(p=>!completed.has(p));
  console.log(c.name,'native platforms still active:',platforms.join(',')||'none; BIR only');
 }
 for(const platform of platforms){
  const out=here+'/.out/today/'+c.name+'/'+platform,key=c.name+'/'+platform;
  const prev=old.find(p=>p.key===key&&p.input_sha256===inputHash&&p.compiler_sha256===manifest.compiler_sha256);
  if(prev&&fs.existsSync(out+'/_main.mjs'))continue;
  const begin=performance.now();
  const compileArgs=['build',`--platform=browser-${platform}`,'--release','--source-maps','--jobs=4',`--out=${out}`,root];
  const executable=process.env.BENI_MEMORY_BYTES?'prlimit':beni,args=process.env.BENI_MEMORY_BYTES?['--as='+process.env.BENI_MEMORY_BYTES,'--',beni,...compileArgs]:compileArgs;
  try{execFileSync(process.env.RESEARCH_LOCK?'flock':executable,process.env.RESEARCH_LOCK?[c.n<=512?'--shared':'--exclusive',process.env.RESEARCH_LOCK,executable,...args]:args,{stdio:['ignore','pipe','pipe'],maxBuffer:16*1024*1024});}
  catch(e){fs.writeFileSync(here+'/results/failure-'+c.name+'-'+platform+'.txt',e.stderr||String(e));
   if(prefix==='stress-'&&(platform==='direct'||e.signal==='SIGKILL'||String(e.stderr).includes('OutOfMemory'))){
    fs.appendFileSync(here+'/results/stress/stopped.jsonl',JSON.stringify({family:c.shape||'mixed',mode:platform,name:c.name,n:c.n,status:e.status,signal:e.signal,reason:String(e.stderr||e.message),input_sha256:inputHash,compiler_sha256:manifest.compiler_sha256,address_space_limit_bytes:Number(process.env.BENI_MEMORY_BYTES||0)||null,date:new Date().toISOString()})+'\n');console.log(c.name,platform,'build failed; preserving failure and measuring other curves');continue;
   }throw e;
  }
  const js=fs.readFileSync(out+'/_main.mjs','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,'');
  const row={key,name:c.name,n:c.n,seed:c.seed,shape:c.shape,platform,input_sha256:inputHash,compiler_sha256:manifest.compiler_sha256,build_ms:performance.now()-begin,...measure(js)};
  fs.appendFileSync(checkpoint,JSON.stringify(row)+'\n');console.log(key,row.brotli+' B',Math.round(row.build_ms)+' ms');
 }
 for(let i=0;i<c.n;i++){
  const file=root+`/Shape${i}.beni`,key=hash(fs.readFileSync(file)),cache=here+'/.out/bir-cache/'+key;
  if(!fs.existsSync(cache))fs.writeFileSync(cache,execFileSync(beni,['dump','--stage=bir',file],{maxBuffer:16*1024*1024}));
  fs.copyFileSync(cache,root+`/Shape${i}.bir`);
 }
}
fs.writeFileSync(here+'/results/'+prefix+'today-complete.json',JSON.stringify({completed:new Date().toISOString(),cases:cases.length})+'\n');
