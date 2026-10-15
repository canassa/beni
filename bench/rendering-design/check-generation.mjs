// After an analysis-only fix, prove that the priced catalogue's emitted source
// is unchanged. This avoids repricing or retiming byte-identical implementations.
import fs from 'node:fs';import {prototype} from './prototype.mjs';
const here=import.meta.dirname,cases=JSON.parse(fs.readFileSync(here+'/.out/cases.json'));let count=0;
for(const c of cases)for(const mode of ['partial','static','cells','local']){const p=prototype(here+'/.out/apps/'+c.name,mode),map=JSON.parse(fs.readFileSync(here+'/.out/measured/'+c.name+'/'+mode+'.map'));for(const [file,source] of Object.entries(p.chunks)){const at=map.sources.indexOf(file);if(at<0||map.sourcesContent[at]!==source)throw Error('Generated source changed: '+c.name+'/'+mode+'/'+file)}count++}
fs.writeFileSync(here+'/results/generation-check.json',JSON.stringify({scope:'Current analysis emits exactly the unminified inputs retained in each measured source map. All four candidates, all 198 apps.',candidates:count,unchanged:true})+'\n');console.log(count,'candidate sources unchanged');
