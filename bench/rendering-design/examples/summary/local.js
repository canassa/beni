import * as core from '../../core.mjs';
// Unmodified reconcileArrays from @solidjs/web 2.0.0-rc.9.
// MIT, Copyright (c) 2016-2025 Ryan Carniato. See THIRD_PARTY_LICENSES.md.
const $$SLOT=Symbol("slot");
function reconcileArrays(parentNode, a, b, marker) {
  let bLength = b.length,
    aEnd = a.length,
    bEnd = bLength,
    aStart = 0,
    bStart = 0,
    tail = a[aEnd - 1],
    tailTag = tail[$$SLOT],
    after = tail.parentNode === parentNode && (!tailTag || tailTag === marker) ? tail.nextSibling : marker || null,
    map = null,
    anchor,
    anchorTag;
  const isLive = n => {
    if (!n) return false;
    const tag = n[$$SLOT];
    return n.parentNode === parentNode && (!tag || tag === marker);
  };
  while (aStart < aEnd || bStart < bEnd) {
    if (a[aStart] === b[bStart] && isLive(a[aStart])) {
      aStart++;
      bStart++;
      continue;
    }
    while (a[aEnd - 1] === b[bEnd - 1] && isLive(a[aEnd - 1])) {
      aEnd--;
      bEnd--;
    }
    if (aEnd === aStart) {
      let node;
      if (bEnd < bLength) {
        if (bStart) {
          const prev = b[bStart - 1];
          const prevTag = prev[$$SLOT];
          node = prev.parentNode === parentNode && (!prevTag || prevTag === marker) ? prev.nextSibling : after;
        } else node = b[bEnd - bStart];
      } else node = after;
      while (bStart < bEnd) {
        const n = b[bStart++];
        parentNode.insertBefore(n, node);
        if (marker) n[$$SLOT] = marker;
      }
    } else if (bEnd === bStart) {
      while (aStart < aEnd) {
        const n = a[aStart++];
        if (!map || !map.has(n)) {
          const tag = n[$$SLOT];
          if (n.parentNode === parentNode && (!tag || tag === marker)) n.remove();
        }
      }
    } else if ((anchor = a[aStart]) === b[bEnd - 1] && b[bStart] === a[aEnd - 1] && anchor.parentNode === parentNode && (!(anchorTag = anchor[$$SLOT]) || anchorTag === marker)) {
      if (marker) {
        do {
          const n = a[--aEnd];
          parentNode.insertBefore(n, anchor);
          n[$$SLOT] = marker;
          bStart++;
          if (aStart >= aEnd - 1 || bStart >= bEnd) break;
        } while (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]);
      } else {
        do {
          parentNode.insertBefore(a[--aEnd], anchor);
          bStart++;
          if (aStart >= aEnd - 1 || bStart >= bEnd) break;
        } while (a[aStart] === b[bEnd - 1] && b[bStart] === a[aEnd - 1]);
      }
    } else {
      if (!map) {
        map = new Map();
        let i = bStart;
        while (i < bEnd) map.set(b[i], i++);
      }
      const index = map.get(a[aStart]);
      if (index != null) {
        if (bStart < index && index < bEnd) {
          let i = aStart,
            sequence = 1,
            t;
          while (++i < aEnd && i < bEnd) {
            if ((t = map.get(a[i])) == null || t !== index + sequence) break;
            sequence++;
          }
          if (sequence > index - bStart) {
            const head = a[aStart];
            const headTag = head[$$SLOT];
            const node = head.parentNode === parentNode && (!headTag || headTag === marker) ? head : after;
            while (bStart < index) {
              const n = b[bStart++];
              parentNode.insertBefore(n, node);
              if (marker) n[$$SLOT] = marker;
            }
          } else {
            const oldNode = a[aStart++];
            const newNode = b[bStart++];
            const oldTag = oldNode[$$SLOT];
            if (oldNode.parentNode === parentNode && (!oldTag || oldTag === marker)) {
              parentNode.replaceChild(newNode, oldNode);
            } else {
              parentNode.insertBefore(newNode, after);
            }
            if (marker) newNode[$$SLOT] = marker;
          }
        } else aStart++;
      } else {
        const n = a[aStart++];
        const nTag = n[$$SLOT];
        if (n.parentNode === parentNode && (!nTag || nTag === marker)) n.remove();
      }
    }
  }
}

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

// APP-BEGIN

