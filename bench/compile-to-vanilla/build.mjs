import {mkdirSync,writeFileSync,readFileSync} from 'node:fs';
import {brotliCompressSync,gzipSync,constants} from 'node:zlib';
import {createHash} from 'node:crypto';
import {execFileSync} from 'node:child_process';
import {cpus,platform,arch} from 'node:os';
import {minify} from 'terser';
import {generate,modes,families,sizes} from './generate.mjs';
const here=new URL('.',import.meta.url);
export const hash=s=>createHash('sha256').update(s).digest('hex');
export function bytes(code){const b=Buffer.from(code);return {raw:b.length,brotli:brotliCompressSync(b,{params:{[constants.BROTLI_PARAM_QUALITY]:11,[constants.BROTLI_PARAM_SIZE_HINT]:b.length}}).length,gzip:gzipSync(b,{level:9}).length}}
export function fit(points){
 const n=points.length,x=points.reduce((s,p)=>s+p.count,0)/n,y=points.reduce((s,p)=>s+p.brotli,0)/n;
 const slope=points.reduce((s,p)=>s+(p.count-x)*(p.brotli-y),0)/points.reduce((s,p)=>s+(p.count-x)**2,0),intercept=y-slope*x;
 const residuals=points.map(p=>p.brotli-intercept-slope*p.count),ss=residuals.reduce((s,r)=>s+r*r,0),total=points.reduce((s,p)=>s+(p.brotli-y)**2,0);
 return {intercept,slope,r2:total?1-ss/total:1,residuals};
}
const observations=[];
mkdirSync(new URL('out/',here),{recursive:true});
mkdirSync(new URL('results/',here),{recursive:true});
for(const family of families)for(const shape of ['repeated','varied'])for(const mode of modes)for(const count of sizes){
 const name=`${family}-${shape}-${mode}-${count}`,source=generate(family,mode,count,shape==='varied');
 const {code}=await minify(source,{module:true,compress:{passes:2},mangle:true});
 writeFileSync(new URL(`out/${name}.source.js`,here),source);
 writeFileSync(new URL(`out/${name}.js`,here),code);
 observations.push({family,shape,mode,count,name,...bytes(code),sha256:hash(code)});
}
// A second axis changes runtime population without adding feature code.
for(const count of [100,1000,10000])for(const mode of modes){
 const name=`crud-population-${mode}-${count}`,source=generate('crud',mode,1,false,count);
 const {code}=await minify(source,{module:true,compress:{passes:2},mangle:true});
 writeFileSync(new URL(`out/${name}.js`,here),code);
 observations.push({family:'crud',shape:'population',mode,count,name,...bytes(code),sha256:hash(code)});
}
const fits=[];
for(const family of families)for(const shape of ['repeated','varied'])for(const mode of modes){const points=observations.filter(p=>p.family===family&&p.shape===shape&&p.mode===mode);fits.push({family,shape,mode,one:points[0].brotli,last:points.at(-1).brotli,...fit(points)})}
const result={commit:execFileSync('git',['rev-parse','HEAD'],{encoding:'utf8'}).trim(),node:process.version,terser:JSON.parse(readFileSync(new URL('node_modules/terser/package.json',here))).version,host:{platform:platform(),arch:arch(),cpu:cpus()[0].model},generator_sha256:hash(readFileSync(new URL('generate.mjs',here))),options:{module:true,compress:{passes:2},mangle:true,brotli:11,gzip:9},observations,fits};
writeFileSync(new URL('results/sizes.json',here),JSON.stringify(result,null,2)+'\n');
console.log(`Built ${observations.length} pages; sizes and ${fits.length} fits in results/sizes.json`);
