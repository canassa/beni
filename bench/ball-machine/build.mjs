// Build the actual sample, with one fixed RNG seed for repeatable workloads.
import {spawnSync} from 'node:child_process';
import {cpSync,mkdirSync,readFileSync,readdirSync,writeFileSync} from 'node:fs';
import {resolve,join} from 'node:path';
import {brotliCompressSync,constants} from 'node:zlib';
const arg=(n,d)=>process.argv.find(x=>x.startsWith(`--${n}=`))?.slice(n.length+3)??d;
const beni=resolve(arg('beni','zig-out/safe-llvm/bin/beni'));
const root=resolve(arg('out','zig-out/bench/ball-machine'));
const source=arg('source','tests/corpus/browser/tea/BallMachine');
mkdirSync(root,{recursive:true});
const project=join(root,'source');mkdirSync(project,{recursive:true});
for(const f of readdirSync(source).filter(x=>x.endsWith('.beni'))) cpSync(join(source,f),join(project,f));
const physics=join(project,'Physics.beni');
const original=readFileSync(physics,'utf8');
const needle='Random.initialSeed (Time.toMillis (Time.now ⊤))';
if(original.split(needle).length!==2) throw Error('expected one initial RNG seed');
writeFileSync(physics,original.replace(needle,'Random.initialSeed 20261026'));
const gradient=join(root,'source-gradient');cpSync(project,gradient,{recursive:true});
const view=join(gradient,'View.beni');let drawing=readFileSync(view,'utf8');
const dynamicFilter=/\s*filter=\{if b\.stage == Done[\s\S]*?\n\s*\}/;
const gradientChanged=dynamicFilter.test(drawing);
if(gradientChanged){
drawing=drawing.replace(dynamicFilter,'');
drawing=drawing.replaceAll('filter="url(#glow)"','');
const marker='    <g transform={"translate(${n1 b.x} ${n1 b.y})"} opacity={n1 opacity}>\n';
if(!drawing.includes(marker))throw Error('missing ball drawing');
drawing=drawing.replace(marker,marker+`        <circle r="15" fill={if b.red then "url(#poolRed)" else "url(#poolOrange)"} opacity={if b.stage == Done || b.dropped && b.stage == Inside then "0.25" else "0"} />
        <circle r="10.5" fill="none" stroke="rgba(183, 156, 255, 0.14)" stroke-width="3" visibility={if b.token then "visible" else "hidden"} />
`);
}else if(!drawing.includes('r="10.5"'))throw Error('unrecognized ball drawing');
writeFileSync(view,drawing);
const runs=[];
function payload(dir){
 const files=readdirSync(dir,{recursive:true}).filter(f=>f.endsWith('.mjs'));
 const buffers=files.map(f=>readFileSync(join(dir,f)));
 return {modules:files.length,raw:buffers.reduce((n,b)=>n+b.length,0),brotli:buffers.reduce((n,b)=>n+brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11}}).length,0)};
}
for(const [name,flags] of [['dev',[]],['release',['--release']],['gradient',[]]]){
 const out=join(root,name);
 const r=spawnSync(beni,['build','--platform=browser-tea','--source-maps',...flags,`--out=${out}`,name==='gradient'?gradient:project],{encoding:'utf8'});
 if(r.status!==0) throw Error(r.stderr);
 cpSync('playground/samples/browser-tea/BallMachine.css',join(out,'style.css'));
 writeFileSync(join(out,'index.html'),'<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><link rel="stylesheet" href="style.css"><script type="module" src="_main.mjs"></script></head><body></body></html>');
 runs.push({name,flags,payload:payload(out)});
}
const version=spawnSync(beni,['version'],{encoding:'utf8'}).stdout.trim();
const revision=spawnSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).stdout.trim();
writeFileSync(join(root,'built.json'),JSON.stringify({revision,version,seed:20261026,source,gradientChanged,runs},null,2)+'\n');
console.log(JSON.stringify({root,version,runs}));
