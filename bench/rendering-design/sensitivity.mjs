// Diagnostic prices for the explicitly excluded owned-array core operations and
// source-map gaps. These are sensitivity probes, not additive savings or CIs.
import fs from 'node:fs';import {minify} from 'terser';import {units} from './provenance.mjs';import {size} from './measure.mjs';
const here=import.meta.dirname,results=[];
const owned=fs.readFileSync(here+'/core.mjs','utf8').split('// Owned-array forms')[1].split('\n').slice(1).join('\n'),packed=await minify(owned,{module:true,compress:{passes:2},mangle:true});
for(const mode of ['tea','direct','vanilla','partial','static','local','cells']){
 const root=here+'/.out/measured/mixed-17-32/',code=fs.readFileSync(root+mode+'.js','utf8'),map=JSON.parse(fs.readFileSync(root+mode+'.map')),{segs,units:decls}=units(code,map);let gaps=0,total=0;const without=[],withAll=[];
 const spans=segs[0]?.offset>0?[{offset:0,source:'unmapped'},...segs]:segs;let unitIndex=0;
 for(let i=0;i<spans.length;i++){const a=spans[i],end=spans[i+1]?.offset??code.length,text=code.slice(a.offset,end),bytes=Buffer.byteLength(text);total+=bytes;while(unitIndex+1<decls.length&&decls[unitIndex].end<=a.offset)unitIndex++;
  if(a.source==='unmapped'){gaps+=bytes;withAll.push(text)}else if(!a.source.startsWith('core/')){without.push(text);withAll.push(text)}
 }
 results.push({mode,app:'mixed-17-32',unmapped_raw:gaps,full_raw:total,unmapped_percent:100*gaps/total,all_unmapped_excluded:size(without.join('')).brotli,all_unmapped_rendering:size(withAll.join('')).brotli});
}
const report={scope:'All unmapped source-map spans are either excluded or retained as rendering. These alternative classifications are a sensitivity probe, not statistical uncertainty bounds. Prototype spans cannot refer to excluded core because core is external. Owned operations are excluded per the rendering-only brief, but their standalone shipping cost is disclosed.',owned_array_helpers:size(packed.code),observations:results};
fs.writeFileSync(here+'/results/sensitivity.json',JSON.stringify(report,null,2)+'\n');console.log(JSON.stringify(report,null,2));
