// Shared admission for research processes, not a benchmark or repository gate.
// CPU slots approximate physical cores; reservations bound concurrent heaps.
import fs from 'node:fs';
import {spawn} from 'node:child_process';
const args=process.argv.slice(2),split=args.indexOf('--');
const options=Object.fromEntries(args.slice(0,split).map(x=>x.replace(/^--/,'').split('=')));
if(split<0||!args[split+1])throw Error('resource-run --memory-mib=N --cpu=N -- command args');
const root=process.env.RESEARCH_RESOURCES||'/tmp/beni-rendering-design-172-resources';
const memory=Number(options['memory-mib']),cpu=Number(options.cpu||1),memoryBudget=Number(process.env.RESEARCH_MEMORY_MIB||26000),cpuBudget=Number(process.env.RESEARCH_CPUS||6);
if(!(memory>0&&memory<=memoryBudget&&cpu>0&&cpu<=cpuBudget))throw Error('Invalid resource reservation');
fs.mkdirSync(root,{recursive:true});
const lock=root+'/mutex',lease=root+'/'+process.pid+'.json',alive=pid=>{if(!(pid>0))return false;try{process.kill(pid,0);return true}catch{return false}};
const writeLease=r=>{fs.writeFileSync(lease+'.tmp',JSON.stringify(r));fs.renameSync(lease+'.tmp',lease)};
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let child,claimed=false,stopping=false;
for(const signal of ['SIGTERM','SIGINT'])process.on(signal,()=>{stopping=true;if(child)child.kill(signal)});
try{
 while(!claimed&&!stopping){
  let fd;
  try{fd=fs.openSync(lock,'wx');fs.writeFileSync(fd,String(process.pid));}
  catch(e){if(e.code!=='EEXIST')throw e;try{const owner=Number(fs.readFileSync(lock,'utf8'));if(!alive(owner)&&Date.now()-fs.statSync(lock).mtimeMs>30000)fs.unlinkSync(lock)}catch{}await sleep(250);continue}
  try{
   let usedMemory=0,usedCpu=0;
   for(const file of fs.readdirSync(root).filter(x=>x.endsWith('.json'))){const path=root+'/'+file,r=JSON.parse(fs.readFileSync(path));if(!alive(r.pid)&&!alive(r.child||-1)){fs.unlinkSync(path);continue}usedMemory+=r.memory;usedCpu+=r.cpu}
   if(usedMemory+memory<=memoryBudget&&usedCpu+cpu<=cpuBudget){writeLease({pid:process.pid,memory,cpu,command:args.slice(split+1)});claimed=true}
  }finally{fs.closeSync(fd);fs.unlinkSync(lock)}
  if(!claimed)await sleep(500);
 }
 if(stopping)process.exitCode=143;
 else{
  child=spawn(args[split+1],args.slice(split+2),{stdio:'inherit'});
  writeLease({pid:process.pid,child:child.pid,memory,cpu,command:args.slice(split+1)});
  const result=await new Promise((resolve,reject)=>{child.on('error',reject);child.on('exit',(code,signal)=>resolve({code,signal}))});
  process.exitCode=result.code??(result.signal==='SIGKILL'?137:143);
 }
}finally{if(claimed)try{fs.unlinkSync(lease)}catch{}}
