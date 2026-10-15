// Two platforms, 20 independent pages/message, actual release bundles.
import {createServer} from 'node:http';
import fs from 'node:fs';
import {resolve} from 'node:path';
import {loadavg} from 'node:os';
import {launch} from '../ui/lib/cdp.mjs';
const dir='bench/s8/results';
const driver=fs.readFileSync('tests/browser/driver.mjs','utf8');
const prelude=driver.slice(driver.indexOf('function prelude()'),driver.indexOf('// ---------------------------------------------------------------------------',driver.indexOf('function prelude()')));
const builds=JSON.parse(fs.readFileSync(`${dir}/app-builds.json`));
const subjects=['tea','direct'];
const server=createServer((req,res)=>{
 res.setHeader('Cross-Origin-Opener-Policy','same-origin');res.setHeader('Cross-Origin-Embedder-Policy','require-corp');
 if(req.url==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><body>');return}
 const file=resolve('zig-out/s8','.'+new URL(req.url,'http://localhost').pathname);
 if(!file.startsWith(resolve('zig-out/s8')+'/')||!fs.existsSync(file)){res.writeHead(404).end();return}
 res.setHeader('Content-Type','text/javascript');res.end(fs.readFileSync(file));
});
await new Promise(r=>server.listen(0,'127.0.0.1',r));
const origin=`http://127.0.0.1:${server.address().port}`;
const browser=await launch();
const ops=[
 {app:'todomvc',name:'add at 100',event:'keydown',selector:'#new-todo',key:'Enter',clear:false},
 {app:'todomvc',name:'toggle at 100',event:'click',selector:'.todo-list>li:nth-child(1)>div>input',endEvent:'change',clear:false},
 {app:'todomvc',name:'clear at 100',event:'click',selector:'#clear-completed',clear:true},
 {app:'sternhalma',name:'choose two players',event:'click',selector:'.items-center>button:nth-child(1)'},
 {app:'sternhalma',name:'new game',event:'click',selector:'button.bg-gray-200',playing:true},
];
const result={started:new Date().toISOString(),chrome:browser.version,samples:20,method:'20 fresh pages per platform/message. Capture to eight microtasks after final event; unthrottled real CDP input. Driver prelude/virtual clock, no CSS, no forced GC. Setup outside timing. TodoMVC seeds 100 todos, six toggle warmups; Sternhalma measures native selection/reset, not synthetic drag. DOM/title/property/error transcript comparison after each timed message.',builds:builds.apps.map(({app,platform,sha256,status})=>({app,platform,sha256,status})),rows:[]};
const settle='async()=>{for(let i=0;i<8;i++)await Promise.resolve()}';
const call=(fn,arg)=>`__s8.${fn}(${arg===undefined?'':JSON.stringify(arg)})`;
try{
 for(const op of ops){
  let oracle=null;
  for(let sample=0;sample<20;sample++)for(let k=0;k<subjects.length;k++){
   const subject=subjects[(sample+k)%subjects.length];
   if(!builds.apps.find(b=>b.app===op.app&&b.platform===subject&&b.status===0))throw Error('Required subject unavailable');
   const page=await browser.newPage(origin+'/');
   try{
    await page.eval(`(()=>{${prelude}\nglobalThis.__s8={prelude,load,step,settle,serialise};comments=false;prelude();})()`);
    if(op.app==='todomvc'){
     const todos=Array.from({length:100},(_,i)=>(op.clear&&i<50?'1':'0')+'todo '+i).join('\n');
     await page.eval(`localStorage.setItem('todos-beni',${JSON.stringify(todos)});location.hash='#/';`);
    }
    await page.eval(call('load',{url:`${origin}/${op.app}-${subject}/_main.mjs`,runtime:null}));await page.eval(call('settle'));
    if(op.playing){await page.eval(call('step',{command:'click',selector:'.items-center>button:nth-child(1)'}));await page.eval(call('settle'));}
    if(op.app==='todomvc'){
     await page.eval(`(async()=>{for(let i=0;i<6;i++){document.querySelector('.todo-list>li:nth-child(1)>div>input').click();await (${settle})();}})()`);
     if(op.key){await page.eval(`document.querySelector('#new-todo').focus()`);await page.send('Input.insertText',{text:'added'});await page.eval(call('settle'));}
    }
    // The fixture's animation frames are virtual; settle setup without awaiting one.
    await page.eval(call('settle'));
    let point;
    if(!op.key){point=await page.locate(`document.querySelector(${JSON.stringify(op.selector)})`);await page.waitFor(`document.elementFromPoint(${point.x},${point.y})===document.querySelector(${JSON.stringify(op.selector)})`);}
    await page.eval(`(()=>{window.__done=false;let start;addEventListener(${JSON.stringify(op.event)},()=>{start=performance.now()},{capture:true,once:true});addEventListener(${JSON.stringify(op.endEvent??op.event)},()=>{let n=8;const finish=()=>{if(--n)queueMicrotask(finish);else{window.__ms=performance.now()-start;window.__done=true}};queueMicrotask(finish)},{once:true})})()`);
    if(op.key){await page.send('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});await page.send('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13,nativeVirtualKeyCode:13});}else await page.press(point);
    await page.waitFor('__done');
    const ms=await page.eval('__ms');await page.eval(call('settle'));
    const state=await page.eval(`({body:__s8.serialise(false),title:document.title,errors:__beniHarness.errors,rows:document.querySelectorAll('.todo-list>li').length,completed:document.querySelectorAll('.todo-list>li.completed').length,storage:localStorage.getItem('todos-beni'),selectionButtons:document.querySelectorAll('.items-center>button').length,resetButtons:document.querySelectorAll('button.bg-gray-200').length})`);
    if(state.errors.length)throw Error(JSON.stringify(state.errors));
    if(op.app==='todomvc'&&(state.rows!==(op.key?101:op.clear?50:100)||(!op.key&&!op.clear&&state.completed!==1)))throw Error('Wrong TodoMVC result '+JSON.stringify(state));
    if(op.app==='sternhalma'&&(op.playing?state.selectionButtons!==4||state.resetButtons!==0:state.resetButtons!==1))throw Error('Wrong Sternhalma transition '+JSON.stringify(state));
    if(op.app==='todomvc'&&state.storage.split('\n').length!==state.rows)throw Error('Persistence did not settle');
    const signature=JSON.stringify(state);
    if(oracle===null)oracle=signature;else if(oracle!==signature)throw Error('Platform transcript mismatch '+op.name);
    result.rows.push({app:op.app,operation:op.name,subject,sample,ms,load:loadavg()[0]});
    fs.writeFileSync(`${dir}/apps-timing.json`,JSON.stringify(result,null,2)+'\n');
   }finally{await page.close()}
  }
  console.log(op.app,op.name,'complete');
 }
}finally{result.finished=new Date().toISOString();fs.writeFileSync(`${dir}/apps-timing.json`,JSON.stringify(result,null,2)+'\n');await browser.close();await new Promise(r=>server.close(r));}
