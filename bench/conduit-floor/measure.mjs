// Reprice frozen archives with --archive, or build beni and archive local references.
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync as exec} from 'node:child_process';
import {createHash} from 'node:crypto';
import {createRequire} from 'node:module';
import {brotliCompressSync,gzipSync,gunzipSync,constants} from 'node:zlib';
const require=createRequire(import.meta.url);
const acorn=require('../ui/apps/solid1/node_modules/acorn');
const {TraceMap,eachMapping}=require('../ui/apps/solid1/node_modules/@jridgewell/trace-mapping');
const out='bench/conduit-floor/results',work='zig-out/conduit-floor';
export const size=s=>{const b=Buffer.from(s);return {raw:b.length,gzip:gzipSync(b,{level:9}).length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}};
const hash=s=>createHash('sha256').update(s).digest('hex');
const archive=process.argv.includes('--archive');
fs.mkdirSync(out,{recursive:true});
const walk=(n,fn)=>{if(!n?.type)return;fn(n);for(const v of Object.values(n))if(Array.isArray(v))v.forEach(x=>walk(x,fn));else if(v?.type)walk(v,fn)};
const category=s=>/node_modules\/(marked|markdown)\//.test(s)?'markdown':/node_modules\/|webpack\/bootstrap|\b(core|platforms)\//.test(s)?'runtime':'app';
const apply=(s,edits)=>{let end=s.length;for(const e of [...edits].sort((a,b)=>b.start-a.start)){if(e.end>end)throw Error('Overlap');s=s.slice(0,e.start)+e.text+s.slice(e.end);end=e.start}acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'});return s};
let manifest;
if(archive)manifest=JSON.parse(fs.readFileSync(`${out}/manifest.json`));
else{
 for(const file of fs.readdirSync(out))if(/^(solid-|vanilla-|beni-).*\.gz$/.test(file))fs.unlinkSync(`${out}/${file}`);
 const beni=process.env.BENI??'zig-out/safe/bin/beni';
 manifest={date:new Date().toISOString(),commit:exec('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),node:process.version,compilerSha256:hash(fs.readFileSync(beni)),references:JSON.parse(fs.readFileSync('bench/conduit-floor/references.json')),subjects:{}};
 for(const p of ['tea','direct']){
  for(const maps of [false,true])exec(beni,['build',`--platform=browser-${p}`,'--release','--no-cache',...(maps?['--source-maps']:[]),`--out=${work}/beni-${p}${maps?'-mapped':''}`,'examples/conduit/src'],{stdio:'pipe'});
 }
 const subjects=['solid-stock','solid-paragraphs','solid-paragraphs-single','vanilla-stock','vanilla-paragraphs','beni-tea','beni-direct'];
 for(const subject of subjects){
  const dir=`${work}/${subject}`,mapped=/solid-|beni-/.test(subject)?dir+'-mapped':dir;
  const files=fs.readdirSync(dir).filter(f=>/\.(m?js)$/.test(f)).sort();
  manifest.subjects[subject]=files;
  for(const file of files){
   const source=fs.readFileSync(`${dir}/${file}`,'utf8'),map=fs.readFileSync(`${mapped}/${file}.map`,'utf8');
   if(mapped!==dir){const m=fs.readFileSync(`${mapped}/${file}`,'utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,'');if(m!==source)throw Error(`Mapped code differs: ${subject}/${file}`)}
   fs.writeFileSync(`${out}/${subject}--${file}.gz`,gzipSync(source,{level:9}));
   fs.writeFileSync(`${out}/${subject}--${file}.map.gz`,gzipSync(map,{level:9}));
  }
 }
 fs.writeFileSync(`${out}/manifest.json`,JSON.stringify(manifest,null,2)+'\n');
}
const result={method:'Per-response brotli 11 with input-size hint; gzip 9. Runtime first, markdown second, application/startup residual. Only whole AST initializers/function bodies with uniformly mapped provenance are stubbed; syntax checked, no DCE. Nonexecutable accounting; not savings.',subjects:{}};
for(const [subject,files] of Object.entries(manifest.subjects)){
 const records=[];
 for(const file of files){
  const s=gunzipSync(fs.readFileSync(`${out}/${subject}--${file}.gz`)).toString(),map=new TraceMap(JSON.parse(gunzipSync(fs.readFileSync(`${out}/${subject}--${file}.map.gz`))));
  const lines=[0];for(let i=0;i<s.length;i++)if(s[i]==='\n')lines.push(i+1);
  const mappings=[];eachMapping(map,m=>{if(m.source)mappings.push({offset:lines[m.generatedLine-1]+m.generatedColumn,source:m.source,part:category(m.source)})});
  const ast=acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'}),candidates=[];
  walk(ast,n=>{
   let target;
   if(n.type==='VariableDeclarator'&&n.init)target=n.init;
   if(n.type==='ExpressionStatement')target=n;
   if(/^(FunctionDeclaration|FunctionExpression|ArrowFunctionExpression)$/.test(n.type)&&n.body.type==='BlockStatement')target=n.body;
   if(!target)return;
   const ms=mappings.filter(m=>target.start<=m.offset&&m.offset<target.end),parts=new Set(ms.map(m=>m.part));
   if(parts.size!==1||parts.has('app'))return;
   candidates.push({start:target.start,end:target.end,text:target.type==='BlockStatement'?'{}':target.type==='ExpressionStatement'?'0;':'0',part:[...parts][0],sources:[...new Set(ms.map(m=>m.source))]});
  });
  candidates.sort((a,b)=>a.start-b.start||b.end-a.end);
  const spans=[];for(const c of candidates)if(!spans.some(p=>p.start<=c.start&&c.end<=p.end))spans.push(c);
  const baseline=size(s),parts=[];let prev=baseline.brotli,edits=[];
  for(const part of ['runtime','markdown']){
   const ns=spans.filter(n=>n.part===part);edits.push(...ns);const after=size(apply(s,edits));
   parts.push({part,rawSpans:ns.reduce((n,e)=>n+Buffer.byteLength(s.slice(e.start,e.end)),0),brotli:prev-after.brotli,aloneSaved:baseline.brotli-size(apply(s,ns)).brotli});prev=after.brotli;
  }
  parts.push({part:'app and startup',rawSpans:baseline.raw-parts.reduce((n,p)=>n+p.rawSpans,0),brotli:prev});
  records.push({file,sha256:hash(s),...baseline,parts,spans});
 }
 const sum=key=>records.reduce((n,r)=>n+r[key],0);
 const concatenated=files.map(f=>gunzipSync(fs.readFileSync(`${out}/${subject}--${f}.gz`))).reduce((a,b)=>Buffer.concat([a,b]),Buffer.alloc(0));
 const parts=['runtime','markdown','app and startup'].map(part=>({part,brotli:records.reduce((n,r)=>n+r.parts.find(p=>p.part===part).brotli,0)}));
 result.subjects[subject]={raw:sum('raw'),gzip:sum('gzip'),brotli:sum('brotli'),concatenatedDiagnostic:size(concatenated),parts,files:records};
 console.log(subject,sum('brotli'),parts);
}
fs.writeFileSync(`${out}/sizes.json`,JSON.stringify(result,null,2)+'\n');
