// Accounting and source snapshots after all timing, never changing a timed bundle.
import fs from 'node:fs';
import {execFileSync,spawnSync} from 'node:child_process';
import {gzipSync,brotliCompressSync,constants} from 'node:zlib';
import {createHash} from 'node:crypto';
const dir='bench/s8/results';
const builds=JSON.parse(fs.readFileSync(`${dir}/app-builds.json`));
for(const row of builds.apps.filter(r=>r.app==='table'&&r.status===0)){
 const get=part=>row.bindings.filter(d=>part==='core'?d.source?.includes('/core/'):part==='runtime'?d.source?.includes('/platforms/'):!d.source?.includes('/core/')&&!d.source?.includes('/platforms/')).map(d=>d.binding).join(' ');
 const map=`${dir}/table-${row.platform}-parts-map.json`;
 fs.writeFileSync(map,JSON.stringify(['core','runtime','app'].map(part=>[part,get(part)]),null,2)+'\n');
 const output=execFileSync('node',['bench/ui/size-parts.mjs',`--file=../../zig-out/s8/table-${row.platform}/_main.mjs`,`--map-file=../s8/results/table-${row.platform}-parts-map.json`],{encoding:'utf8',maxBuffer:1<<24});
 fs.writeFileSync(`${dir}/table-${row.platform}-normalized-parts.txt`,output);
}
// Reprice the timed Todo subjects consistently; preserve the older no-hint file.
const todoTiming=JSON.parse(fs.readFileSync(`${dir}/todo-timing.json`)),todoBytes=[];
for(const [subject,expected]of Object.entries(todoTiming.sources)){
 const source=fs.readFileSync(`bench/todomvc/out/direct-effects/${subject}/_main.mjs`);
 const sha256=createHash('sha256').update(source).digest('hex');
 if(sha256!==expected)throw Error('Timed Todo source differs: '+subject);
 todoBytes.push({subject,sha256,raw:source.length,brotli:brotliCompressSync(source,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:source.length}}).length});
 fs.writeFileSync(`${dir}/todo-${subject}.mjs.gz`,gzipSync(source,{level:9}));
}
fs.writeFileSync(`${dir}/todo-release-bytes.json`,JSON.stringify({method:'Unmodified timed release JS, brotli 11 with input-size hint; legacy todo-sizes.json used no size hint.',rows:todoBytes},null,2)+'\n');
for(const row of builds.apps.filter(r=>r.status===0)){
 const file=`zig-out/s8/${row.app}-${row.platform}/_direct-plan.json`;
 if(fs.existsSync(file))fs.writeFileSync(`${dir}/${row.app}-${row.platform}-plan.json.gz`,gzipSync(fs.readFileSync(file),{level:9}));
}
const endpoints={holes:10000,width:1024,depth:128,rows:30000,live:10000,derived:100000,helperRows:10000,tree:12};
const sources=[];
for(const [sweep,n] of Object.entries(endpoints)){
 const base=`bench/ui/out/scaling/${sweep}/${n}`;
 if(!fs.existsSync(base))throw Error('Missing endpoint '+base);
 const writes=execFileSync(process.env.BENI,['dump','--stage=writes','--platform=browser-direct',`${base}/src/Main.beni`],{encoding:'utf8',maxBuffer:1<<26});
 fs.writeFileSync(`${dir}/${sweep}-${n}.writes`,writes);
 const mappedOut=`zig-out/s8/endpoints/${sweep}-${n}`;
 execFileSync(process.env.BENI,['build','--release','--source-maps','--no-cache','--platform=browser-direct',`--out=${mappedOut}`,`${base}/src/Main.beni`],{encoding:'utf8',maxBuffer:1<<26});
 const mappedSource=fs.readFileSync(`${mappedOut}/_main.mjs`,'utf8').replace(/\/\/# sourceMappingURL=.*\n$/,'');
 if(mappedSource!==fs.readFileSync(`${base}/beni-direct-rel/_main.mjs`,'utf8'))throw Error('Endpoint map build differs: '+sweep);
 fs.writeFileSync(`${dir}/${sweep}-${n}-direct.map.gz`,gzipSync(fs.readFileSync(`${mappedOut}/_main.mjs.map`),{level:9}));


 for(const f of ['src/Main.beni','beni-direct-rel/_main.mjs','beni-rel/_main.mjs','vanilla.js','p3.js'])if(fs.existsSync(`${base}/${f}`)){
  const name=`${sweep}-${n}-${f.replaceAll('/','-')}.gz`;
  fs.writeFileSync(`${dir}/${name}`,gzipSync(fs.readFileSync(`${base}/${f}`),{level:9}));sources.push({sweep,n,file:f,archive:name});
 }
}
fs.writeFileSync(`${dir}/endpoint-sources.json`,JSON.stringify(sources,null,2)+'\n');
// Release Debug rejection is a separate finding from direct's lowering support.
const probes=[];
for(const platform of ['tea','direct'])for(const mode of ['development','test-only-release']){
 const args=['build',`--platform=browser-${platform}`,'--no-cache',`--out=zig-out/s8/bike-${platform}-${mode}`,...(mode==='test-only-release'?['--release','--allow-debug']:[]),'examples/bike-wars/src'];
 const r=spawnSync(process.env.BENI,args,{encoding:'utf8'});probes.push({platform,mode,args,status:r.status,stdout:r.stdout,stderr:r.stderr});
}
fs.writeFileSync(`${dir}/bike-probes.json`,JSON.stringify(probes,null,2)+'\n');
