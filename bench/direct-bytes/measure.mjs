// Research-only: build unchanged programs, price isolated edits to emitted bundles.
// direnv exec . node bench/direct-bytes/measure.mjs
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createRequire} from 'node:module';
import {createHash} from 'node:crypto';
import {brotliCompressSync,gzipSync,constants} from 'node:zlib';
const require=createRequire(import.meta.url);
const acorn=require('../ui/apps/solid1/node_modules/acorn');
const {TraceMap,originalPositionFor}=require('../ui/apps/solid1/node_modules/@jridgewell/trace-mapping');
export const size=s=>{const b=Buffer.from(s);return {raw:b.length,gzip:gzipSync(b,{level:9}).length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}};
const root='bench/direct-bytes/results';fs.mkdirSync(root,{recursive:true});
const work='zig-out/direct-bytes';fs.mkdirSync(work,{recursive:true});
const beni=process.env.BENI??'zig-out/safe/bin/beni';
const walk=(n,fn,parent=null)=>{if(!n||!n.type)return;fn(n,parent);for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(x=>walk(x,fn,n));else if(v?.type)walk(v,fn,n)}};
const apply=(s,edits)=>{let end=s.length;for(const e of edits.sort((a,b)=>b.start-a.start)){if(e.end>end)throw Error('Overlapping edits '+JSON.stringify(e)+' before '+end);s=s.slice(0,e.start)+e.text+s.slice(e.end);end=e.start}acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'});return s};
const subjects={conduit:'examples/conduit/src',todomvc:'bench/todomvc/apps/beni/Sandbox.beni',table:'bench/ui/apps/beni/Main.beni'};
const result={commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),node:process.version,compilerSha256:createHash('sha256').update(fs.readFileSync(beni)).digest('hex'),subjects:{}};
for(const [app,input] of Object.entries(subjects))for(const platform of ['tea','direct']){
 const out=`${work}/${app}-${platform}`;
 for(const maps of [false,true])execFileSync(beni,['build',`--platform=browser-${platform}`,'--release','--no-cache',...(maps?['--source-maps']:[]),`--out=${out}${maps?'-maps':''}`,input],{stdio:'pipe'});
 const source=fs.readFileSync(`${out}/_main.mjs`,'utf8');
 const mapped=fs.readFileSync(`${out}-maps/_main.mjs`,'utf8').replace(/\/\/# sourceMappingURL=.*\n$/,'');
 if(mapped!==source)throw Error('Map build changed executable bytes');
 const map=new TraceMap(JSON.parse(fs.readFileSync(`${out}-maps/_main.mjs.map`)));
 const ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'}),decls=[],nodes=[],matrices=[];
 walk(ast,(n,p)=>{nodes.push(n);if(n.type==='VariableDeclarator'){let info=originalPositionFor(map,{line:1,column:n.id.start});decls.push({n,...info})}if(n.type==='ArrayExpression'&&n.elements.length&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[0]?.value==='string'&&typeof e.elements[1]?.value==='string'&&/^[01]+$/.test(e.elements[1].value)))matrices.push(n)});
 const directName=name=>decls.find(d=>d.name===name&&d.source?.includes('/browser-direct/Direct.beni'))?.n.id.name;
 const top=new Set(ast.body.flatMap(n=>n.declarations??[]));
 const categories={
  'consumer matrix':matrices,
  'group descriptors':decls.filter(d=>/^dg\d/.test(d.name??'')).map(d=>d.n),
  'patch entry functions':decls.filter(d=>/^dp\d/.test(d.name??'')).map(d=>d.n),
  'restate entry functions':decls.filter(d=>/^dr\d/.test(d.name??'')).map(d=>d.n),
  'template factories and preparation':decls.filter(d=>/^(k|p|t)\d/.test(d.name??'')&&top.has(d.n)).map(d=>d.n),
  'selection runtime':decls.filter(d=>top.has(d.n)&&d.source?.includes('/browser-direct/Direct.beni')&&/^(templateWanted|templateAny|templateSelect|templateSelectNew|templateGroup|templateSameInputs)$/.test(d.name??'')).map(d=>d.n),
  'context and patch runtime':decls.filter(d=>top.has(d.n)&&d.source?.includes('/browser-direct/Direct.beni')&&/^template/.test(d.name??'')&&!/^(templateWanted|templateAny|templateSelect|templateSelectNew|templateGroup|templateSameInputs)$/.test(d.name??'')).map(d=>d.n),
 };
 const stub=n=>({start:n.type==='VariableDeclarator'?n.init.start:n.start,end:n.type==='VariableDeclarator'?n.init.end:n.end,text:n.type==='VariableDeclarator'?'0':'[]'});
 const baseline=size(source),rows=[];let cumulative=[],previous=baseline.brotli;
 for(const [part,ns] of Object.entries(categories)){
  const edits=ns.filter(n=>n.type!=='VariableDeclarator'||n.init).map(stub);
  const alone=size(apply(source,edits.slice()));cumulative.push(...edits);
  // No overlaps across these categories; a matrix is nested in main only.
  const peeled=size(apply(source,cumulative.slice()));
  rows.push({part,count:edits.length,rawSpans:ns.reduce((s,n)=>s+Buffer.byteLength(source.slice(n.start,n.end)),0),alone,aloneSaved:baseline.brotli-alone.brotli,orderedSaved:previous-peeled.brotli});previous=peeled.brotli;
 }
 const trials=[];
 const trial=(name,edits)=>{const changed=apply(source,edits);const stats=size(changed);trials.push({name,edits:edits.length,...stats,saved:baseline.brotli-stats.brotli});fs.writeFileSync(`${root}/${app}-${platform}-${name}.mjs.gz`,gzipSync(changed,{level:9}));return changed};
 // Only the matrix's binary values: charAt(out-of-range) is still unequal to "1".
 const trim=matrices.flatMap(m=>m.elements.map(e=>e.elements[1]).filter(n=>/0$/.test(n.value)).map(n=>({start:n.start,end:n.end,text:JSON.stringify(n.value.replace(/0+$/,''))})));
 if(platform==='direct'){
  trial('trim-mask-zeroes',trim);
  const eligible=nodes.filter(n=>n.type==='Literal'&&typeof n.value==='string'&&/^(?:\$[\w]+\/)?[\d:/]+$/.test(n.value)&&/\d+:\d+/.test(n.value));
  const tokens=[...new Set(eligible.flatMap(n=>n.value.match(/\d+:\d+/g)))].sort();const ids=new Map(tokens.map((t,i)=>[t,i.toString(36)]));
  const paths=eligible.map(n=>({start:n.start,end:n.end,text:JSON.stringify(n.value.replace(/\d+:\d+/g,t=>ids.get(t)))}));
  trial('short-path-ids',paths);trial('paths-and-zeroes',[...trim,...paths]);
  // Exact duplicate descriptor initializers can share the immutable descriptor?
  // They are mutated by templateGroup, so report duplicates but DO NOT merge.
 }
 const row={baseline,sha256:createHash('sha256').update(source).digest('hex'),parts:rows,residualBrotli:previous,trials,matrices:matrices.map(m=>({entries:m.elements.length,raw:m.end-m.start,distinctMasks:new Set(m.elements.map(e=>e.elements[1].value)).size})),declarations:decls.filter(d=>top.has(d.n)).map(d=>({binding:d.n.id.name,original:d.name,source:d.source,start:d.n.start,end:d.n.end})),runtimeNames:Object.fromEntries(['templatePlan','templateAny','templateWanted','templateGroup','templateSelectNew','templateSelect','templatePatch'].map(n=>[n,directName(n)]))};
 (result.subjects[app]??={})[platform]=row;
 fs.writeFileSync(`${root}/${app}-${platform}-baseline.mjs.gz`,gzipSync(source,{level:9}));
 console.log(app,platform,baseline,rows.map(r=>[r.part,r.aloneSaved]),trials);
}
fs.writeFileSync(`${root}/measurements.json`,JSON.stringify(result,null,2)+'\n');
