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
 const clean=dir=>{if(!fs.existsSync(dir))return;for(const e of fs.readdirSync(dir,{withFileTypes:true})){const f=path.join(dir,e.name);if(e.isDirectory())clean(f);else if(/\.(m?js)(\.map)?$/.test(e.name))fs.unlinkSync(f);}};
 const build=flags=>{clean(path.join(cwd,ref.output));run('npm',['run','build',...flags],cwd);};
 const save=label=>{const dst=path.join(work,`${name}-${label}`);fs.rmSync(dst,{recursive:true,force:true});fs.cpSync(path.join(cwd,ref.output),dst,{recursive:true});};
 build([]);save('stock');
 if(name==='solid'){build(['--','--sourcemap']);save('stock-mapped');}
 for(const edit of ref.adjustments){
  const file=path.join(cwd,edit.file),source=fs.readFileSync(file,'utf8');
  if(!source.includes(edit.before))throw Error(`Missing exact adjustment: ${edit.file}`);
  fs.writeFileSync(file,source.replace(edit.before,edit.after));
 }
 build([]);save('paragraphs');
 if(name==='solid'){build(['--','--sourcemap']);save('paragraphs-mapped');}
 if(name==='solid'){
  build(['--','--inlineDynamicImports']);save('paragraphs-single');
  build(['--','--inlineDynamicImports','--sourcemap']);save('paragraphs-single-mapped');
 }
}
