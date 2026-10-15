import fs from 'node:fs';
import {parseBir,analyse,localId} from './bir.mjs';
import {ownership} from './ownership.mjs';
import {Expressions} from './expressions.mjs';
import {DomCompiler} from './dom-compiler.mjs';
export function prototype(root,mode){
 let source=`import * as core from '../../../core.mjs';\n`;
 source+=fs.readFileSync(import.meta.dirname+'/reconcile.js','utf8')+'\n'+fs.readFileSync(import.meta.dirname+'/runtime.js','utf8');
 if(mode==='cells')source+=fs.readFileSync(import.meta.dirname+'/cells.js','utf8');
 const files=fs.readdirSync(root).filter(f=>/^Shape\d+\.bir$/.test(f)).sort((a,b)=>+a.match(/\d+/)[0]-+b.match(/\d+/)[0]);
 source+='\n// APP-BEGIN\n';
 const witnesses=[];
 for(let index=0;index<files.length;index++){
  const ir=parseBir(fs.readFileSync(root+'/'+files[index],'utf8')),analysis=analyse(ir),e=new Expressions(ir,'s'+index+'_'),dom=new DomCompiler(e,mode);
  const proofs=ownership(ir);e.owned=new Set(proofs.map(p=>p.expression));const fieldNames=[...new Set(analysis.cases.flatMap(c=>c.writes))];if(mode==='static')e.dirtyFields=fieldNames;
  const logic=e.constructors()+'\n'+e.functions(),views=dom.compile(),patches=dom.rootPatches();
  const update=e.name(ir.byName.update),init=e.name(ir.byName.init),view=e.name(ir.byName.view);
  let wiring='';
  if(mode==='local')wiring=`function send(msg,event,node){guarded(()=>{model=${update}(msg,model);ui.set(model);enqueue(()=>ui.p())})}`;
  else if(mode==='static'){
   wiring=`let dirty=0;function send(msg,event,node){guarded(()=>{dirty=0;model=${update}(msg,model);ui.set(model);${patches.map((p,i)=>`if(dirty&${p.reads.includes('$model')?(1<<fieldNames.length)-1:p.reads.reduce((mask,k)=>mask|(1<<fieldNames.indexOf(k)),0)})enqueue(ui.h[${i}]);`).join('')}if(node&&event.type==='input')enqueue(()=>ui.p());})}`;
  }else if(mode==='partial'||mode==='cells'){
   const d=ir.byName.update,modelId=localId(d.nodes[d.params[1]]);
   const handlers=analysis.cases.map(c=>{
    const params=e.params(d,c.params),env=new Map([[modelId,'model']]);
    const target=patches.map((p,i)=>p.reads.some(r=>r==='$model'||c.writes.includes(r))?i:-1).filter(i=>i>=0);
    const tag=+d.nodes[+d.nodes[c.pat].raw.match(/%(\d+)/)[1]].raw.match(/^ctor (\d+)/)[1];
    const body=mode==='cells'?`const next=${e.expression(d,c.body,env)};${c.writes.map(k=>`store.set(${JSON.stringify(k)},next.${k},${proofs.some(p=>p.path===k)});`).join('')}`:`model=${e.expression(d,c.body,env)};ui.set(model);${target.map(i=>`enqueue(ui.h[${i}]);`).join('')}`;
    return `function action${tag}(${params}){${body}}`;
   }).join('\n');
   const dispatch=analysis.cases.map(c=>{const pat=d.nodes[c.pat],ctor=d.nodes[+pat.raw.match(/%(\d+)/)[1]],tag=+ctor.raw.match(/^ctor (\d+)/)[1];return `case ${tag}:action${tag}(...msg.slice(1));break;`;}).join('');
   wiring=handlers+'const send=null;';
  }else throw Error('Unknown prototype '+mode);
  let componentSource=`\n{${logic}\n${views}\n${mode==='cells'?`const store=cellStore(${init}(undefined));let model=store.value,ui;`:`let model=${init}(undefined),ui;`}${wiring}\nui=${view}(document.body,null,send,model);${mode==='cells'?'for(const f of ui.h)observeBinding(f);':''}}\n`;
  const fieldMap=Object.fromEntries(fieldNames.map((k,i)=>[k,'m'+i]));
  for(const [field,short] of Object.entries(fieldMap))componentSource=componentSource.replaceAll(new RegExp('\\b'+field+'\\b','g'),short);
  source+=componentSource;
  witnesses.push({module:files[index],...analysis,ownership:proofs,emittedFields:fieldMap,rootPatches:patches});
 }
 const [support,app]=source.split('// APP-BEGIN');return {source,witnesses,chunks:{'render-runtime.js':support,'App.js':app}};
}
if(process.argv[1]===import.meta.filename){
 const name=process.argv[2]||'list-17-1',root=import.meta.dirname+'/out/apps/'+name;
 for(const mode of ['partial','static','cells','local']){const {source,witnesses}=prototype(root,mode),out=import.meta.dirname+'/out/prototypes/'+name;fs.mkdirSync(out,{recursive:true});fs.writeFileSync(out+'/'+mode+'.js',source);fs.writeFileSync(out+'/analysis.json',JSON.stringify(witnesses,null,2));console.log(name,mode,source.length);}
}
