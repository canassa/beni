// Exact readable source excerpts for the profiled editor-message comparison.
import {readFileSync,writeFileSync} from 'node:fs';
import {createRequire} from 'node:module';
const require=createRequire(import.meta.url);
const acorn=require('../ui/apps/solid1/node_modules/acorn');
const [before,after,tea,out]=process.argv.slice(2);
if(!out)throw new Error('Expected three development Main.mjs paths and an output JSON path');
function nodes(source){const into=[];const walk=n=>{if(!n||typeof n!=='object')return;if(n.type)into.push(n);for(const v of Object.values(n))if(Array.isArray(v))v.forEach(walk);else if(v&&typeof v==='object')walk(v);};walk(acorn.parse(source,{ecmaVersion:'latest',sourceType:'module'}));return into;}
const sources=[before,after,tea].map(f=>readFileSync(f,'utf8'));
const trees=sources.map(nodes);
const handler=(i)=>{const n=trees[i].find(n=>n.type==='VariableDeclarator'&&n.id.name?.includes('$hGotEditorMsg$EnteredTitle$'));if(!n)throw new Error('Missing editor handler');return sources[i].slice(n.start,n.end);};
const decl=trees[2].find(n=>n.type==='VariableDeclarator'&&n.id.name==='Main$update');
const arm=trees[2].find(n=>n.type==='SwitchCase'&&n.test?.value==='GotEditorMsg'&&decl.start<n.start&&decl.end>n.end);
if(!arm)throw new Error('Missing tea editor arm');
writeFileSync(out,JSON.stringify({before:handler(0),after:handler(1),tea:sources[2].slice(arm.start,arm.end)},null,2)+'\n');
