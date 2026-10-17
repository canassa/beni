// Retry a capped TEA curve with a larger, isolated compiler address-space
// budget. All prices still come from the ordinary stress worker.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {application,shapes} from './catalogue.mjs';
import {writeApp} from './generate.mjs';
const here=import.meta.dirname,[family,nText,capText='24',mode='tea']=process.argv.slice(2),cap=Number(capText)*2**30,target=512000;
let n=Number(nText);
if(!shapes.includes(family)||!Number.isInteger(n)||n<1||!['24','64'].includes(capText)||!['tea','direct'].includes(mode))throw Error('memory-probe.mjs family N 24|64 [tea|direct]');
const beni=path.resolve(process.env.BENI||'zig-out/bin/beni'),hash=x=>createHash('sha256').update(x).digest('hex'),compiler=hash(fs.readFileSync(beni));
const protocol=JSON.parse(fs.readFileSync(here+'/results/stress/protocol.json'));
if(compiler!==protocol.compiler_sha256)throw Error('Compiler identity changed');
for(const [file,expected] of Object.entries(protocol.source_hashes))if(hash(fs.readFileSync(here+'/'+file))!==expected)throw Error('Measurement source changed: '+file);
const rows=file=>fs.existsSync(file)?fs.readFileSync(file,'utf8').trim().split('\n').filter(Boolean).map(JSON.parse):[];
const append=(file,row)=>fs.appendFileSync(file,JSON.stringify(row)+'\n');
const log=here+'/results/stress/observations.jsonl',nativeLog=here+'/results/stress-today.jsonl',attemptLog=here+'/results/stress/memory-probes.jsonl';
const env={...process.env,RESEARCH_LOCK:process.env.RESEARCH_LOCK||'/tmp/beni-rendering-design-172.lock'};
function run(memory,cpu,command,args,extra={}){
 return execFileSync(process.execPath,[here+'/resource-run.mjs','--memory-mib='+memory,'--cpu='+cpu,'--',command,...args],{env:{...env,...extra},encoding:'utf8',maxBuffer:16*1024*1024});
}
function inputHash(root){const digest=createHash('sha256'),files=fs.readdirSync(root).filter(f=>f.endsWith('.beni')).sort();for(const [i,file] of files.entries()){if(i)digest.update('\n');digest.update(file+'\n');digest.update(fs.readFileSync(root+'/'+file))}return digest.digest('hex')}
for(;;){
 const measured=rows(log).filter(r=>r.shape===family&&r.mode===mode);
 if(measured.some(r=>r.rendering.brotli>=target)){console.log(family,mode,'already crossed');break}
 const name=`stress-${family}-17-${n}`,root=here+'/.out/apps/'+name,out=here+`/.out/memory-probes/${family}-${n}-${mode}${capText==='64'?'-as64-ram26000':''}`;
 const generated=application(n,17,family);
 if(!fs.existsSync(root))writeApp(generated,name);
 const expected=[['Main.beni',generated.source],...generated.parts.map(p=>['Shape'+p.index+'.beni',p.source])];
 if(fs.readdirSync(root).filter(f=>f.endsWith('.beni')).length!==expected.length||expected.some(([f,s])=>fs.readFileSync(root+'/'+f,'utf8')!==s))throw Error('Source differs from the unchanged catalogue');
 const input=inputHash(root);fs.mkdirSync(out,{recursive:true});
 const marker=out+'/build.json';let build=fs.existsSync(marker)?JSON.parse(fs.readFileSync(marker)):null;
 if(build&&(build.input_sha256!==input||build.compiler_sha256!==compiler||build.address_space_limit_bytes!==cap))throw Error('Probe checkpoint identity changed');
 if(!build){
  build={name,family,n,seed:17,mode,input_sha256:input,compiler_sha256:compiler,address_space_limit_bytes:cap,physical_memory_limit_bytes:capText==='64'?26000*2**20:null,started:new Date().toISOString(),exclusive_reservation:{memory_mib:26000,cpu:6}};
  console.log('PROBE',family,mode,n,capText+' GiB address space, exclusive compiler admission'+(capText==='64'?', 26000 MiB cgroup RAM limit':''));
  const compile=['prlimit','--as='+cap,'--',beni,'build','--platform=browser-'+mode,'--release','--source-maps','--jobs=4','--out='+out,root];
  const unit='beni-rendering-'+family+'-'+mode+'-'+n+'-as'+capText;
  const command=capText==='64'?['systemd-run','--user','--wait','--pipe','--unit='+unit,'--working-directory='+process.cwd(),'-p','MemoryMax='+build.physical_memory_limit_bytes,'-p','MemorySwapMax=0','-p','LimitSTACK=33554432','/run/current-system/sw/bin/time','-v','-o',out+'/resource.txt',...compile]:compile;
  try{run(26000,6,'flock',['--exclusive',env.RESEARCH_LOCK+'.compiler',...command]);build.status=0}
  catch(e){build.status=e.status;build.signal=e.signal;build.reason=String(e.stderr||e.message);if(!/out\s*of\s*memory|oom-kill/i.test(build.reason)&&e.status!==137)throw e}
  build.finished=new Date().toISOString();
  if(capText==='64'){
   build.resource_log=fs.existsSync(out+'/resource.txt')?fs.readFileSync(out+'/resource.txt','utf8'):null;
   build.peak_rss_kib=Number(build.resource_log?.match(/Maximum resident set size \(kbytes\): (\d+)/)?.[1])||null;
   try{execFileSync('systemctl',['--user','reset-failed',unit],{stdio:'ignore'})}catch{}
  }
  if(build.status===0){const code=fs.readFileSync(out+'/_main.mjs','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,'');build.native_sha256=hash(code);build.native_raw=Buffer.byteLength(code)}
  fs.writeFileSync(marker,JSON.stringify(build,null,2)+'\n');append(attemptLog,build);
 }
 if(build.status!==0){
  const stop={...build,date:build.finished,reason:build.reason,memory_probe:true};
  const file=here+'/results/stress/stopped.jsonl';if(!rows(file).some(r=>r.name===name&&r.mode===mode&&r.address_space_limit_bytes===cap))append(file,stop);
  console.log(family,mode,n,'failed at '+capText+' GiB; preserving the endpoint');break;
 }
 const nativeCode=fs.readFileSync(out+'/_main.mjs','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,'');
 if(hash(nativeCode)!==build.native_sha256||Buffer.byteLength(nativeCode)!==build.native_raw)throw Error('Probe compiler artifact changed');
 const dest=out+'/normalized',pricedFile=dest+'/'+mode+'-size.json';
 if(!fs.existsSync(pricedFile))run(Math.ceil(Math.min(14500,1024+n*1.5)),1,process.execPath,['--stack-size=16384','--max-old-space-size='+(n>4096?12288:6144),here+'/stress-worker.mjs',name,mode],{NATIVE_OUTPUT:out,MEASURE_OUTPUT:dest});
 const price=JSON.parse(fs.readFileSync(pricedFile));
 if(price.name!==name||price.mode!==mode||price.source_sha256!==input||price.sha256!==hash(fs.readFileSync(dest+'/'+mode+'.js'))||price.compiler_release.full.raw!==build.native_raw)throw Error('Probe price identity changed');
 const row={...price,compiler_sha256:compiler,compiler_address_space_limit_bytes:cap,compiler_physical_memory_limit_bytes:build.physical_memory_limit_bytes||null,memory_probe:true};
 const prior=rows(log).find(r=>r.name===name&&r.mode===mode);if(prior&&prior.sha256!==row.sha256)throw Error('Conflicting existing price');
 const native={key:name+'/'+mode,name,n,seed:17,shape:family,platform:mode,input_sha256:input,compiler_sha256:compiler,...price.compiler_release.full,sha256:build.native_sha256,address_space_limit_bytes:cap,physical_memory_limit_bytes:build.physical_memory_limit_bytes||null,memory_probe:true};
 const priorNative=rows(nativeLog).find(r=>r.key===native.key);if(priorNative&&priorNative.sha256!==native.sha256)throw Error('Conflicting native output');
 const standardNative=here+'/.out/today/'+name+'/'+mode,standardPrice=here+'/.out/measured/'+name;
 fs.mkdirSync(standardNative,{recursive:true});fs.mkdirSync(standardPrice,{recursive:true});
 for(const f of ['_main.mjs','_main.mjs.map'])fs.copyFileSync(out+'/'+f,standardNative+'/'+f);
 for(const f of [mode+'.js',mode+'.map'])fs.copyFileSync(dest+'/'+f,standardPrice+'/'+f);
 fs.writeFileSync(standardPrice+'/'+mode+'-size.json',JSON.stringify(row)+'\n');
 if(!priorNative)append(nativeLog,native);if(!prior)append(log,row);
 console.log('PROBE PRICED',family,mode,n,row.rendering.brotli,'brotli bytes');
 if(row.rendering.brotli>=target)break;
 const before=measured.filter(r=>r.n<n).sort((a,b)=>a.n-b.n).at(-1),slope=before?(row.rendering.brotli-before.rendering.brotli)/(n-before.n):0;
 n=Math.ceil(Math.max(n+16,Math.min(n*1.5,slope>0?n+(target*1.01-row.rendering.brotli)/slope:n*1.25))/16)*16;
}
