import {refs,fields,localId,dependencies,analyse} from './bir.mjs';
// Restricted proof for this closed renderer: a fresh per-instance init record;
// model arrays never escape to effects/foreign calls; mutate only a field's own
// map/filter/append/reverse, when no sibling RHS or callback reads that array.
// Everything outside this proved subset retains copying array operations.
export function ownership(ir){
 const init=ir.byName.init,d=ir.byName.update,model=localId(d.nodes[d.params[1]]),env=new Map([[model,new Set(['$model'])]]),proofs=[];
 if(init.params.length!==1||init.nodes[init.body].op!=='record')return proofs;
 const fresh=new Set(fields(init.nodes[init.body]).filter(([k,id])=>{
  const n=init.nodes[id],r=refs(n.raw);
  return n.op==='list'||n.op==='call'&&['qualified List.map','qualified List.range'].includes(init.nodes[r[0]].raw);
 }).map(([k])=>k));
 for(const n of d.nodes.filter(n=>n?.op==='record_update')){
  const base=d.nodes[refs(n.raw)[0]];if(base.op!=='local'||localId(base)!==model)continue;
  for(const [path,id] of fields(n)){
   if(!fresh.has(path))continue;
   const expr=d.nodes[id],r=refs(expr.raw);if(expr.op!=='call')continue;
   const fn=d.nodes[r[0]].raw.replace(/^(qualified|import_value) /,'');if(!['List.map','List.filter','List.append','List.reverse'].includes(fn))continue;
   const input=d.nodes[r[1]],match=input.raw.match(/^field_access %(\d+) \.(\w+)$/);
   if(!match||match[2]!==path||d.nodes[+match[1]].op!=='local'||localId(d.nodes[+match[1]])!==model)continue;
   if(fields(n).some(([other,rhs])=>other!==path&&dependencies(ir,d,rhs,env).has(path)))continue;
   if(r[2]!=null&&dependencies(ir,d,r[2],env).has(path))continue;
   proofs.push({expression:id,path,operation:fn,reason:'fresh init array; same-field transform; no sibling RHS/callback dependency on old array; closed renderer has no retained model snapshots or effects'});
  }
 }
 return proofs;
}
