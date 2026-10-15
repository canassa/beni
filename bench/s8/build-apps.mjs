// Unchanged applications, clean release builds, source-map based accounting.
import fs from 'node:fs';
import {spawnSync,execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {brotliCompressSync,gzipSync,constants} from 'node:zlib';
const require=createRequire(import.meta.url);
const acorn=require('../ui/apps/solid1/node_modules/acorn');
const {TraceMap,originalPositionFor}=require('../ui/apps/solid1/node_modules/@jridgewell/trace-mapping');
// S8_APPS (comma-separated keys of `apps`, such as `bike`, not directory names) and
// S8_RESULTS (a directory) measure a later build without a change to the batch's own
// results. An empty variable is the same as no variable.
const beni=process.env.BENI??'zig-out/bin/beni',dir=process.env.S8_RESULTS||'bench/s8/results',only=process.env.S8_APPS?process.env.S8_APPS.split(','):undefined;
fs.mkdirSync(dir,{recursive:true});
const size=s=>{const b=Buffer.from(s);return {raw:b.length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}};
const apps={conduit:'examples/conduit/src',todomvc:'tests/corpus/browser/direct/TodoMVC.beni',sternhalma:'examples/sternhalma/src',bike:'examples/bike-wars/src',table:'bench/ui/apps/beni/Main.beni'};
const result={commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),compilerSha256:createHash('sha256').update(fs.readFileSync(beni)).digest('hex'),node:process.version,method:'Unmodified emitted release JS. Ordered initializer stubs: core, runtime; remainder charged to app/startup. No reoptimisation. Compression interactions depend on order. Core leave-one-out is also recorded for criterion 5.',apps:[]};
for(const [app,input] of Object.entries(apps)) if(!only||only.includes(app)) for(const platform of ['tea','direct']){
 const out=`zig-out/s8/${app}-${platform}`;
 const args=['build',`--platform=browser-${platform}`,'--release','--no-cache',`--out=${out}`,input];
 const run=spawnSync(beni,args,{encoding:'utf8'});
 const row={app,platform,input,args,status:run.status,stdout:run.stdout,stderr:run.stderr};result.apps.push(row);
 if(run.status!==0)continue;
 const source=fs.readFileSync(`${out}/_main.mjs`,'utf8');
 const mapped=spawnSync(beni,[...args.slice(0,-1),'--source-maps',`--out=${out}-maps`,input],{encoding:'utf8'});
 if(mapped.status!==0)throw Error(mapped.stderr);
 if(fs.readFileSync(`${out}-maps/_main.mjs`,'utf8').replace(/\/\/# sourceMappingURL=.*\n$/,'')!==source)throw Error('Map build differs');
 const map=new TraceMap(JSON.parse(fs.readFileSync(`${out}-maps/_main.mjs.map`)));
 const ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'});
 const decls=ast.body.flatMap(n=>n.declarations??[]).filter(n=>n.init).map(n=>({n,...originalPositionFor(map,{line:1,column:n.id.start})}));
 const stub=(s,ds)=>{for(const {n} of ds.toSorted((a,b)=>b.n.init.start-a.n.init.start))s=s.slice(0,n.init.start)+'0'+s.slice(n.init.end);acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'});return s};
 const categories={core:decls.filter(d=>d.source?.includes('/core/')),runtime:decls.filter(d=>d.source?.includes('/platforms/'))};
 let selected=[],before=size(source).brotli;
 row.size=size(source);row.sha256=createHash('sha256').update(source).digest('hex');row.parts=[];
 for(const [part,ds] of Object.entries(categories)){
  selected.push(...ds);const next=size(stub(source,selected)).brotli;
  row.parts.push({part,rawSpans:ds.reduce((s,{n})=>s+Buffer.byteLength(source.slice(n.start,n.end)),0),orderedBrotli:before-next,leaveOneOut:row.size.brotli-size(stub(source,ds)).brotli});before=next;
 }
 row.parts.push({part:'app/startup/residual',orderedBrotli:before});
 row.bindings=decls.map(({n,...info})=>({binding:n.id.name,...info,start:n.start,end:n.end}));
 fs.writeFileSync(`${dir}/${app}-${platform}.mjs.gz`,gzipSync(source,{level:9}));
 fs.writeFileSync(`${dir}/${app}-${platform}.map.gz`,gzipSync(fs.readFileSync(`${out}-maps/_main.mjs.map`),{level:9}));
}
fs.writeFileSync(`${dir}/app-builds.json`,JSON.stringify(result,null,2)+'\n');
