// Read beni's public BIR dump. The catalogue supplies source, never dependency sets.
export const refs = s => [...s.matchAll(/%(\d+)/g)].map(m=>+m[1]);
export function parseBir(text) {
 const declarations=[];let d=null,current=null;
 for(const line of text.split('\n')){
  const decl=/^decl (\d+): (?:pub )?(value|alias|type) (\w+)/.exec(line);
  if(decl){d={id:+decl[1],kind:decl[2],name:decl[3],nodes:[],params:[],ctors:[]};declarations[d.id]=d;current=null;continue;}
  if(!d)continue;
  let m;
  if((m=/^  %(\d+) = (.+)$/.exec(line))){current={id:+m[1],raw:m[2],op:m[2].split(' ')[0],markup:[]};d.nodes[current.id]=current;}
  else if(current?.op==='markup'&&/^    /.test(line)&&!/^    \d+ /.test(line))current.markup.push(line);
  else if((m=/^  params \[(.*)\]/.exec(line)))d.params=refs(m[1]);
  else if((m=/^  body %(\d+)/.exec(line)))d.body=+m[1];
  else if((m=/^  ctor (\d+) (\w+) \[(.*)\]/.exec(line)))d.ctors.push({id:+m[1],name:m[2],arity:refs(m[3]).length});
  else if(!/^    /.test(line))current=null;
 }
 const byName=Object.fromEntries(declarations.filter(Boolean).map(d=>[d.name,d]));
 const ctors=Object.fromEntries(declarations.filter(Boolean).flatMap(d=>d.ctors).map(c=>[c.id,c]));
 return {declarations,byName,ctors};
}
export const localId=n=>+n.raw.match(/local (\d+)/)[1];
export const fields=n=>[...n.raw.matchAll(/(\w+) = %(\d+)/g)].map(m=>[m[1],+m[2]]);
export const ctorName=n=>n.raw.match(/\((\w+)\)/)?.[1]||n.raw.split(' ').at(-1).split('.').at(-1);
export function markupTree(lines){
 const root={kind:'fragment',children:[]},stack=[{indent:2,node:root}];
 for(const line of lines){
  const indent=line.length-line.trimStart().length,raw=line.trim();
  while(stack.at(-1).indent>=indent)stack.pop();
  const parent=stack.at(-1).node;
  if(raw.startsWith('attr ')){const m=/^attr ([^ ]+) = (.*)$/.exec(raw);parent.attrs.push({name:m[1],value:m[2]});continue;}
  if(raw.startsWith('row ')){parent.row=refs(raw)[0];continue;}
  let node;
  if(raw.startsWith('element '))node={kind:'element',tag:raw.slice(8),attrs:[],children:[]};
  else if(raw==='fragment')node={kind:'fragment',children:[]};
  else if(raw.startsWith('text '))node={kind:'text',text:JSON.parse(raw.slice(5))};
  else if(raw.startsWith('hole '))node={kind:'hole',expr:refs(raw)[0]};
  else if(raw.startsWith('for ')){const [each,key]=refs(raw);node={kind:'for',each,key};}
  else throw Error('Unsupported markup dump: '+raw);
  parent.children.push(node);stack.push({indent,node});
 }
 return root;
}
// Root-path dependencies, propagated through helpers and lexical bindings.
// A recursive helper conservatively depends on its argument roots at the cycle.
export function dependencies(ir,d,id,env=new Map(),active=new Set()){
 const n=d.nodes[id];if(!n)throw Error(`missing ${d.name} %${id}`);
 const union=xs=>new Set(xs.flatMap(x=>[...x]));
 const go=x=>dependencies(ir,d,x,env,active),rs=refs(n.raw);
 if(n.op==='local')return env.get(localId(n))||new Set();
 if(n.op==='field_access'){
  const base=d.nodes[rs[0]],field=n.raw.match(/\.(\w+)$/)[1];
  if(base.op==='local'&&env.get(localId(base))?.has('$model'))return new Set([field]);
  return go(rs[0]);
 }
 if(n.op==='let'){
  const next=new Map(env);for(const r of rs.slice(0,-1)){const def=d.nodes[r];next.set(localId(def),dependencies(ir,d,refs(def.raw).at(-1),next,active));}
  return dependencies(ir,d,rs.at(-1),next,active);
 }
 if(n.op==='case'){
  const input=go(rs[0]),all=[input];
  for(const branch of rs.slice(1)){const [pat,body]=refs(d.nodes[branch].raw),next=new Map(env);
   const bind=id=>{const p=d.nodes[id];if(p.op==='pat_var')next.set(localId(p),input);else for(const child of refs(p.raw))bind(child);};bind(pat);
   all.push(dependencies(ir,d,body,next,active));
  }
  return union(all);
 }
 if(n.op==='lambda'){
  const next=new Map(env);for(const p of rs.slice(0,-1)){const node=d.nodes[p];if(node.op==='pat_var')next.set(localId(node),new Set());}
  return dependencies(ir,d,rs.at(-1),next,active);
 }
 if(n.op==='call'){
  const fn=d.nodes[rs[0]],args=rs.slice(1).map(go);
  if(fn.op==='top'){
   const target=ir.declarations[+fn.raw.match(/^top (\d+)/)[1]];
   if(active.has(target.id))return union(args);
   const next=new Map();target.params.forEach((p,i)=>{const param=target.nodes[p];if(param.op==='pat_var')next.set(localId(param),args[i]||new Set());});
   return dependencies(ir,target,target.body,next,new Set([...active,target.id]));
  }
  return union([go(rs[0]),...args]);
 }
 if(n.op==='markup'){
  const tree=markupTree(n.markup),out=[];
  const visit=t=>{if(t.kind==='hole')out.push(go(t.expr));if(t.kind==='for'){out.push(go(t.each));out.push(go(t.row));}for(const a of t.attrs||[])if(a.value.startsWith('%'))out.push(go(+a.value.slice(1)));for(const c of t.children||[])visit(c);};visit(tree);return union(out);
 }
 if(n.op==='top'){
  const target=ir.declarations[+n.raw.match(/^top (\d+)/)[1]];
  if(active.has(target.id)||target.params.length)return new Set();
  return dependencies(ir,target,target.body,new Map(),new Set([...active,target.id]));
 }
 if(n.op.startsWith('pat_')||['ctor','import_ctor','qualified','import_value','string','int','float','unit','chunk'].includes(n.op))return new Set();
 return union(rs.map(go));
}
export function analyse(ir){
 const d=ir.byName.update,root=d.nodes[d.body];
 if(root.op!=='case')throw Error('update must have an exhaustive message case');
 const model=localId(d.nodes[d.params[1]]),cases=[];
 function writes(id){
  const n=d.nodes[id],rs=refs(n.raw);
  if(n.op==='local'&&localId(n)===model)return [];
  if(n.op==='record_update'){
   if(d.nodes[rs[0]].op!=='local'||localId(d.nodes[rs[0]])!==model)throw Error('Unproven update root');
   return fields(n).map(([path,rhs])=>({path,rhs,operation:operation(rhs)}));
  }
  if(n.op==='case')return rs.slice(1).flatMap(r=>writes(refs(d.nodes[r].raw).at(-1)));
  throw Error('Unsupported update result '+n.raw);
 }
 function operation(id){
  const n=d.nodes[id],r=refs(n.raw);
  if(n.op!=='call')return {kind:'replace'};
  const fn=d.nodes[r[0]].raw.replace(/^(qualified|import_value) /,'');
  if(!['List.append','List.map','List.filter','List.reverse'].includes(fn))return {kind:'replace',callee:fn};
  const input=d.nodes[r[1]],field=input.raw.match(/^field_access %(\d+) \.(\w+)$/);
  if(!field||d.nodes[+field[1]].op!=='local'||localId(d.nodes[+field[1]])!==model)return {kind:'replace'};
  return {kind:fn.slice(5).toLowerCase(),input:field[2],argument:r[2]??null,witness:n.raw};
 }
 for(const branchId of refs(root.raw).slice(1)){
  const [pat,body]=refs(d.nodes[branchId].raw),[ctor,...params]=refs(d.nodes[pat].raw);
  const found=writes(body),paths=[...new Set(found.map(w=>w.path))].sort();
  cases.push({name:ctorName(d.nodes[ctor]),pat,body,params,writes:paths,assignments:found});
 }
 const v=ir.byName.view,env=new Map([[localId(v.nodes[v.params[0]]),new Set(['$model'])]]),holes=[];
 for(const n of v.nodes.filter(Boolean))if(n.op==='markup'){
  const walk=(t,position)=>{
   if(t.kind==='hole')holes.push({position,expr:t.expr,reads:[...dependencies(ir,v,t.expr,env)].sort()});
   if(t.kind==='for')holes.push({position,expr:t.each,row:t.row,reads:[...new Set([...dependencies(ir,v,t.each,env),...dependencies(ir,v,t.row,env)])].sort(),structural:true});
   for(const a of t.attrs||[])if(!a.name.startsWith('on')&&a.value.startsWith('%'))holes.push({position:position+'@'+a.name,expr:+a.value.slice(1),reads:[...dependencies(ir,v,+a.value.slice(1),env)].sort()});
   (t.children||[]).forEach((c,i)=>walk(c,position+'.'+i));
  };walk(markupTree(n.markup),'%'+n.id);
 }
 return {method:'Record-update result paths and view-expression dependencies from compiler BIR; helper argument substitution; recursive calls conservatively depend on argument roots.',cases,holes,edges:cases.map(c=>({message:c.name,holes:holes.filter(h=>h.reads.some(r=>c.writes.includes(r)||r==='$model')).map(h=>h.position)}))};
}
