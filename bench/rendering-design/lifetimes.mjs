import fs from 'node:fs';import {here,openBrowser,snapshotFunction} from './browser.mjs';
const b=await openBrowser(),rows=[];const errors=[];b.browser.on(m=>{if(m.method==='Runtime.exceptionThrown'||m.method==='Runtime.consoleAPICalled'&&m.params.type==='error')errors.push(m.params)});
try{for(const shape of ['list','modal','tabs'])for(const mode of ['tea','direct','vanilla','partial','static','cells','local',...(shape==='list'?['solid']:[])]){errors.length=0;const page=await b.page(shape+'-17-1',mode);try{
 const result=await page.eval(`(async()=>{${snapshotFunction};const tick=()=>new Promise(r=>setTimeout(r,0)),snapshot=()=>JSON.stringify(walk(document.querySelector('section[data-shape]')));let stale;
 if(${JSON.stringify(shape)}==='list'){const row=document.querySelector('[data-row="1"]');stale=row.querySelectorAll('button')[1];row.querySelectorAll('button')[2].click();await tick();}
 else if(${JSON.stringify(shape)}==='modal'){document.querySelector('[id$="-open"]').click();await tick();stale=document.querySelector('[id$="-draft"]');document.querySelector('[id$="-close"]').click();await tick();}
 else {document.querySelector('[id$="-choose-1"]').click();await tick();stale=document.querySelector('[id$="-draft"]');document.querySelector('[id$="-choose-0"]').click();await tick();}
 const before=snapshot();if(stale.tagName==='INPUT'){stale.value='stale mutation';stale.dispatchEvent(new Event('input',{bubbles:true}))}else stale.click();await tick();const after=snapshot();
 // Reopen the branch: an invisible stale write must not appear later.
 if(${JSON.stringify(shape)}==='tabs'){document.querySelector('[id$="-choose-1"]').click();await tick();if(document.querySelector('[id$="-draft"]').value==='stale mutation')throw Error('stale branch action escaped');}
 return {unchanged:before===after,detached:!stale.isConnected};})()`);rows.push({shape,mode,...result,errors:errors.slice()});console.log(shape,mode,result.unchanged?'passed':'FAILED');
 }catch(e){rows.push({shape,mode,error:String(e),errors:errors.slice()})}finally{await page.close()}}
 fs.writeFileSync(here+'/results/lifetimes.json',JSON.stringify({browser:b.browser.version,observations:rows},null,2)+'\n');}finally{await b.close()}
