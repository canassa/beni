import fs from 'node:fs';
export function vanilla(spec){
 const here=import.meta.dirname,used=[...new Set(spec.parts.map(p=>p.shape))],body=fs.readFileSync(here+'/vanilla.js','utf8');
 const factories=used.map(shape=>body.replace('function vanilla(c)',`function vanilla_${shape}(c)`).replace('const {shape,index,seed,variant,depth,step,population}=c;',`const shape=${JSON.stringify(shape)};const {index,seed,variant,depth,step,population}=c;`)).join('\n');
 return `import * as core from '../../../core.mjs';\n`+fs.readFileSync(here+'/reconcile.js','utf8')+'\n'+fs.readFileSync(here+'/runtime.js','utf8')+'\n// APP-BEGIN\n'+factories+'\n'+spec.parts.map(p=>`vanilla_${p.shape}(${JSON.stringify({...p,population:spec.population})});`).join('\n');
}
