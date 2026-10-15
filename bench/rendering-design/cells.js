// Proposed explicit cells: per-binding dynamic dependency tracking. Shared
// implementation; each mounted component owns its cells and observers.
let observing=null;
function cellStore(initial){
 const cells=new Map(Object.entries(initial).map(([k,value])=>[k,{value,readers:new Set()}]));
 const value={};
 for(const [key,cell] of cells)Object.defineProperty(value,key,{enumerable:true,get(){if(observing){cell.readers.add(observing);observing.deps.add(cell)}return cell.value}});
 return {value,set(key,next,force){const cell=cells.get(key);if(force||cell.value!==next){cell.value=next;for(const effect of cell.readers)enqueue(effect)}}};
}
function observeBinding(fn){
 const run=()=>{for(const cell of run.deps)cell.readers.delete(run);run.deps.clear();const previous=observing;observing=run;try{fn()}finally{observing=previous}};
 run.deps=new Set();run();return ()=>{pending.delete(run);for(const cell of run.deps)cell.readers.delete(run);run.deps.clear()};
}
