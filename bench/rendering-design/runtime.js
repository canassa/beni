// Rendering/lifetime support. Unknown defects stop the app and escape unchanged.
let dead=false,queued=false,pending=new Set(),journals=new WeakMap();
function guarded(f){if(dead)return;let ok=false;try{f();ok=true}finally{if(!ok){dead=true;pending.clear()}}}
function enqueue(f){pending.add(f);if(!queued){queued=true;queueMicrotask(()=>guarded(flush))}}
function flush(){queued=false;const work=pending;pending=new Set();for(const f of work)f();journals=new WeakMap()}
function element(tag,parent,before){const n=document.createElement(tag);parent.insertBefore(n,before);return n}
function textNode(value,parent,before){const n=document.createTextNode(value);parent.insertBefore(n,before);return n}
function textValue(n,value){value=String(value);if(n.data!==value)n.data=value}
function attribute(n,key,value){
 if(key==='value'||key==='checked'||key==='disabled'||key==='hidden'){if(n[key]!==value)n[key]=value;return}
 value=String(value);if(n.getAttribute(key)!==value)n.setAttribute(key,value);
}
function mountDescriptor(parent,before,send,desc){return desc[0](parent,before,send,...desc.slice(1))}
function updateDescriptor(block,desc){block.set(...desc.slice(1));block.p()}
function switchBlock(parent,before,send,pick){
 const anchor=textNode('',parent,before);let factory=null,block=null;
 const p=()=>{const desc=pick();if(desc[0]!==factory){block?.d();factory=desc[0];block=mountDescriptor(parent,anchor,send,desc)}else updateDescriptor(block,desc)};
 p();return {p,get nodes(){return [...(block?.nodes||[]),anchor]},d(){block?.d();anchor.remove()}};
}
function recordEdit(xs,entry){let edits=journals.get(xs);if(!edits)journals.set(xs,edits=[]);edits.push(entry);return xs}
function edit_map(xs,f){const changes=[];core.Owned_map(xs,x=>{const next=f(x);if(next!==x)changes.push([x,next]);return next});return recordEdit(xs,{kind:'map',changes})}
function edit_filter(xs,f){const removed=[];core.Owned_filter(xs,x=>{const keep=f(x);if(!keep)removed.push(x);return keep});return recordEdit(xs,{kind:'remove',items:removed})}
function edit_append(xs,ys){core.Owned_append(xs,ys);return recordEdit(xs,{kind:'append',items:ys})}
function edit_reverse(xs){core.Owned_reverse(xs);return recordEdit(xs,{kind:'reorder'})}
function listBlock(parent,before,send,each,key,make,inputs=()=>[],selector=null){
 const anchor=textNode('',parent,before);let old=[],byKey=new Map(),previousInputs=[],selected,previousItems=null,seenJournal=null,distinct=true;
 const patchRow=(row,item)=>{const desc=make(item);if(row.factory!==desc[0])return false;updateDescriptor(row.block,desc);row.item=item;return true};
 const newRow=(item,detach=false)=>{const desc=make(item),block=mountDescriptor(parent,anchor,send,desc);if(detach)for(const node of block.nodes)node.remove();return {item,factory:desc[0],block}};
 const p=()=>{
  const rows=each(),captured=inputs(),nextSelected=selector?.(),edits=journals.get(rows);
  const inputsSame=captured.length===previousInputs.length&&captured.every((x,i)=>x===previousInputs[i]);
  let fast=previousItems===rows&&inputsSame&&distinct;
  if(fast&&edits!==seenJournal&&edits){
   // Preflight before changing DOM; an unproved permutation or duplicate key
   // falls back to the same full keyed reconciler used below.
   const added=new Set(),removed=new Set();const has=k=>added.has(k)||byKey.has(k)&&!removed.has(k);
   for(const edit of edits){
    if(edit.kind==='reorder'){fast=false;break}
    if(edit.kind==='map'&&edit.changes.some(([a,b])=>key(a)!==key(b)||!has(key(a)))){fast=false;break}
    if(edit.kind==='remove')for(const item of edit.items)removed.add(key(item));
    if(edit.kind==='append')for(const item of edit.items){const k=key(item);if(has(k))fast=false;added.add(k);removed.delete(k)}
   }
   if(fast)for(const edit of edits){
    if(edit.kind==='map')for(const [a,b] of edit.changes){const row=byKey.get(key(a))[0];if(!patchRow(row,b))throw Error('proved row factory changed')}
    if(edit.kind==='remove')for(const item of edit.items){const k=key(item),row=byKey.get(k)?.[0];if(row){row.block.d();old.splice(old.indexOf(row),1);byKey.delete(k)}}
    if(edit.kind==='append')for(const item of edit.items){const row=newRow(item);old.push(row);byKey.set(key(item),[row])}
   }
  }
  if(fast){
   if(selector&&nextSelected!==selected){for(const k of new Set([selected,nextSelected])){const row=byKey.get(k)?.[0];if(row)patchRow(row,row.item)}}
  }else{
   const next=[],nextMap=new Map(),used=new Map();
   for(const item of rows){
    const k=key(item),rank=used.get(k)||0;used.set(k,rank+1);
    let row=byKey.get(k)?.[rank];
    const selectChanged=selector&&nextSelected!==selected&&(k===nextSelected||k===selected);
    if(row){if(row.item!==item||!inputsSame||selectChanged){if(!patchRow(row,item)){row.block.d();row=newRow(item,old.length>0)}}}
    else row=newRow(item,old.length>0);
    next.push(row);if(!nextMap.has(k))nextMap.set(k,[]);nextMap.get(k).push(row);
   }
   const keep=new Set(next),oldNodes=old.flatMap(r=>r.block.nodes),newNodes=next.flatMap(r=>r.block.nodes);
   if(oldNodes.length&&(oldNodes.length!==newNodes.length||oldNodes.some((n,i)=>n!==newNodes[i])))reconcileArrays(parent,oldNodes,newNodes,anchor);
   for(const row of old)if(!keep.has(row))row.block.d();
   old=next;byKey=nextMap;distinct=[...byKey.values()].every(chain=>chain.length===1);
  }
  previousItems=rows;previousInputs=captured;selected=nextSelected;seenJournal=edits;
 };
 p();return {p,get nodes(){return [...old.flatMap(r=>r.block.nodes),anchor]},d(){for(const row of old)row.block.d();anchor.remove();old=[];byKey.clear()}};
}
