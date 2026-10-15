// Nonexecutable deletion probes. These locate byte costs, never available savings.
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {gunzipSync,gzipSync} from 'node:zlib';
const require=createRequire(import.meta.url);let acorn,TraceMap,originalPositionFor;
try{acorn=require('../ui/apps/solid1/node_modules/acorn');({TraceMap,originalPositionFor}=require('../ui/apps/solid1/node_modules/@jridgewell/trace-mapping'));}
catch(error){if(error.code!=='MODULE_NOT_FOUND')throw error;throw Error('Missing analysis dependencies: run npm ci in bench/ui/apps/solid1.',{cause:error});}
const dir='bench/conduit-floor/results',s=gunzipSync(fs.readFileSync(`${dir}/beni-direct--_main.mjs.gz`)).toString();
const map=new TraceMap(JSON.parse(gunzipSync(fs.readFileSync(`${dir}/beni-direct--_main.mjs.map.gz`))));
const {brotliCompressSync,gzipSync:gz,constants}=await import('node:zlib');
const size=s=>{const b=Buffer.from(s);return {raw:b.length,gzip:gz(b,{level:9}).length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}};
const ast=acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'}),decls=[],matrices=[];
function walk(n){if(!n?.type)return;if(n.type==='VariableDeclarator')decls.push({...originalPositionFor(map,{line:1,column:n.start}),n});if(n.type==='ArrayExpression'&&n.elements.length&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[0]?.value==='string'&&/^[01]+$/.test(e.elements[1]?.value)))matrices.push(n);for(const v of Object.values(n))if(Array.isArray(v))v.forEach(walk);else if(v?.type)walk(v)}walk(ast);
const patch=decls.filter(d=>/^dp\d/.test(d.name??''));
const prologues=[];
for(const {n,name} of patch){
 const fn=n.init,stmt=fn.body.body[0],env=fn.params[1]?.name;
 if(stmt?.type!=='VariableDeclaration'||!env)continue;
 if(!stmt.declarations.every(d=>d.init?.type==='MemberExpression'&&d.init.object.name===env&&d.init.computed&&Number.isInteger(d.init.property.value)))continue;
 prologues.push({start:stmt.start,end:stmt.end,text:'',name,slots:stmt.declarations.length});
}
const top=new Set(ast.body.flatMap(n=>n.declarations??[]));
const stub=d=>({start:d.n.init.start,end:d.n.init.end,text:'0',name:d.name});
const groups=decls.filter(d=>/^dg\d/.test(d.name??'')).map(stub);
const selection=decls.filter(d=>top.has(d.n)&&d.source?.includes('/browser-direct/Direct.beni')&&/^(templateWanted|templateAny|templateSelect|templateSelectNew|templateGroup|templateSameInputs)$/.test(d.name??'')).map(stub);
const matrix=matrices.map(n=>({start:n.start,end:n.end,text:'[]'}));
const entries=patch.map(stub);
if(matrices.length!==1||matrices[0].elements.length!==331||patch.length!==146||groups.length!==146||selection.length!==4||prologues.length!==120||prologues.reduce((n,p)=>n+p.slots,0)!==155)throw Error('Frozen Conduit protocol counts changed; audit before measuring');
const accounting=JSON.parse(fs.readFileSync(`${dir}/sizes.json`)).subjects['beni-direct'].files[0].spans;
if(!selection.every(e=>accounting.some(a=>a.part==='runtime'&&a.start<=e.start&&e.end<=a.end)))throw Error('Selection helpers are not in the runtime attribution');
const changes={environmentPrologues:prologues,consumerMatrix:matrix,descriptors:groups,selectionRuntime:selection,patchEntries:entries,protocolAndPrologues:[...matrix,...groups,...selection,...prologues]};
const baseline=size(s),rows=[];
for(const [label,edits] of Object.entries(changes)){
 let changed=s,previous=s.length;
 for(const e of [...edits].sort((a,b)=>b.start-a.start)){if(e.end>previous)throw Error('Overlap');changed=changed.slice(0,e.start)+e.text+changed.slice(e.end);previous=e.start}
 acorn.parse(changed,{ecmaVersion:'latest',sourceType:'module'});
 const after=size(changed);rows.push({label,count:edits.length,...after,saved:baseline.brotli-after.brotli,edits});
 fs.writeFileSync(`${dir}/probe-${label}.mjs.gz`,gzipSync(changed,{level:9}));
}
// Re-encode precisely the same matrix bits. These are data-shape probes, not
// executable AOT group selections: call/row/restate semantics still need lowering.
const pairs=matrices[0].elements.map(e=>e.elements.map(n=>n.value)),width=Math.max(...pairs.map(p=>p[1].length));
const sparse=pairs.map(([id,mask])=>[id,[...mask].flatMap((b,i)=>b==='1'?[i]:[])]);
const inverted=[pairs.map(p=>p[0]),Array.from({length:width},(_,key)=>pairs.flatMap(([,mask],i)=>mask[key]==='1'?[i]:[]))];
for(let i=0;i<pairs.length;i++)for(let k=0;k<width;k++)if((pairs[i][1][k]==='1')!==sparse[i][1].includes(k)||(pairs[i][1][k]==='1')!==inverted[1][k].includes(i))throw Error('Matrix information changed');
const encodings=[];
for(const [label,data]of Object.entries({binaryPairs:pairs,sparseKeyLists:sparse,invertedSourceLists:inverted})){
 const literal=JSON.stringify(data),n=matrices[0],changed=s.slice(0,n.start)+literal+s.slice(n.end),after=size(changed);
 acorn.parse(changed,{ecmaVersion:'latest',sourceType:'module'});
 encodings.push({label,literal:size(literal),wholeBundle:after,saved:baseline.brotli-after.brotli});
 fs.writeFileSync(`${dir}/encoding-${label}.mjs.gz`,gzipSync(changed,{level:9}));
}
fs.writeFileSync(`${dir}/encodings.json`,JSON.stringify({warning:'Same matrix information; changed formats are not runnable or complete AOT group plans. No replacement runtime is credited.',entries:pairs.length,keys:width,setBits:pairs.reduce((n,p)=>n+[...p[1]].filter(b=>b==='1').length,0),encodings},null,2)+'\n');
// Optional pretty-printing is the only step requiring reference dependencies.
if(process.argv.includes('--excerpts')){
const parser=require('../../zig-out/conduit-floor/solid/node_modules/@babel/parser');
const generate=require('../../zig-out/conduit-floor/solid/node_modules/@babel/generator').default;
const pretty=x=>generate(parser.parse(x,{sourceType:'module'})).code;
const excerpt={direct:patch.slice(0,5).map(d=>({name:d.name,source:d.source,code:pretty(`const ${s.slice(d.n.start,d.n.end)};`)})),environmentFunctions:prologues.length,environmentSlots:prologues.reduce((n,p)=>n+p.slots,0),patchFunctions:patch.length};
for(const subject of ['solid-stock','solid-paragraphs']){
 const manifest=JSON.parse(fs.readFileSync(`${dir}/manifest.json`));
 const file=manifest.subjects[subject].find(f=>f.startsWith('ArticleList-'));
 const source=gunzipSync(fs.readFileSync(`${dir}/${subject}--${file}.gz`)).toString();
 excerpt[subject]={file,code:pretty(source)};
}
fs.writeFileSync(`${dir}/excerpts.json`,JSON.stringify(excerpt,null,2)+'\n');
}
fs.writeFileSync(`${dir}/probes.json`,JSON.stringify({baseline,warning:'All deletion probes are nonexecutable and nonadditive. Retained DOM work and replacement scheduling/environment code must be paid for.',rows},null,2)+'\n');
console.log(rows.map(({label,saved})=>({label,saved})));
