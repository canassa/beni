import fs from 'node:fs';
const rows=[];
for(const pid of fs.readdirSync('/proc').filter(p=>/^\d+$/.test(p))){
 try{
  const args=fs.readFileSync(`/proc/${pid}/cmdline`,'utf8').replaceAll('\0',' ');
  if(!/chromium|benchmarkRunner\.js/.test(args))continue;
  const status=fs.readFileSync(`/proc/${pid}/status`,'utf8');
  rows.push({pid:Number(pid),args,cpus:status.match(/^Cpus_allowed_list:\s*(.*)$/m)?.[1],ppid:status.match(/^PPid:\s*(.*)$/m)?.[1]});
 }catch(e){if(!['ENOENT','ESRCH','EACCES'].includes(e.code))throw e;}
}
fs.writeFileSync('bench/s8/results/affinity-observed.json',JSON.stringify({time:new Date().toISOString(),rows},null,2)+'\n');
