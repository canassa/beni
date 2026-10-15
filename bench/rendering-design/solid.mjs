import fs from 'node:fs';import {build} from 'vite';import solid from '@solidjs/vite-plugin';
import {size,hash,account} from './measure.mjs';
const here=import.meta.dirname;
const cases=JSON.parse(fs.readFileSync(here+(process.env.CASES_FILE||'/.out/cases.json'))).filter(c=>['list','form'].includes(c.shape));
const rows=[];
for(const c of cases){
 const spec=JSON.parse(fs.readFileSync(here+'/.out/apps/'+c.name+'/spec.json'));
 let source=fs.readFileSync(here+'/solid.jsx','utf8').replace('const cases=CASE_CONFIG;',`const cases=${JSON.stringify(spec.parts.map(p=>({...p,population:spec.population})))};`);
 source=source.replace("c.shape==='list'?<List c={c}/>:<Form c={c}/>",c.shape==='list'?'<List c={c}/>':'<Form c={c}/>');
 const out=here+'/.out/solid/'+c.name;fs.mkdirSync(out,{recursive:true});fs.writeFileSync(out+'/main.jsx',source);
 await build({configFile:false,root:here,logLevel:'warn',plugins:[solid()],build:{outDir:out,emptyOutDir:false,sourcemap:true,minify:'terser',terserOptions:{module:true,compress:{passes:2},mangle:true,format:{comments:false}},modulePreload:false,rollupOptions:{input:out+'/main.jsx',output:{entryFileNames:'solid.js',format:'es',codeSplitting:false}}}});
 const code=fs.readFileSync(out+'/solid.js','utf8').replace(/\/\/# sourceMappingURL=.*\n?$/,''),map=JSON.parse(fs.readFileSync(out+'/solid.js.map'));
 // All Solid code here is rendering. No router, fetch, validation or core library.
 const runtimeSources=map.sources.map(s=>s.includes('node_modules/')?'beni:///platforms/solid/runtime.beni':s);
 const priced=account(code,{...map,sources:runtimeSources},'today');delete priced.render;
 rows.push({name:c.name,n:c.n,seed:c.seed,shape:c.shape,mode:'solid',sha256:hash(code),...priced});
 fs.writeFileSync(here+'/results/'+(process.env.RESULT_PREFIX||'')+'solid-sizes.json',JSON.stringify({solid:'2.0.0-rc.9',compiler:'@solidjs/vite-plugin 3.0.0-next.35',observations:rows},null,2)+'\n');
 console.log(c.name,'Solid',priced.rendering.brotli,'B');
}
