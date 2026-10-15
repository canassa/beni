// Inspect and price helper machinery in archived bundles, without executing edits.
import fs from 'node:fs';
import {resolve} from 'node:path';
import {createRequire} from 'node:module';
import {gunzipSync,brotliCompressSync,constants} from 'node:zlib';
const require=createRequire(resolve(process.env.S8_DEPS??'bench/ui/apps/solid1/package.json'));
const acorn=require('acorn');
const {TraceMap,originalPositionFor}=require('@jridgewell/trace-mapping');
const dir='bench/s8/results';
const br=s=>{const b=Buffer.from(s);return brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length};
const walk=(n,fn)=>{if(!n?.type)return;fn(n);for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(x=>walk(x,fn));else if(v?.type)walk(v,fn)}};
const result=[];
for(const app of ['conduit','todomvc','sternhalma','table'])for(const platform of ['tea','direct']){
 const source=gunzipSync(fs.readFileSync(`${dir}/${app}-${platform}.mjs.gz`)).toString();
 const map=new TraceMap(JSON.parse(gunzipSync(fs.readFileSync(`${dir}/${app}-${platform}.map.gz`))));
 const ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'}),decls=[],matrices=[];
 walk(ast,n=>{if(n.type==='VariableDeclarator')decls.push({n,...originalPositionFor(map,{line:1,column:n.id.start})});if(n.type==='ArrayExpression'&&n.elements.length&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[0]?.value==='string'&&typeof e.elements[1]?.value==='string'&&/^[01]+$/.test(e.elements[1].value)))matrices.push(n)});
 const parts={matrix:matrices,'group descriptors':decls.filter(d=>/^dg\d/.test(d.name??'')).map(d=>d.n),'patch entries':decls.filter(d=>/^dp\d/.test(d.name??'')).map(d=>d.n),'restate entries':decls.filter(d=>/^dr\d/.test(d.name??'')).map(d=>d.n)};
 const rows=[];
 for(const [part,nodes]of Object.entries(parts)){
  let edited=source;
  for(const n of nodes.toSorted((a,b)=>b.start-a.start)){const start=n.type==='VariableDeclarator'?n.init.start:n.start,end=n.type==='VariableDeclarator'?n.init.end:n.end;edited=edited.slice(0,start)+(n.type==='VariableDeclarator'?'0':'[]')+edited.slice(end)}
  acorn.parse(edited,{ecmaVersion:'latest',sourceType:'module'});
  rows.push({part,count:nodes.length,rawSpanBytes:nodes.reduce((s,n)=>s+Buffer.byteLength(source.slice(n.start,n.end)),0),independentBrotliSaved:br(source)-br(edited)});
 }
 const visitGuards=ast.body.flatMap(s=>s.declarations??[]).map(n=>({n,...originalPositionFor(map,{line:1,column:n.id.start})})).filter(d=>['groupEpoch','groupProgram','groupOnce'].includes(d.name)).map(d=>({original:d.name,binding:d.n.id.name,source:source.slice(d.n.start,d.n.end)}));
 result.push({app,platform,brotli:br(source),parts:rows,visitGuards,matrices:matrices.map(m=>({entries:m.elements.length,distinctMasks:new Set(m.elements.map(e=>e.elements[1].value)).size}))});
}
fs.writeFileSync(`${dir}/helper-anatomy.json`,JSON.stringify({method:'Independent initializer/matrix stubs, no execution or reoptimisation. Savings cannot be summed or treated as available optimisations.',rows:result},null,2)+'\n');console.log(result);
