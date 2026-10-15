import {readFileSync,writeFileSync,readdirSync} from 'node:fs';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
const here=new URL('.',import.meta.url),hash=b=>createHash('sha256').update(b).digest('hex');
const sources=Object.fromEntries(readdirSync(here).filter(n=>/\.(mjs|js|py|json)$/.test(n)).map(n=>[n,hash(readFileSync(new URL(n,here)))]));
const results=Object.fromEntries(readdirSync(new URL('results/',here)).filter(n=>n!=='manifest.json').map(n=>[n,hash(readFileSync(new URL('results/'+n,here)))]));
const references=Object.fromEntries(['../ui/apps/solid2/package-lock.json','../ui/apps/solid2/src/bench.jsx','../ui/apps/solid2/src/static.jsx','../ui/apps/micro/p2/static.js','../ui/lib/benchmarks.mjs','../ui/lib/cdp.mjs','../ui/lib/trace.mjs'].map(p=>[p,hash(readFileSync(new URL(p,here)))]));
writeFileSync(new URL('results/manifest.json',here),JSON.stringify({base:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),node:process.version,sources,results,references},null,2)+'\n');
console.log('Recorded source/result/reference hashes');
