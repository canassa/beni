// Isolated lookup kernels in Chrome; never presented as application latency.
import fs from 'node:fs';
import {gunzipSync} from 'node:zlib';
import {createRequire} from 'node:module';
import {launch} from '../ui/lib/cdp.mjs';
const require=createRequire(import.meta.url),acorn=require('../ui/apps/solid1/node_modules/acorn');
const s=gunzipSync(fs.readFileSync('bench/direct-bytes/results/conduit-direct-baseline.mjs.gz')).toString();
let entries;
function walk(n){if(!n?.type)return;if(n.type==='ArrayExpression'&&n.elements.length>300&&n.elements.every(e=>e?.type==='ArrayExpression'&&e.elements.length===2&&typeof e.elements[1]?.value==='string'&&/^[01]+$/.test(e.elements[1].value)))entries=n.elements.map(e=>e.elements.map(x=>x.value));for(const v of Object.values(n)){if(Array.isArray(v))v.forEach(walk);else if(v?.type)walk(v)}}walk(acorn.parse(s,{ecmaVersion:'latest',sourceType:'module'}));
const browser=await launch({chrome:process.env.CHROME??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'});
try{
 const page=await browser.newPage('about:blank');
 const data=await page.eval(`(()=>{
 const entries=${JSON.stringify(entries)},keys=entries.map(e=>e[0]),table=Object.fromEntries(entries),short=Object.fromEntries(entries.map((e,i)=>[i.toString(36),e[1]])),shortKeys=keys.map((_,i)=>i.toString(36));
 const strings=entries.map(e=>e[1]),limbs=strings.map(s=>{let a=[];for(let i=0;i<s.length;i+=32){let w=0;for(let j=0;j<32;j++)if(s[i+j]==='1')w=(w|2**j)>>>0;a.push(w)}return a});
 const run={strings:()=>{let c=0;for(let i=0;i<2000000;i++)c+=strings[i%331].charAt(i%97)==='1';return c},limbs:()=>{let c=0;for(let i=0;i<2000000;i++){let k=i%97;c+=(limbs[i%331][k>>>5]>>>(k&31)&1)===1}return c},longKeys:()=>{let c=0;for(let i=0;i<2000000;i++)c+=table[keys[i%331]].length;return c},shortKeys:()=>{let c=0;for(let i=0;i<2000000;i++)c+=short[shortKeys[i%331]].length;return c}};
 for(let i=0;i<5;i++)for(const f of Object.values(run))f();
 const samples=[];
 for(let round=0;round<20;round++)for(const name of (round%2?Object.keys(run).reverse():Object.keys(run))){let start=performance.now(),check=run[name]();samples.push({round,name,ms:performance.now()-start,check})}
 return samples;
 })()`);
 fs.writeFileSync('bench/direct-bytes/results/speed.json',JSON.stringify({chrome:browser.version,iterations:2000000,warmups:5,scope:'lookup kernels only; no application speed or parity claim',samples:data},null,2)+'\n');console.log(browser.version);
}finally{await browser.close()}
