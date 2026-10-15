// The compiler/build barrier: record prepared bytes, verify them after timing.
import fs from 'node:fs';
import {createHash} from 'node:crypto';
const dir='bench/s8/results';
const sha=p=>createHash('sha256').update(fs.readFileSync(p)).digest('hex');
if(process.argv.includes('--check')){
 const data=JSON.parse(fs.readFileSync(`${dir}/prepared-artifacts.json`));
 for(const [file,hash]of Object.entries(data.files))if(sha(file)!==hash)throw Error('Prepared artifact changed: '+file);
 fs.writeFileSync(`${dir}/artifact-verification.json`,JSON.stringify({verified:new Date().toISOString(),files:Object.keys(data.files).length,compilerSha256:sha(process.env.BENI)},null,2)+'\n');
}else{
 const files={};
 function scan(path){if(!fs.existsSync(path))return;for(const e of fs.readdirSync(path,{withFileTypes:true})){const p=`${path}/${e.name}`;if(e.isDirectory())scan(p);else if(/\.(m?js|css)$/.test(e.name))files[p]=sha(p);}}
 for(const p of ['bench/ui/out','bench/todomvc/out/direct-effects','zig-out/s8','zig-out/conduit-measured/browser-tea-release','zig-out/conduit-measured/browser-direct-release',...['vanillajs','solid','beni-tea','beni-direct'].map(s=>`bench/jfb/work/frameworks/keyed/${s}/dist`)])scan(p);
 files[process.env.BENI]=sha(process.env.BENI);
 const expected=JSON.parse(fs.readFileSync(`${dir}/app-builds.json`)).compilerSha256;
 if(files[process.env.BENI]!==expected)throw Error('Application byte builds and frozen compiler differ');
 for(const p of ['tea','direct'])if(sha(`zig-out/s8/table-${p}/_main.mjs`)!==sha(`bench/ui/out/${p==='tea'?'beni-rel':'beni-direct-rel'}/_main.mjs`))throw Error('UI table differs from frozen compiler build');
 fs.writeFileSync(`${dir}/prepared-artifacts.json`,JSON.stringify({recorded:new Date().toISOString(),compilerSha256:files[process.env.BENI],files},null,2)+'\n');
}
