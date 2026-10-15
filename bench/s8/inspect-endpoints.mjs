// Source inspection only: retain emitted work without timing edited programs.
import fs from 'node:fs';
import {resolve} from 'node:path';
import {createRequire} from 'node:module';
import {gunzipSync} from 'node:zlib';
import {createHash} from 'node:crypto';
const require=createRequire(resolve(process.env.S8_DEPS??'bench/ui/apps/solid1/package.json'));
const acorn=require('acorn'),{TraceMap,originalPositionFor}=require('@jridgewell/trace-mapping');
const dir='bench/s8/results',rows=[];
const walk=(n,fn)=>{if(!n?.type)return;fn(n);for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(x=>walk(x,fn));else if(v?.type)walk(v,fn)}};
for(const [sweep,n] of Object.entries({holes:10000,width:1024,depth:128,rows:30000,live:10000,derived:100000,helperRows:10000,tree:12})){
 const source=gunzipSync(fs.readFileSync(`${dir}/${sweep}-${n}-beni-direct-rel-_main.mjs.gz`)).toString();
 const map=new TraceMap(JSON.parse(gunzipSync(fs.readFileSync(`${dir}/${sweep}-${n}-direct.map.gz`))));
 const ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'});
 const decls=ast.body.flatMap(s=>s.declarations??[]),main=decls.find(d=>originalPositionFor(map,{line:1,column:d.id.start}).name==='main');
 const mount=main?.init.arguments?.find(a=>a.type==='ArrowFunctionExpression');
 if(!mount?.body.body)throw Error('No mounted program for '+sweep);
 const functions=mount.body.body.flatMap(s=>s.declarations??[]).filter(d=>d.init?.type==='ArrowFunctionExpression');
 const count=(node,test)=>{let k=0;walk(node,x=>{if(test(x))k++});return k};
 const isData=n=>n.type==='AssignmentExpression'&&n.left.type==='MemberExpression'&&n.left.property.name==='data';
 const groups=new Map(functions.filter(d=>count(d.init,isData)>0).map(d=>[d.id.name,d.init]));
 const handlers=functions.map(d=>{const calls=[];walk(d.init,x=>{if(x.type==='CallExpression'&&x.callee.type==='Identifier'&&groups.has(x.callee.name))calls.push(x.callee.name)});return {name:d.id.name,calls,body:source.slice(d.init.start,d.init.end)}}).filter(d=>d.calls.length);
 const largest=handlers.toSorted((a,b)=>b.calls.length-a.calls.length)[0];
 const children={};
 if(largest)for(const name of largest.calls)walk(groups.get(name),x=>{if(x.type==='MemberExpression'&&!x.computed){const p=x.property.name;children[p]=(children[p]??0)+1}});
 rows.push({sweep,n,bundleSpreadElements:count(ast,x=>x.type==='SpreadElement'),objectSpreads:count(ast,x=>x.type==='ObjectExpression'&&x.properties.some(p=>p.type==='SpreadElement')),rootTextGroupDefinitions:groups.size,largestGroupCaller:largest??null,memberReadsAcrossCalledGroups:children,groupBodies:[...new Set(largest?.calls??[])].map(name=>({name,dataWrites:count(groups.get(name),isData),body:source.slice(groups.get(name).start,groups.get(name).end)}))});
}
const holesGrowth=[];
for(const n of [10,30,100,300,1000,3000,10000]){
 const file=`bench/ui/out/scaling/holes/${n}/beni-direct-rel/_main.mjs`,source=fs.readFileSync(file,'utf8'),ast=acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'});
 let html=0;walk(ast,x=>{if(x.type==='Literal'&&typeof x.value==='string'&&x.value.startsWith('<'))html+=Buffer.byteLength(source.slice(x.start,x.end))});
 holesGrowth.push({n,file,sha256:createHash('sha256').update(source).digest('hex'),raw:Buffer.byteLength(source),htmlLiteralSourceBytes:html,nonHtmlSourceBytes:Buffer.byteLength(source)-html});
}
fs.writeFileSync(`${dir}/endpoint-inspection.json`,JSON.stringify({holesGrowth,method:'AST inspection. Root text groups are mount-scope arrows with a .data assignment; largest caller is selected by direct calls to those definitions. Member reads count source occurrences, not measured CPU time. Spreads count the whole emitted bundle, not just a handler.',rows},null,2)+'\n');
console.log(rows.map(({sweep,n,bundleSpreadElements,rootTextGroupDefinitions,largestGroupCaller,memberReadsAcrossCalledGroups})=>({sweep,n,bundleSpreadElements,rootTextGroupDefinitions,caller:largestGroupCaller?.name,calls:largestGroupCaller?.calls.length,memberReadsAcrossCalledGroups})));
