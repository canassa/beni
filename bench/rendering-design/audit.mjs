// Closed-world preconditions for the experimental BIR lowering. This is not a
// general ownership checker for arbitrary beni programs: unknown roots/calls fail.
import fs from 'node:fs';import {createHash} from 'node:crypto';import {application} from './catalogue.mjs';import {parseBir,analyse} from './bir.mjs';import {ownership} from './ownership.mjs';
const here=import.meta.dirname,hash=s=>createHash('sha256').update(s).digest('hex');
const pure=new Set(['Basics.add','Basics.sub','Basics.mul','Basics.append','Basics.and','Basics.or','Basics.not','List.map','List.range','List.append','List.filter','List.reverse','List.length','List.foldl','List.sortBy','String.fromInt','String.contains','String.length','Int.mod']);
const cases=JSON.parse(fs.readFileSync(here+'/.out/cases.json')),rows=[];
for(const c of cases){const root=here+'/.out/apps/'+c.name,spec=JSON.parse(fs.readFileSync(root+'/spec.json')),expected=application(spec.n,spec.seed,spec.onlyShape,spec.population);
 // The recognized source root is a sandbox of disjoint component models. It
 // never exports/stores old models, shares arrays between instances, or runs effects.
 if(fs.readFileSync(root+'/Main.beni','utf8')!==expected.source)throw Error('Unrecognized app root '+c.name);
 let owned=0,edges=0,arms=0;const modules=[];
 for(const p of spec.parts){const source=fs.readFileSync(root+`/Shape${p.index}.beni`,'utf8');if(source!==expected.parts[p.index].source)throw Error('Source/spec mismatch');const bir=fs.readFileSync(root+`/Shape${p.index}.bir`,'utf8'),ir=parseBir(bir);
  for(const d of ir.declarations.filter(Boolean))for(const n of d.nodes.filter(Boolean))if(['qualified','import_value'].includes(n.op)&&!pure.has(n.raw.split(' ').at(-1)))throw Error('Unknown or effectful primitive '+n.raw);
  const a=analyse(ir),proofs=ownership(ir);owned+=proofs.length;edges+=a.edges.length;arms+=a.cases.length;modules.push({module:`Shape${p.index}`,source_sha256:hash(source),bir_sha256:hash(bir),write_sets:a.cases.map(x=>({message:x.name,writes:x.writes})),owned_operations:proofs});
 }
 rows.push({name:c.name,root_sha256:hash(expected.source),modules,owned_operations:owned,dependency_edges:edges,update_arms:arms});
}
fs.writeFileSync(here+'/results/source-audit.json',JSON.stringify({scope:'Admission requires exact equality with generated Main and component source plus a pure-primitive allowlist. Disjoint ownership and absence of retained external snapshots follow from this construction, not general root analysis. Read/write/operation witnesses are derived from real compiler BIR. This is not a general beni ownership proof.',observations:rows},null,2)+'\n');console.log('Audited',rows.length,'closed source roots');
