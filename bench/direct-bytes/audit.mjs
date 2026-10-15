// Independent replay of archived attribution, and protocol-position checks.
import fs from 'node:fs';
import {createRequire} from 'node:module';
import {gunzipSync,brotliCompressSync,constants} from 'node:zlib';
const require=createRequire(import.meta.url),acorn=require('../ui/apps/solid1/node_modules/acorn');
const root='bench/direct-bytes/results',measure=JSON.parse(fs.readFileSync(`${root}/measurements.json`)),result={};
const walk=(n,f,p=null)=>{if(!n?.type)return;f(n,p);for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(x=>walk(x,f,n));else if(v?.type)walk(v,f,n)}};
const br=s=>brotliCompressSync(Buffer.from(s),{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:Buffer.byteLength(s)}}).length;
for(const [app,platforms]of Object.entries(measure.subjects))for(const [platform,info]of Object.entries(platforms)){
 const s=gunzipSync(fs.readFileSync(`${root}/${app}-${platform}-baseline.mjs.gz`)).toString(),ast=acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'}),nodes=[],parents=new Map();walk(ast,(n,p)=>{nodes.push(n);parents.set(n,p)});
 if(s.indexOf('\n')!==s.length-1)throw Error('Expected one executable line');
 const decls=info.declarations.map(d=>({...d,n:nodes.find(n=>n.type==='VariableDeclarator'&&n.start===d.start&&n.end===d.end)}));
 if(decls.some(d=>!d.n))throw Error('Missing mapped declaration');
 const matrices=nodes.filter(n=>n.type==='ArrayExpression'&&n.elements.length&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[0]?.value==='string'&&typeof e.elements[1]?.value==='string'&&/^[01]+$/.test(e.elements[1].value)));
 const cats={
 'consumer matrix':matrices,
 'group descriptors':decls.filter(d=>/^dg\d/.test(d.original??'')).map(d=>d.n),
 'patch entry functions':decls.filter(d=>/^dp\d/.test(d.original??'')).map(d=>d.n),
 'restate entry functions':decls.filter(d=>/^dr\d/.test(d.original??'')).map(d=>d.n),
 'template factories and preparation':decls.filter(d=>/^(k|p|t)\d/.test(d.original??'')).map(d=>d.n),
 'selection runtime':decls.filter(d=>d.source?.includes('/browser-direct/Direct.beni')&&/^(templateWanted|templateAny|templateSelect|templateSelectNew|templateGroup|templateSameInputs)$/.test(d.original??'')).map(d=>d.n),
 'context and patch runtime':decls.filter(d=>d.source?.includes('/browser-direct/Direct.beni')&&/^template/.test(d.original??'')&&!/^(templateWanted|templateAny|templateSelect|templateSelectNew|templateGroup|templateSameInputs)$/.test(d.original??'')).map(d=>d.n)
 };
 for(const [part,ns]of Object.entries(cats))if(ns.length!==info.parts.find(p=>p.part===part).count)throw Error('Attribution count mismatch');
 if(cats['group descriptors'].length!==cats['patch entry functions'].length)throw Error('Descriptor/patch count mismatch');
 const edits=[],reverse=[];let previous=br(s);
 for(const [part,ns]of Object.entries(cats).reverse()){
  edits.push(...ns.map(n=>({start:n.type==='VariableDeclarator'?n.init.start:n.start,end:n.type==='VariableDeclarator'?n.init.end:n.end,text:n.type==='VariableDeclarator'?'0':'[]'})));
  let out=s,end=s.length;for(const e of edits.toSorted((a,b)=>b.start-a.start)){if(e.end>end)throw Error('Overlapping audit edits');out=out.slice(0,e.start)+e.text+out.slice(e.end);end=e.start}acorn.parse(out,{ecmaVersion:'latest',sourceType:'module'});
  const after=br(out);reverse.push({part,saved:previous-after});previous=after;
 }
 if(previous!==info.residualBrotli)throw Error('Orders disagree about final source cost');
 const eligible=nodes.filter(n=>n.type==='Literal'&&typeof n.value==='string'&&/^(?:\$[\w]+\/)?[\d:/]+$/.test(n.value)&&/\d+:\d+/.test(n.value));
 const protocolCalls=new Set(decls.filter(d=>d.source?.includes('/browser-direct/Direct.beni')&&['templateCapture','templatePlace','templateValue'].includes(d.original)).map(d=>d.binding));
 const descriptors=cats['group descriptors'];
 const literalAudit=eligible.map(n=>{
  let reason=matrices.some(m=>m.start<=n.start&&n.end<=m.end)?'consumer matrix':descriptors.some(d=>d.start<=n.start&&n.end<=d.end)?'group source holes':null;
  const p=parents.get(n);
  if(!reason&&p?.type==='CallExpression'&&protocolCalls.has(p.callee.name)&&p.arguments.includes(n)&&p.arguments.indexOf(n)<2)reason='direct protocol capture/place/value argument';
  if(!reason)throw Error(`Unclassified protocol-shaped literal ${app}/${platform}: ${n.value} at ${n.start}`);
  return {start:n.start,end:n.end,value:n.value,reason};
 });
 const maskReads=nodes.filter(n=>n.type==='BinaryExpression'&&n.operator==='==='&&n.right.value==='1'&&n.left.type==='CallExpression'&&n.left.callee.type==='MemberExpression'&&n.left.callee.property.name==='charAt');
 for(const n of maskReads)if(!decls.some(d=>d.source?.includes('/browser-direct/Direct.beni')&&['templateWanted','templateAny'].includes(d.original)&&d.start<=n.start&&n.end<=d.end))throw Error('Non-protocol charAt rewrite');
 const charCalls=nodes.filter(n=>n.type==='CallExpression'&&n.callee.type==='MemberExpression'&&n.callee.property.name==='charAt'&&decls.some(d=>d.source?.includes('/browser-direct/Direct.beni')&&['templateWanted','templateAny'].includes(d.original)&&d.start<=n.start&&n.end<=d.end));
 if(charCalls.length!==maskReads.length)throw Error('Unchecked mask charAt use');
 result[`${app}-${platform}`]={reverse,residualBrotli:previous,literalAudit,maskReadCount:maskReads.length,sourceMapDeclarationCount:decls.length};
}
fs.writeFileSync(`${root}/audit.json`,JSON.stringify(result,null,2)+'\n');console.log('Both orders agree; every rewritten literal and mask read has a protocol position.');
