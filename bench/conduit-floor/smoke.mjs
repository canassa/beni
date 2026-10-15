// Offline startup/route probes, not a RealWorld conformance suite or timing run.
import fs from 'node:fs';
import {createServer} from 'node:http';
import {gunzipSync} from 'node:zlib';
import {launch,sleep} from '../ui/lib/cdp.mjs';
const dir='bench/conduit-floor/results',manifest=JSON.parse(fs.readFileSync(`${dir}/manifest.json`));
function prelude(){
 window.errors=[];window.requests=[];localStorage.clear();
 window.addEventListener('error',e=>window.errors.push(e.message));
 window.addEventListener('unhandledrejection',e=>window.errors.push(String(e.reason)));
 const user={username:'floor',email:'floor@example.com',token:'fixture-token',bio:'bio',image:''};
 const author={username:'author',bio:'bio',image:'',following:false};
 const article={slug:'floor-article',title:'Floor title',description:'description',body:'first paragraph\n\nsecond paragraph',tagList:['floor'],createdAt:'2026-01-01T00:00:00Z',updatedAt:'2026-01-01T00:00:00Z',favorited:false,favoritesCount:1,author};
 if(location.search.includes('auth')){localStorage.setItem('jwt',user.token);localStorage.setItem('auth',JSON.stringify(user));}
 window.fetch=async url=>{
  const u=new URL(url,location.href);window.requests.push(u.pathname+u.search);
  const p=u.pathname.replace(/^\/api/,'').replace(/\/{2,}/g,'/').replace(/\/$/,'');
  const data=p==='/user'?{user}:p==='/tags'?{tags:['floor']}:p.endsWith('/comments')?{comments:[]}:p.startsWith('/profiles/')?{profile:author}:p==='/articles'||p==='/articles/feed'?{articles:[article],articlesCount:21}:{article};
  return new Response(JSON.stringify(data),{status:200,headers:{'Content-Type':'application/json'}});
 };
}
const server=createServer((req,res)=>{
 const u=new URL(req.url,'http://localhost'),[subject,file]=u.pathname.slice(1).split('/');
 if(!(subject in manifest.subjects)){res.writeHead(404);res.end();return;}
 if(!file){
  const vanilla=subject.startsWith('vanilla'),body=vanilla?'<c-nav></c-nav><div class="home-page"><router-outlet></router-outlet></div><c-footer></c-footer>':'';
  res.setHeader('Content-Type','text/html');res.end(`<!doctype html><html><head><script>(${prelude.toString()})();</script></head><body>${body}<script ${vanilla?'defer':'type="module"'} src="/${subject}/${vanilla?'bundle.js':'index.js'}"></script></body></html>`);return;
 }
 if(!manifest.subjects[subject].includes(file)){res.writeHead(404);res.end();return;}
 res.setHeader('Content-Type','application/javascript');res.end(gunzipSync(fs.readFileSync(`${dir}/${subject}--${file}.gz`)));
});
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve));
const browser=await launch(),rows=[];
try{
 for(const subject of Object.keys(manifest.subjects).filter(s=>!s.startsWith('beni'))){
  for(const route of ['home','article','editor','favorite']){
   const hash=route==='home'||route==='favorite'?'#/':route==='article'?'#/article/floor-article':'#/editor';
   const page=await browser.newPage(`http://127.0.0.1:${server.address().port}/${subject}/${route==='editor'||route==='favorite'?'?auth':''}${hash}`);
   const predicate=route==='editor'?'!!document.querySelector("textarea")':'document.body.textContent.includes("Floor title")';
   const start=Date.now();while(!await page.eval(predicate)&&Date.now()-start<3000)await sleep(20);
   if(route==='favorite'){
    await page.eval(`document.querySelector('.article-preview button')?.click()`);
    await sleep(40);
   }
   const record=await page.eval(`({visible:${predicate},text:document.body.textContent,requests:window.requests,errors:window.errors,inputs:[...document.querySelectorAll('input,textarea')].map(n=>({tag:n.tagName,placeholder:n.placeholder,value:n.value}))})`);
   rows.push({subject,route,...record});await page.close();
  }
 }
}finally{await browser.close();server.close();}
fs.writeFileSync(`${dir}/smoke.json`,JSON.stringify({chrome:browser.version,warning:'Limited route startup with fixture fetch responses, no CSS, no performance or full parity claim.',rows},null,2)+'\n');
console.log(rows.map(({subject,route,visible,errors})=>({subject,route,visible,errors})));
