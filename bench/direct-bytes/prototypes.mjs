// Isolated alternatives to the original emitted bundle, never to another trial.
import fs from 'node:fs';
import {gunzipSync,gzipSync,brotliCompressSync,constants} from 'node:zlib';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url),acorn=require('../ui/apps/solid1/node_modules/acorn');
const root='bench/direct-bytes/results',summary={};
const walk=(n,f,p=null)=>{if(!n?.type)return;f(n,p);for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(x=>walk(x,f,n));else if(v?.type)walk(v,f,n)}};
const size=s=>{const b=Buffer.from(s);return {raw:b.length,gzip:gzipSync(b,{level:9}).length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length}};
const apply=(s,edits)=>{for(const e of edits.sort((a,b)=>b.start-a.start))s=s.slice(0,e.start)+e.text+s.slice(e.end);acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'});return s};
for(const app of ['conduit','todomvc','table']){
 const s=gunzipSync(fs.readFileSync(`${root}/${app}-direct-baseline.mjs.gz`)).toString(),base=size(s),ast=acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'}),parents=new Map(),nodes=[];
 walk(ast,(n,p)=>{parents.set(n,p);nodes.push(n)});
 const matrices=nodes.filter(n=>n.type==='ArrayExpression'&&n.elements.length&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[0]?.value==='string'&&typeof e.elements[1]?.value==='string'&&/^[01]+$/.test(e.elements[1].value)));
 const trial=(name,edits)=>{const out=apply(s,edits);fs.writeFileSync(`${root}/${app}-direct-${name}.mjs.gz`,gzipSync(out,{level:9}));return {name,edits:edits.length,...size(out),saved:base.brotli-size(out).brotli}};
 const fields=new Map(['$$directContext','$$templates','$$patch','$$restate','$$arguments','$$template'].map((f,i)=>[f,'$D'+i]));
 const fieldEdits=[];
 walk(ast,(n,p)=>{if(n.type==='Identifier'&&p?.type==='MemberExpression'&&p.property===n&&!p.computed&&fields.has(n.name))fieldEdits.push({start:n.start,end:n.end,text:fields.get(n.name)});if(n.type==='Literal'&&fields.has(n.value))fieldEdits.push({start:n.start,end:n.end,text:JSON.stringify(fields.get(n.value))})});
 const rows=[trial('short-protocol-fields',fieldEdits)];
 const limbs=[];for(const matrix of matrices)for(const e of matrix.elements){const n=e.elements[1],a=[];for(let i=0;i<n.value.length;i+=32){let word=0;for(let j=0;j<32;j++)if(n.value[i+j]==='1')word=(word|2**j)>>>0;a.push(word)}limbs.push({start:n.start,end:n.end,text:JSON.stringify(a)})}
 // charAt mask tests only. All emitted charAt calls below must compare to "1".
 for(const n of nodes)if(n.type==='BinaryExpression'&&n.operator==='==='&&n.right.value==='1'&&n.left.type==='CallExpression'&&n.left.callee.type==='MemberExpression'&&n.left.callee.property.name==='charAt'){
  const obj=s.slice(n.left.callee.object.start,n.left.callee.object.end),key=s.slice(n.left.arguments[0].start,n.left.arguments[0].end);
  limbs.push({start:n.start,end:n.end,text:`((${obj}[${key}>>>5]>>>(${key}&31)&1)===1)`});
 }
 rows.push(trial('u32-masks',limbs));
 const measurements=JSON.parse(fs.readFileSync(`${root}/measurements.json`)).subjects[app].direct;
 const groupName=measurements.runtimeNames.templateGroup;
 const descriptorNames=new Map(measurements.declarations.filter(d=>/^dg\d/.test(d.original??'')).map(d=>[d.binding,d]));
 const packed=[];
 for(const n of nodes){
  if(groupName&&n.type==='CallExpression'&&n.callee.name===groupName){
   const desc=nodes.find(x=>x.type==='VariableDeclarator'&&x.id?.name===n.arguments[0].name&&descriptorNames.has(x.id.name));
   if(!desc)throw Error('Missing descriptor');
   packed.push({start:n.start,end:n.end,text:s.slice(desc.init.start,desc.init.end-1)+','+n.arguments.slice(1).map(a=>s.slice(a.start,a.end)).join(',')+(n.arguments.length===2?',null':'')+']'});
   packed.push({start:desc.init.start,end:desc.init.end,text:'0'});
  }
  if(n.type==='MemberExpression'&&!n.computed&&['$$patch','$$restate'].includes(n.property.name))packed.push({start:n.object.end,end:n.end,text:n.property.name==='$$patch'?'[4]':'[5]'});
 }
 const groupDecl=nodes.find(n=>n.type==='VariableDeclarator'&&groupName&&n.id?.name===groupName);
 // Its implementation's property writes were already collected: replace the
 // whole initializer instead and discard edits nested inside it.
 const packedFlat=groupDecl?packed.filter(e=>!(groupDecl.init.start<=e.start&&e.end<=groupDecl.init.end)):packed;
 if(groupDecl)packedFlat.push({start:groupDecl.init.start,end:groupDecl.init.end,text:'0'});
 rows.push(trial('inline-group-records',packedFlat));

 // Direct object literal instead of a list of pairs + population loop.
 // Works with either a shared templatePlan(entries) or its inlined form.
 const objects=[];
 for(const m of matrices){
  const object='{'+m.elements.map(e=>`${s.slice(e.elements[0].start,e.elements[0].end)}:${s.slice(e.elements[1].start,e.elements[1].end)}`).join(',')+'}';
  const p=parents.get(m);
  if(p.type==='CallExpression'){
   objects.push({start:p.start,end:p.end,text:`(${object.slice(0,-1)},$$templates:new Map()})`});
  }else if(p.type==='ForOfStatement'){
   const assignment=p.body.type==='ExpressionStatement'?p.body.expression:null;
   if(!assignment||assignment.left.type!=='MemberExpression')throw Error('Unexpected matrix loop');
   const plan=assignment.left.object.name;
   const init=nodes.find(n=>n.type==='VariableDeclarator'&&n.id.name===plan&&n.start<p.start&&n.init.type==='ObjectExpression'&&n.init.properties.length===0);
   if(!init)throw Error('Missing plan initializer');
   objects.push({start:init.init.start,end:init.init.end,text:object},{start:p.start,end:p.end,text:''});
  }else throw Error('Unknown matrix parent '+p.type);
 }
 rows.push(trial('literal-plan',objects));
 summary[app]=rows;
}
fs.writeFileSync(`${root}/prototypes.json`,JSON.stringify(summary,null,2)+'\n');console.log(JSON.stringify(summary,null,2));
