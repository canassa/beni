import fs from 'node:fs';import {createHash} from 'node:crypto';import {brotliCompressSync,gzipSync,constants} from 'node:zlib';import {minify} from 'terser';
import {units} from './provenance.mjs';import {prototype} from './prototype.mjs';import {vanilla} from './vanilla.mjs';
import {execFileSync} from 'node:child_process';
const here=import.meta.dirname;
export const hash=s=>createHash('sha256').update(s).digest('hex');
export const size=s=>{const b=Buffer.from(s);return {raw:b.length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length,gzip:gzipSync(b,{level:9}).length}};
export function account(code,map,kind){
 const parsed=units(code,map),chunks={core:[],runtime:[],app:[]},origins={},renderParts=[];
 const segments=parsed.segs.length&&parsed.segs[0].offset>0?[{offset:0,source:'unmapped'},...parsed.segs]:parsed.segs;
 let unitIndex=0;
 for(let i=0;i<segments.length;i++){
  const segment=segments[i],start=segment.offset,end=segments[i+1]?.offset??code.length;
  if(end<=start)continue;
  while(unitIndex+1<parsed.units.length&&parsed.units[unitIndex].end<=start)unitIndex++;
  const unit=parsed.units[unitIndex];
  // Name-free gaps inherit their enclosing declaration's provenance. Mapped
  // spans keep their own source even when Terser inlines core into an app unit.
  const owner=segment.source==='unmapped'&&unit?.start<=start&&unit.end>=end?unit.owner:segment.source;
  const group=kind==='today'?(owner.startsWith('core/')?'core':owner.startsWith('platforms/')?'runtime':'app'):(owner.includes('render-runtime.js')?'runtime':'app');
  const text=code.slice(start,end);chunks[group].push(text);if(group!=='core')renderParts.push(text);
  origins[owner]=(origins[owner]||0)+Buffer.byteLength(text);
 }
 const runtime=chunks.runtime.join(''),app=chunks.app.join(''),render=renderParts.join('');
 // Compress each identical byte string once within this account. This matters
 // when core is empty and full/rendering are identical; prices do not change.
 const core=chunks.core.join(''),inputs=[...new Set([code,render,runtime,app,core])],prices=new Map();
 // Never wait for an extra slot while holding a worker reservation: if the
 // pool is full, retain serial compression. This avoids nested-pool deadlock.
 if(process.env.RESEARCH_LOCK&&inputs.filter(s=>s.length>=1048576).length>=2){
  try{const result=JSON.parse(execFileSync(process.execPath,[here+'/resource-run.mjs','--try=1','--memory-mib=1024','--cpu=1','--',process.execPath,here+'/compression-batch.mjs'],{input:JSON.stringify(inputs),encoding:'utf8',maxBuffer:1024*1024}));
   if(result.length!==inputs.length)throw Error('Incomplete compression batch');
   inputs.forEach((text,index)=>prices.set(text,result[index]));
  }catch(e){if(e.status!==75)throw e}
 }
 const price=text=>{if(!prices.has(text))prices.set(text,size(text));return prices.get(text)};
 return {full:price(code),rendering:price(render),runtime:price(runtime),app_alone:price(app),app_in_rendering_context:price(render).brotli-price(runtime).brotli,excluded_core:price(core),origins,rendering_sha256:hash(render),render};
}
if(process.argv[1]===import.meta.filename){
const cases=JSON.parse(fs.readFileSync(here+(process.env.CASES_FILE||'/.out/cases.json')));
const resultFile=here+'/results/'+(process.env.RESULT_PREFIX||'')+'sizes.json';
const modes=process.env.MODES?.split(',')||['tea','direct','vanilla','partial','static','cells','local'];
const rows=process.env.MODES&&fs.existsSync(resultFile)?JSON.parse(fs.readFileSync(resultFile)).observations.filter(r=>!modes.includes(r.mode)):[];fs.mkdirSync(here+'/results',{recursive:true});
for(const c of cases){
 const appRoot=here+'/.out/apps/'+c.name,spec=JSON.parse(fs.readFileSync(appRoot+'/spec.json'));
 for(const mode of modes){
  let output,rawRelease=null,kind,analysis=null;
  const dest=here+'/.out/measured/'+c.name;fs.mkdirSync(dest,{recursive:true});
  if(mode==='tea'||mode==='direct'){
   const root=here+'/.out/today/'+c.name+'/'+mode,source=fs.readFileSync(root+'/_main.mjs','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,''),map=JSON.parse(fs.readFileSync(root+'/_main.mjs.map'));
   rawRelease=account(source,map,'today');delete rawRelease.render;
   output=await minify({'bundle.js':source},{module:true,compress:{passes:2},mangle:true,format:{comments:false},sourceMap:{content:map,asObject:true}});kind='today';
  }else{
   let chunks;
   if(mode==='vanilla'){const [support,app]=vanilla(spec).split('// APP-BEGIN');chunks={'render-runtime.js':support,'App.js':app};}
   else{const result=prototype(appRoot,mode);chunks=result.chunks;analysis=result.witnesses;}
   output=await minify(chunks,{module:true,compress:{passes:2},mangle:true,format:{comments:false},sourceMap:{asObject:true,includeSources:true}});kind='prototype';
  }
  fs.writeFileSync(dest+'/'+mode+'.js',output.code);fs.writeFileSync(dest+'/'+mode+'.map',JSON.stringify(output.map));
  if(analysis)fs.writeFileSync(dest+'/'+mode+'-analysis.json',JSON.stringify(analysis,null,2));
  const priced=account(output.code,output.map,kind);fs.writeFileSync(dest+'/'+mode+'-rendering.js',priced.render);delete priced.render;
  const row={name:c.name,n:c.n,seed:c.seed,shape:c.shape,mode,sha256:hash(output.code),...priced,compiler_release:rawRelease};rows.push(row);
  fs.writeFileSync(resultFile,JSON.stringify({protocol:'Whole-response brotli 11, gzip 9. All candidates normalized with Terser 5.51.2 (module, two passes, identifier mangling). Rendering extraction deletes source-map spans owned by core, including inlined spans; unmapped gaps inherit their containing declaration. Extracts are byte attribution artifacts, not executable bundles. Full bundles are executed for validation. Runtime standalone; app incremental in rendering context, not additive independent prices. Compiler release figures also retained.',observations:rows},null,2)+'\n');
  console.log(c.name,mode,priced.rendering.brotli,'rendering B');
 }
}

}
