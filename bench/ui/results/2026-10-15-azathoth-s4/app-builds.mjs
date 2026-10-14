import {spawnSync} from 'node:child_process';
import {mkdirSync,writeFileSync} from 'node:fs';
import {homedir} from 'node:os';
const root=homedir()+'/src/github.com/canassa/beni';
const out=root+'/bench/ui/results/2026-10-15-azathoth-s4';
mkdirSync(out,{recursive:true});
const apps={Conduit:['examples/conduit','src'],BikeWars:['examples/bike-wars','src'],Sternhalma:['examples/sternhalma','src'],'TodoMVC-full':['.','tests/corpus/browser/tea/TodoMVC.beni'],'TodoMVC-routing':['.','tests/corpus/browser/direct/TodoRouting.beni'],'TodoMVC-sandbox':['.','bench/todomvc/apps/beni/Sandbox.beni']};
const r={};
for (const [name,[cwd,src]] of Object.entries(apps)) {
 const command=[root+'/zig-out/bin/beni','build','--platform=browser-direct','--release','--no-cache','--diagnostics=json','--out=/tmp/beni-s4-app-'+name,src];
 const p=spawnSync(command[0],command.slice(1),{cwd:root+'/'+cwd,encoding:'utf8'});
 r[name]={command,cwd,exit:p.status,stdout:p.stdout,stderr:p.stderr};
 console.log(name,p.status,p.stderr.slice(0,350));
}
writeFileSync(out+'/app-builds.json',JSON.stringify(r,null,2)+'\n');
