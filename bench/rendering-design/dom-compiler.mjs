import {refs,localId,markupTree,dependencies} from './bir.mjs';
// Every DOM factory is generated from BIR. Helpers/recursion remain calls; branch
// and row lifetime machinery is shared, never an application-shaped fake runtime.
export class DomCompiler {
 constructor(expressions,mode){this.mode=mode;this.e=expressions;this.ir=expressions.ir;this.factories=[];this.cache=new Map();this.meta=new Map();}
 locals(d){return [...new Set(d.nodes.filter(n=>n?.op==='pat_var').map(localId))].sort((a,b)=>a-b);}
 scalar(d,id,env){return this.e.expression(d,id,env);}
 isView(d,id,seen=new Set()){
  if(seen.has(id))return false;seen.add(id);const n=d.nodes[id],r=refs(n.raw);
  if(n.op==='markup')return true;
  if(n.op==='call')return d.nodes[r[0]].op==='top'&&this.e.views.has(+d.nodes[r[0]].raw.match(/^top (\d+)/)[1]);
  if(n.op==='case')return r.slice(1).some(b=>this.isView(d,refs(d.nodes[b].raw).at(-1),seen));
  return false;
 }
 descriptor(d,id,env){
  const n=d.nodes[id],r=refs(n.raw),ex=x=>this.scalar(d,x,env);
  if(n.op==='markup'){
   const captures=[...env.keys()].sort((a,b)=>a-b),name=this.factory(d,n,captures);
   return `[${name},${captures.map(x=>env.get(x)).join(',')}]`;
  }
  if(n.op==='call'&&d.nodes[r[0]].op==='top')return `[${this.e.name(this.ir.declarations[+d.nodes[r[0]].raw.match(/^top (\d+)/)[1]])},${r.slice(1).map(ex).join(',')}]`;
  if(n.op==='case'){
   const pieces=r.slice(1).map(b=>{
    const [pat,body]=refs(d.nodes[b].raw),p=this.e.pattern(d,pat,'z'),next=new Map(env);
    const add=x=>{const node=d.nodes[x];if(node.op==='pat_var')next.set(localId(node),'v'+localId(node));else for(const q of refs(node.raw).slice(1))add(q);};add(pat);
    return `if(${p.test}){${p.bind}return ${this.descriptor(d,body,next)}}`;
   });return `(()=>{const z=${ex(r[0])};${pieces.join('')}throw Error('unreachable view')})()`;
  }
  throw Error('unsupported view expression '+n.raw);
 }
 factory(d,n,captures){
  const key=`${d.id}:${n.id}:${captures.join(',')}`;
  if(this.cache.has(key))return this.cache.get(key);
  const name=this.e.prefix+'view'+this.cache.size;this.cache.set(key,name);
  const env=new Map(captures.map(x=>[x,'v'+x])),params=captures.map(x=>'v'+x),mount=[],patches=[],roots=[],children=[],topChildren=[];
  let serial=0;const fresh=()=>`n${serial++}`;
  const depEnv=new Map(d.params.map((p,i)=>[localIdSafe(d.nodes[p]),new Set(i===0&&d.name==='view'?['$model']:[])]));
  function localIdSafe(node){return node.op==='pat_var'?localId(node):-1;}
  const patch=(code,exprs)=>{const index=patches.length;patches.push({code,reads:[...new Set(exprs.flatMap(id=>[...dependencies(this.ir,d,id,depEnv)]))].sort()});return index;};
  const expr=id=>this.scalar(d,id,env);
  const walk=(t,parent,before,top=false)=>{
   if(t.kind==='fragment'){for(const c of t.children)walk(c,parent,before,top);return;}
   const node=fresh();if(top)roots.push(node);
   if(t.kind==='element'){
    mount.push(`const ${node}=element(${JSON.stringify(t.tag)},${parent},${before});`);
    for(const a of t.attrs){
     if(a.name.startsWith('on')){
      if(!a.value.startsWith('%'))throw Error('event not expression');const id=+a.value.slice(1),kind=a.name.slice(2).toLowerCase();
      const payload=kind==='input'?'event.target.value':kind==='check'?'event.target.checked':'event';
      const val=expr(id),en=d.nodes[id];
      const fn=en.op==='lambda'||en.op==='ctor'&&this.ir.ctors[+en.raw.match(/^ctor (\d+)/)[1]].arity;
      if(['partial','cells'].includes(this.mode)){
       const call=this.directEvent(d,id,payload,env);
       mount.push(`${node}.addEventListener(${JSON.stringify(kind==='check'?'change':kind)},event=>{if(live)guarded(()=>{${call};${kind==='input'?'enqueue(()=>ui.p());':''}})});`);
      }else mount.push(`${node}.addEventListener(${JSON.stringify(kind==='check'?'change':kind)},event=>{if(live)S(${fn?`(${val})(${payload})`:val},event,${node})});`);
     }else if(a.value.startsWith('%')){const id=+a.value.slice(1);patch(`attribute(${node},${JSON.stringify(a.name)},${expr(id)});`,[id]);}
     else mount.push(`attribute(${node},${JSON.stringify(a.name)},${a.value});`);
    }
    for(const c of t.children)walk(c,node,'null');
   }else if(t.kind==='text')mount.push(`const ${node}=textNode(${JSON.stringify(t.text)},${parent},${before});`);
   else if(t.kind==='hole'&&!this.isView(d,t.expr)){
    mount.push(`const ${node}=textNode('',${parent},${before});`);patch(`textValue(${node},${expr(t.expr)});`,[t.expr]);
   }else if(t.kind==='hole'){
    mount.push(`const ${node}=switchBlock(${parent},${before},S,()=>${this.descriptor(d,t.expr,env)});`);children.push(node);if(top){roots.pop();topChildren.push(node);}patch(`${node}.p();`,[t.expr]);
   }else if(t.kind==='for'){
    const row=d.nodes[t.row],r=refs(row.raw);if(row.op!=='lambda')throw Error('unsupported row function');
    const rowParam=d.nodes[r[0]],next=new Map(env);next.set(localId(rowParam),'item');
    const rowDesc=this.descriptor(d,r.at(-1),next);
    const eachReads=dependencies(this.ir,d,t.each,depEnv),rowReads=dependencies(this.ir,d,t.row,depEnv);
    const outside=[...rowReads].filter(k=>!eachReads.has(k)),modelParam=d.name==='view'?d.nodes[d.params[0]]:null;
    let selector=null;
    if(modelParam&&outside.length===1){
     const keyNode=d.nodes[t.key],keyRefs=refs(keyNode.raw),keyBody=d.nodes[keyRefs.at(-1)];
     const keyField=keyNode.op==='lambda'&&keyBody.op==='field_access'?keyBody.raw.match(/\.(\w+)$/)[1]:null;
     const candidates=d.nodes.filter(x=>x?.op==='field_access'&&x.raw.endsWith('.'+outside[0]));
     const users=id=>d.nodes.filter(x=>x&&refs(x.raw).includes(id));
     if(keyField&&candidates.length&&candidates.every(x=>users(x.id).every(u=>u.op==='method_call'&&/\(==\)$/.test(u.raw)&&refs(u.raw).some(r=>{const q=d.nodes[r];return q.op==='field_access'&&q.raw.endsWith('.'+keyField)&&d.nodes[refs(q.raw)[0]].op==='local'&&localId(d.nodes[refs(q.raw)[0]])===localId(rowParam)}))))selector=outside[0];
    }
    const rootModel=modelParam?env.get(localId(modelParam)):null;
    const inputValues=rootModel?outside.filter(k=>k!==selector).map(k=>rootModel+'.'+k):[...env.values()];
    const select=selector?'()=>'+rootModel+'.'+selector:'null';
    mount.push(`const ${node}=listBlock(${parent},${before},S,()=>${expr(t.each)},${expr(t.key)},item=>${rowDesc},()=>[${inputValues}],${select});`);children.push(node);if(top){roots.pop();topChildren.push(node);}patch(`${node}.p();`,[t.each,t.row]);
   }else throw Error('unsupported DOM node '+t.kind);
  };
  walk(markupTree(n.markup),'P','B',true);
  const code=`function ${name}(P,B,S,${params.join(',')}){let live=true;${mount.join('')}const h=[${patches.map(p=>`()=>{${p.code}}`).join(',')}];for(const f of h)f();return {h,set:(${params.map((_,i)=>'a'+i)})=>{${params.map((p,i)=>p+'=a'+i+';').join('')}},p(){for(const f of h)f()},get nodes(){return [${roots.join(',')}${roots.length&&topChildren.length?',':''}${topChildren.map(c=>'...'+c+'.nodes').join(',')}]},d(){live=false;${children.map(c=>c+'.d();').join('')}${roots.map(r=>r+'.remove();').join('')}}}}`;
  this.meta.set(name,patches);this.factories.push(code);return name;
 }
 compile(){
  const functions=[];
  for(const id of this.e.views){const d=this.ir.declarations[id];if(d.kind!=='value')continue;
   const env=new Map(d.params.filter(p=>d.nodes[p].op==='pat_var').map(p=>[localId(d.nodes[p]),'v'+localId(d.nodes[p])]));
   const desc=this.descriptor(d,d.body,env),name=this.e.name(d),params=this.e.params(d);
   // A direct markup function can return its compiled factory without a second wrapper.
   if(d.nodes[d.body].op==='markup')functions.push(`function ${name}(P,B,S,${params}){const a=${desc};return a[0](P,B,S,...a.slice(1))}`);
   else functions.push(`function ${name}(P,B,S,${params}){const b=switchBlock(P,B,S,()=>${desc});return {h:[()=>b.p()],set:(${params.map((_,i)=>'a'+i)})=>{${params.map((p,i)=>p+'=a'+i+';').join('')}},p:()=>b.p(),get nodes(){return b.nodes},d:()=>b.d()}}`);
  }
  return this.factories.join('\n')+'\n'+functions.join('\n');
 }
 directEvent(d,id,payload,env){
  const n=d.nodes[id],r=refs(n.raw);
  if(n.op==='lambda'){
   const next=new Map(env);r.slice(0,-1).forEach(p=>{const node=d.nodes[p];if(node.op==='pat_var')next.set(localId(node),payload)});
   return this.directEvent(d,r.at(-1),payload,next);
  }
  if(n.op==='ctor'){const tag=+n.raw.match(/^ctor (\d+)/)[1];return `action${tag}(${this.ir.ctors[tag].arity?payload:''})`;}
  if(n.op==='call'&&d.nodes[r[0]].op==='ctor'){
   const tag=+d.nodes[r[0]].raw.match(/^ctor (\d+)/)[1];return `action${tag}(${r.slice(1).map(x=>this.scalar(d,x,env)).join(',')})`;
  }
  throw Error('Message cannot be erased: '+n.raw);
 }
 rootPatches(){const d=this.ir.byName.view,n=d.nodes[d.body];if(n.op!=='markup')return [{reads:['$model']}];const key=[...this.cache.keys()].find(k=>k.startsWith(`${d.id}:${n.id}:`));return this.meta.get(this.cache.get(key));}
}
