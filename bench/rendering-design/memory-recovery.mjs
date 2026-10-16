// A successful retry supersedes a capped failure only for the exact same
// generated source and compiler. Retain the failed attempt as provenance.
export function memoryRecovery(rows,attempts){
 const recovered=[],unresolved=[];
 for(const attempt of attempts){
  const row=rows.find(r=>r.name===attempt.name&&r.mode===attempt.mode&&r.source_sha256===attempt.input_sha256&&r.compiler_sha256===attempt.compiler_sha256&&attempt.address_space_limit_bytes>0&&r.compiler_address_space_limit_bytes>attempt.address_space_limit_bytes);
  if(row)recovered.push({...attempt,retry:{n:row.n,sha256:row.sha256,brotli:row.rendering.brotli,address_space_limit_bytes:row.compiler_address_space_limit_bytes}});
  else unresolved.push(attempt);
 }
 const latest=new Map();for(const r of unresolved)latest.set(r.family+'/'+r.mode,r);
 return {recovered,stopped:[...latest.values()]};
}