{function s0_c0(a0,a1,a2,a3){return [0,a0,a1,a2,a3]}
function s0_c1(a0,a1,a2,a3){return [1,a0,a1,a2,a3]}
function s0_c3(a0){return [3,a0]}
function s0_c4(a0){return [4,a0]}
function s0_c5(a0){return [5,a0]}
function s0_f1(v0){return core.List_foldl(v0,0,(v1,v2)=>(v2+v1.score))}
function s0_f4(_){return ({m1:core.List_map(core.List_range(1,20),(v0)=>({id:v0,title:("Item "+core.String_fromInt(v0)),score:core.Int_mod((v0*1),17),done:false})),m0:21,m2:0,m3:1})}
function s0_f5(v0,v1){return (()=>{const z=v0;if(z[0]===2){return ({...v1,m1:edit_append(v1.m1,[({id:v1.m0,title:("summary 17/0 Activity "+core.String_fromInt(v1.m0)),score:1,done:false})]),m0:(v1.m0+1)})}if(z[0]===3){const v2=z[1];return ({...v1,m1:edit_filter(v1.m1,(v3)=>(v3.id!==v2))})}if(z[0]===4){const v4=z[1];return ({...v1,m1:edit_map(v1.m1,(v5)=>(()=>{const z=(v5.id===v4);if(z===true){return ({...v5,title:(v5.title+"!"),score:(v5.score+1),done:(!v5.done)})}if(z===false){return v5}throw Error('unreachable pattern')})())})}if(z[0]===5){const v6=z[1];return ({...v1,m2:v6})}if(z[0]===6){return ({...v1,m1:edit_reverse(v1.m1)})}if(z[0]===7){return ({...v1,m3:(v1.m3+1)})}throw Error('unreachable pattern')})()}
function s0_view1(P,B,S,v0,v3){let live=true;const n0=element("li",P,B);const n1=element("button",n0,null);n1.addEventListener("click",event=>{if(live)S(s0_c5(v3.id),event,n1)});const n2=textNode('',n1,null);const n3=element("output",n0,null);const n4=textNode('',n3,null);const n5=element("button",n0,null);n5.addEventListener("click",event=>{if(live)S(s0_c4(v3.id),event,n5)});const n6=textNode("Edit",n5,null);const n7=element("button",n0,null);n7.addEventListener("click",event=>{if(live)S(s0_c3(v3.id),event,n7)});const n8=textNode("Remove",n7,null);const h=[()=>{attribute(n0,"data-row",core.String_fromInt(v3.id));},()=>{attribute(n0,"class",(()=>{const z=(v0.m2===v3.id);if(z===true){return "selected"}if(z===false){return ""}throw Error('unreachable pattern')})());},()=>{textValue(n2,v3.title);},()=>{textValue(n4,v3.score);}];for(const f of h)f();return {h,set:(a0,a1)=>{v0=a0;v3=a1;},p(){for(const f of h)f()},get nodes(){return [n0]},d(){live=false;n0.remove();}}}
function s0_view0(P,B,S,v0){let live=true;const n0=element("section",P,B);attribute(n0,"id","s0");attribute(n0,"data-shape","summary");const n1=element("h2",n0,null);const n2=textNode("summary 17/0 Activity",n1,null);const n3=element("div",n0,null);attribute(n3,"class","level-0");const n4=element("button",n3,null);attribute(n4,"id","s0-add");n4.addEventListener("click",event=>{if(live)S([2],event,n4)});const n5=textNode("Add",n4,null);const n6=element("button",n3,null);attribute(n6,"id","s0-reverse");n6.addEventListener("click",event=>{if(live)S([6],event,n6)});const n7=textNode("Reverse",n6,null);const n8=element("button",n3,null);attribute(n8,"id","s0-rate");n8.addEventListener("click",event=>{if(live)S([7],event,n8)});const n9=textNode("Rate",n8,null);const n10=element("dl",n3,null);const n11=element("dt",n10,null);const n12=textNode("Total",n11,null);const n13=element("dd",n10,null);attribute(n13,"id","s0-total");const n14=textNode('',n13,null);const n15=element("dt",n10,null);const n16=textNode("Completed",n15,null);const n17=element("dd",n10,null);const n18=textNode('',n17,null);const n19=element("p",n3,null);const n20=textNode('',n19,null);const n21=textNode(" records",n19,null);const n22=element("ul",n3,null);const n23=listBlock(n22,null,S,()=>v0.m1,(v2)=>v2.id,item=>[s0_view1,v0,item],()=>[],()=>v0.m2);const h=[()=>{textValue(n14,(s0_f1(v0.m1)*v0.m3));},()=>{textValue(n18,core.List_length(core.List_filter(v0.m1,(v1)=>v1.done)));},()=>{textValue(n20,core.List_length(v0.m1));},()=>{n23.p();}];for(const f of h)f();return {h,set:(a0)=>{v0=a0;},p(){for(const f of h)f()},get nodes(){return [n0]},d(){live=false;n23.d();n0.remove();}}}
function s0_f6(P,B,S,v0){const a=[s0_view0,v0];return a[0](P,B,S,...a.slice(1))}
let model=s0_f4(undefined),ui;function send(msg,event,node){guarded(()=>{model=s0_f5(msg,model);ui.set(model);enqueue(()=>ui.p())})}
ui=s0_f6(document.body,null,send,model);}
