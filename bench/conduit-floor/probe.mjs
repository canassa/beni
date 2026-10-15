// Nonexecutable deletion probes. These locate byte costs, never available savings.
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {gunzipSync,gzipSync} from 'node:zlib';
const require=createRequire(import.meta.url),acorn=require('../ui/apps/solid1/node_modules/acorn');
const {TraceMap,originalPositionFor}=require('../ui/apps/solid1/node_modules/@jridgewell/trace-mapping');
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
const changes={environmentPrologues:prologues,consumerMatrix:matrix,descriptors:groups,selectionRuntime:selection,patchEntries:entries,protocolAndPrologues:[...matrix,...groups,...selection,...prologues]};
const baseline=size(s),rows=[];
for(const [label,edits] of Object.entries(changes)){
 let changed=s,previous=s.length;
 for(const e of [...edits].sort((a,b)=>b.start-a.start)){if(e.end>previous)throw Error('Overlap');changed=changed.slice(0,e.start)+e.text+changed.slice(e.end);previous=e.start}
 acorn.parse(changed,{ecmaVersion:'latest',sourceType:'module'});
 const after=size(changed);rows.push({label,count:edits.length,...after,saved:baseline.brotli-after.brotli,edits});
 fs.writeFileSync(`${dir}/probe-${label}.mjs.gz`,gzipSync(changed,{level:9}));
}
// Readable snippets from the actual shipped Solid component function and direct entries.
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
fs.writeFileSync(`${dir}/probes.json`,JSON.stringify({baseline,warning:'All deletion probes are nonexecutable and nonadditive. Retained DOM work and replacement scheduling/environment code must be paid for.',rows},null,2)+'\n');
console.log(rows.map(({label,saved})=>({label,saved})));
