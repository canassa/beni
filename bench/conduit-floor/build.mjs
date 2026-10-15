// Local reference builds only. Run from the repository root; no remote machines.
import fs from 'node:fs';
import {execFileSync as exec} from 'node:child_process';
import path from 'node:path';
const root=process.cwd(), work=path.join(root,'zig-out/conduit-floor');
const refs=JSON.parse(fs.readFileSync('bench/conduit-floor/references.json'));
const run=(cmd,args,cwd)=>exec(cmd,args,{cwd,stdio:'inherit',env:{...process.env,NODE_OPTIONS:'--openssl-legacy-provider'}});
for(const [name,ref] of Object.entries(refs)){
 const cwd=path.join(work,name);
 if(!fs.existsSync(cwd))run('git',['clone',ref.repository,cwd],root);
 run('git',['checkout',ref.commit],cwd);
 for(const file of ['package.json',...ref.editedFiles])run('git',['restore',file],cwd);
 for(const file of ['package.json','package-lock.json'])fs.copyFileSync(`bench/conduit-floor/references/${name}/${file}`,path.join(cwd,file));
 run('npm',['ci','--ignore-scripts','--no-audit','--no-fund'],cwd);
 const save=label=>{const dst=path.join(work,`${name}-${label}`);fs.rmSync(dst,{recursive:true,force:true});fs.cpSync(path.join(cwd,ref.output),dst,{recursive:true});};
 run('npm',['run','build'],cwd);save('stock');
 if(name==='solid'){run('npm',['run','build','--','--sourcemap'],cwd);save('stock-mapped');}
 for(const edit of ref.adjustments){
  const file=path.join(cwd,edit.file),source=fs.readFileSync(file,'utf8');
  if(!source.includes(edit.before))throw Error(`Missing exact adjustment: ${edit.file}`);
  fs.writeFileSync(file,source.replace(edit.before,edit.after));
 }
 run('npm',['run','build'],cwd);save('paragraphs');
 if(name==='solid'){run('npm',['run','build','--','--sourcemap'],cwd);save('paragraphs-mapped');}
 if(name==='solid'){
  run('npm',['run','build','--','--inlineDynamicImports'],cwd);save('paragraphs-single');
  run('npm',['run','build','--','--inlineDynamicImports','--sourcemap'],cwd);save('paragraphs-single-mapped');
 }
}
