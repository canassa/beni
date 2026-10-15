import {mkdirSync,writeFileSync} from 'node:fs';
import {application,shapes,counts,seeds} from './catalogue.mjs';
const here=import.meta.dirname;
export function writeApp(app,name) {
 const root=`${here}/out/apps/${name}`;mkdirSync(root,{recursive:true});
 writeFileSync(root+'/Main.beni',app.source);
 for(const p of app.parts)writeFileSync(root+`/Shape${p.index}.beni`,p.source);
 writeFileSync(root+'/spec.json',JSON.stringify({...app,source:undefined,parts:app.parts.map(({source,...p})=>p)},null,2)+'\n');
 return root;
}
if(process.argv[1]===import.meta.filename){
 const smoke=process.argv.includes('--smoke');
 const cases=[];
 for(const shape of [null,...shapes])for(const seed of smoke?[17]:seeds)for(const n of smoke?[1]:counts){
  const app=application(n,seed,shape),name=`${shape||'mixed'}-${seed}-${n}`;
  cases.push({name,path:writeApp(app,name),n,seed,shape});
 }
 writeFileSync(here+'/out/cases.json',JSON.stringify(cases,null,2)+'\n');
 console.log(`Generated ${cases.length} actual TEA apps`);
}
