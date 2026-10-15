import fs from 'node:fs';import {createHash} from 'node:crypto';
import {here,openBrowser,actions,snapshotFunction} from './browser.mjs';
const hash=s=>createHash('sha256').update(s).digest('hex');
const b=await openBrowser(),rows=[],errors=[];b.browser.on(m=>{if(m.method==='Runtime.exceptionThrown')errors.push(m.params.exceptionDetails.exception?.description||m.params.exceptionDetails.text)});
const cases=JSON.parse(fs.readFileSync(here+(process.env.CASES_FILE||'/out/cases.json'))).filter(c=>!process.env.CASE||process.env.CASE.split(',').includes(c.name));
const output=here+'/results/validation'+(process.env.RESULT_SUFFIX||'')+'.json';
try{for(const c of cases){
 const spec=JSON.parse(fs.readFileSync(here+'/out/apps/'+c.name+'/spec.json'));let expected;
 const modes=process.env.MODES?.split(',')||['tea','direct','vanilla','partial','static','cells','local',...(['list','form'].includes(c.shape)?['solid']:[])];
 for(const mode of modes){errors.length=0;const page=await b.page(c.name,mode);let result;try{
  result=await page.eval(`(async()=>{${snapshotFunction};const actions=${JSON.stringify(actions)},parts=${JSON.stringify(spec.parts)},all=[...document.querySelectorAll('section[data-shape]')];if(all.length!==parts.length)throw Error('mount count '+all.length);const transcript=[all.map(walk)],identity=[];const selected=${JSON.stringify(c.n===1||c.shape===null&&c.n===32?spec.parts.map(p=>p.index):[0,c.n-1].filter((x,i,a)=>a.indexOf(x)===i))};
  for(const index of selected){const section=all[index],shape=parts[index].shape;for(const [kind,selector,arg] of actions[shape]){const before=new Map([...section.querySelectorAll('[data-row]')].map(n=>[n.dataset.row,n])),n=section.querySelectorAll(selector)[kind==='click'?(arg||0):0];if(!n)throw Error('missing '+index+' '+selector);if(kind==='input'){n.value=arg;n.dispatchEvent(new Event('input',{bubbles:true}));}else n.click();await new Promise(r=>setTimeout(r,0));if(shape!=='filter')for(const row of section.querySelectorAll('[data-row]'))if(before.has(row.dataset.row)&&before.get(row.dataset.row)!==row)identity.push(index+':'+row.dataset.row);transcript.push([index,kind,selector,walk(section)]);}
  // Three events before the render microtask: stale closures must read current state.
  if(['list','table','summary'].includes(shape)){const edit=section.querySelectorAll('[data-row="1"] button')[1];edit.click();edit.click();edit.click();await new Promise(r=>setTimeout(r,0));transcript.push([index,'batched-edit',walk(section)]);}}
  transcript.push(all.map(walk));return {transcript,identity};})()`);
  const digest=hash(JSON.stringify(result.transcript));if(mode==='tea')expected=digest;
  const row={name:c.name,mode,sha256:hash(fs.readFileSync(here+`/out/${mode==='solid'?'solid':'measured'}/${c.name}/${mode}.js`)),observations:result.transcript.length,transcript_sha256:digest,matches_tea:digest===expected,identity_failures:result.identity.length,errors:errors.slice()};rows.push(row);
  if(mode==='tea'||!row.matches_tea||row.errors.length||row.identity_failures){fs.mkdirSync(here+'/out/validation',{recursive:true});fs.writeFileSync(here+`/out/validation/${c.name}-${mode}.json`,JSON.stringify(result,null,2));if(mode!=='tea'||row.errors.length||row.identity_failures)console.log(c.name,mode,'FAIL',row.errors[0]?.slice(0,100)||'DOM/identity');}
 }catch(e){rows.push({name:c.name,mode,error:String(e),errors:errors.slice()});console.log(c.name,mode,'ERROR',String(e).slice(0,160));}finally{await page.close();}}
 fs.writeFileSync(output,JSON.stringify({browser:b.browser.version,scope:'All mounts; all messages on first/last instances, every instance of mixed N32; batched list edits; retained row DOM identity. Full minified bundles.',observations:rows},null,2)+'\n');console.log(c.name,'done');
}}finally{await b.close();}
