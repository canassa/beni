// One mode per process bounds the lifetime of Terser's AST and source-map trees.
import fs from 'node:fs';import {createHash} from 'node:crypto';import {minify} from 'terser';
import {prototype} from './prototype.mjs';import {vanilla} from './vanilla.mjs';
import {account,hash} from './measure.mjs';
const here=import.meta.dirname,[name,mode]=process.argv.slice(2),root=here+'/.out/apps/'+name;
const spec=JSON.parse(fs.readFileSync(root+'/spec.json')),started=performance.now();
let chunks,output,kind,compilerRelease=null;
if(mode==='tea'||mode==='direct'){
 const dir=process.env.NATIVE_OUTPUT||here+'/.out/today/'+name+'/'+mode,code=fs.readFileSync(dir+'/_main.mjs','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,''),map=JSON.parse(fs.readFileSync(dir+'/_main.mjs.map'));
 const original=account(code,map,'today');compilerRelease={full:original.full,rendering:original.rendering,runtime:original.runtime};
 output=await minify({'bundle.js':code},{module:true,compress:{passes:2},mangle:true,format:{comments:false},sourceMap:{content:map,asObject:true}});kind='today';
}else{
 if(mode==='vanilla'){const [support,app]=vanilla(spec).split('// APP-BEGIN');chunks={'render-runtime.js':support,'App.js':app};}
 else chunks=prototype(root,mode).chunks;
 output=await minify(chunks,{module:true,compress:{passes:2},mangle:true,format:{comments:false},sourceMap:{asObject:true,includeSources:true}});kind='prototype';
}
const priced=account(output.code,output.map,kind),out=process.env.MEASURE_OUTPUT||here+'/.out/measured/'+name;fs.mkdirSync(out,{recursive:true});
fs.writeFileSync(out+'/'+mode+'.js',output.code);fs.writeFileSync(out+'/'+mode+'.map',JSON.stringify(output.map));
const sourceManifest=fs.existsSync(root+'/source-manifest.json')?JSON.parse(fs.readFileSync(root+'/source-manifest.json')):null;
const sourceFiles=fs.readdirSync(root).filter(x=>x.endsWith('.beni')).sort(),sourceHasher=createHash('sha256');for(const [i,file] of sourceFiles.entries()){if(i)sourceHasher.update('\n');sourceHasher.update(file+'\n');sourceHasher.update(fs.readFileSync(root+'/'+file));}const sourceHash=sourceManifest?.source_sha256||sourceHasher.digest('hex');
const result={name,source_layout:spec.source_layout||'flat',n:spec.n,seed:spec.seed,shape:spec.onlyShape,mode,source_sha256:sourceHash,sha256:hash(output.code),rendering_sha256:priced.rendering_sha256,full:priced.full,rendering:priced.rendering,runtime:priced.runtime,app_alone:priced.app_alone,app_in_rendering_context:priced.app_in_rendering_context,excluded_core:priced.excluded_core,compiler_release:compilerRelease,elapsed_ms:performance.now()-started,peak_rss_kib:process.resourceUsage().maxRSS,source_modules:sourceManifest?.source_modules||sourceFiles.length,source_bytes:sourceManifest?.source_bytes||sourceFiles.reduce((sum,x)=>sum+fs.statSync(root+'/'+x).size,0)};
fs.writeFileSync(out+'/'+mode+'-size.json',JSON.stringify(result)+'\n');console.log(name,mode,priced.rendering.brotli);
