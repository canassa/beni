import {refs,fields,localId,ctorName} from './bir.mjs';
const operators={'Basics.add':'+','Basics.sub':'-','Basics.mul':'*','Basics.append':'+','Basics.and':'&&','Basics.or':'||'};
export class Expressions {
 constructor(ir,prefix=''){this.ir=ir;this.prefix=prefix;this.imports=new Set();this.owned=new Set();this.dirtyFields=null;this.views=new Set(ir.declarations.filter(d=>d?.nodes.some(n=>n?.op==='markup')).map(d=>d.id));
  for(let pass=0;pass<ir.declarations.length;pass++)for(const d of ir.declarations.filter(Boolean))if(d.nodes.some(n=>n?.op==='top'&&this.views.has(+n.raw.match(/^top (\d+)/)[1])))this.views.add(d.id);
 }
 name(d){return this.prefix+'f'+d.id;}
 params(d,ids=d.params){return ids.map(id=>d.nodes[id].op==='pat_var'?'v'+localId(d.nodes[id]):'_');}
 constructorValue(n){if(n.op==='import_ctor'){const name=n.raw.split(' ').at(-1);if(name==='Basics.True')return 'true';if(name==='Basics.False')return 'false';throw Error('unsupported imported constructor '+name);}const id=+n.raw.match(/^ctor (\d+)/)[1],c=this.ir.ctors[id];return c.arity?this.prefix+'c'+id:`[${id}]`;}
 pattern(d,id,value){const n=d.nodes[id],r=refs(n.raw);
  if(n.op==='pat_var')return {test:'true',bind:`const v${localId(n)}=${value};`};
  if(n.op==='pat_wild'||n.op==='pat_unit')return {test:'true',bind:''};
  if(n.op==='pat_int'||n.op==='pat_string')return {test:`${value}===${n.raw.slice(n.op.length+1)}`,bind:''};
  if(n.op==='pat_ctor'){
   const c=d.nodes[r[0]],name=ctorName(c);
   if(c.op==='import_ctor'&&(name==='True'||name==='False'))return {test:`${value}===${name.toLowerCase()}`,bind:''};
   const tag=+c.raw.match(/^ctor (\d+)/)[1],parts=r.slice(1).map((p,i)=>this.pattern(d,p,`${value}[${i+1}]`));
   return {test:[`${value}[0]===${tag}`,...parts.map(x=>x.test).filter(x=>x!=='true')].join('&&'),bind:parts.map(x=>x.bind).join('')};
  }
  throw Error('unsupported pattern '+n.raw);
 }
 expression(d,id,env=new Map(),markup=null){
  const n=d.nodes[id],r=refs(n.raw),e=x=>this.expression(d,x,env,markup);
  switch(n.op){
   case 'int':case 'float':case 'string':case 'chunk':return n.raw.slice(n.op.length+1);
   case 'unit':return 'undefined';
   case 'local':return env.get(localId(n))||'v'+localId(n);
   case 'top':return this.name(this.ir.declarations[+n.raw.match(/^top (\d+)/)[1]]);
   case 'ctor':case 'import_ctor':return this.constructorValue(n);
   case 'field_access':return `${e(r[0])}.${n.raw.match(/\.(\w+)$/)[1]}`;
   case 'tuple':case 'list':return '['+r.map(e).join(',')+']';
   case 'record':return '({'+fields(n).map(([k,v])=>k+':'+e(v)).join(',')+'})';
   case 'record_update':{
    const result='({...'+e(r[0])+','+fields(n).map(([k,v])=>k+':'+e(v)).join(',')+'})';
    const root=d.name==='update'&&d.nodes[r[0]].op==='local'&&localId(d.nodes[r[0]])===localId(d.nodes[d.params[1]]);
    if(root&&this.dirtyFields){const mask=fields(n).reduce((m,[k])=>m|(1<<this.dirtyFields.indexOf(k)),0);return `(dirty|=${mask},${result})`;}
    return result;
   }
   case 'lambda':return '('+this.params(d,r.slice(0,-1)).join(',')+')=>'+e(r.at(-1));
   case 'qualified':case 'import_value':{const name=n.raw.split(' ').at(-1);this.imports.add(name);return 'core.'+name.replaceAll('.','_');}
   case 'call':{
    const fn=d.nodes[r[0]],name=fn.raw.replace(/^(qualified|import_value) /,''),args=r.slice(1).map(e);
    if(d.name==='update'&&this.owned.has(id))return 'edit_'+name.slice(5)+'('+args.join(',')+')';
    if(operators[name])return '('+args.join(operators[name])+')';
    if(name==='Basics.not')return '(!'+args[0]+')';
    return e(r[0])+'('+args.join(',')+')';
   }
   case 'method_call':{
    const op=n.raw.match(/\(([^)]+)\)$/)?.[1],js={'==':'===','≠':'!==','<':'<','>':'>','≤':'<=','≥':'>='}[op];
    if(!js)throw Error('unsupported method '+n.raw);
    return '('+e(r[0])+js+e(r[1])+')';
   }
   case 'case':{
    const value=e(r[0]),cases=r.slice(1).map(b=>{const [p,result]=refs(d.nodes[b].raw),pattern=this.pattern(d,p,'z');return `if(${pattern.test}){${pattern.bind}return ${e(result)}}`;});
    return `(()=>{const z=${value};${cases.join('')}throw Error('unreachable pattern')})()`;
   }
   case 'let':{
    const bindings=r.slice(0,-1).map(x=>{const def=d.nodes[x],values=refs(def.raw);return `const v${localId(def)}=${e(values.at(-1))};`;});return `(()=>{${bindings.join('')}return ${e(r.at(-1))}})()`;
   }
   case 'interp':return '('+r.map(x=>'String('+e(x)+')').join('+')+')';
   case 'markup':if(markup)return markup(d,n,env);throw Error('markup needs a view compiler');
   default:throw Error('unsupported expression '+d.name+' '+n.raw);
  }
 }
 constructors(){return Object.values(this.ir.ctors).filter(c=>c.arity).map(c=>`function ${this.prefix}c${c.id}(${Array.from({length:c.arity},(_,i)=>'a'+i)}){return [${c.id},${Array.from({length:c.arity},(_,i)=>'a'+i)}]}`).join('\n');}
 functions(){return this.ir.declarations.filter(d=>d?.kind==='value'&&!this.views.has(d.id)).map(d=>d.params.length?`function ${this.name(d)}(${this.params(d)}){return ${this.expression(d,d.body)}}`:`const ${this.name(d)}=${this.expression(d,d.body)};`).join('\n');}
}
