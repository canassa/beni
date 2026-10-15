import fs from 'node:fs';import http from 'node:http';import path from 'node:path';
import {launch} from '../ui/lib/cdp.mjs';
export const here=import.meta.dirname;
export async function openBrowser(){
 const server=http.createServer((req,res)=>{const u=new URL(req.url,'http://localhost');if(u.pathname==='/page'){res.setHeader('Content-Type','text/html');res.end(`<html><body><script type="module" src="${u.searchParams.get('script')}"></script></body></html>`);return;}const file=path.resolve(here,'.'+u.pathname);if(!file.startsWith(here+'/')||!fs.existsSync(file)){res.writeHead(404);res.end();return;}res.setHeader('Content-Type',/\.(m?js)$/.test(file)?'text/javascript':'application/json');res.end(fs.readFileSync(file));});
 await new Promise(r=>server.listen(0,'127.0.0.1',r));
 const browser=await launch({chrome:process.env.CHROME||'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',taskset:process.env.CHROME_CPU||null});
 return {browser,page:(name,mode)=>browser.newPage(`http://127.0.0.1:${server.address().port}/page?script=/out/${mode==='solid'?'solid':'measured'}/${name}/${mode}.js`),close:async()=>{await browser.close();server.close();}};
}
export const actions={
 list:[['click','[id$="-add"]'],['click','[data-row="1"] button',0],['click','[data-row="1"] button',1],['click','[id$="-reverse"]'],['click','[data-row="2"] button',2]],
 form:[['input','[id$="-name"]','a'],['input','[id$="-name"]','Rejected#'],['input','[id$="-name"]','Alice 🌈'],['input','[id$="-email"]','a@b'],['click','[id$="-submit"]'],['click','[id$="-reset"]']],
 tabs:[['click','[id$="-choose-1"]'],['input','[id$="-draft"]','hello'],['click','[id$="-choose-0"]'],['click','[id$="-read"]']],
 nested:[['click','article button',0],['click','article button',1],['click','[id$="-collapse"]'],['click','[id$="-collapse"]']],
 thread:[['click','article[data-comment="2"] > button'],['input','article[data-comment="2"] > input','Changed 🌈'],['click','[id$="-collapse"]'],['click','[id$="-collapse"]']],
 cluster:[['click','[id$="-increment"]'],['click','[id$="-toggle"]'],['click','[id$="-reset"]']],
 table:[['click','[id$="-sort"]'],['click','[data-row="1"] button',0],['click','[data-row="1"] button',1],['click','[id$="-reverse"]'],['click','[id$="-add"]'],['click','[data-row="2"] button',2]],
 modal:[['click','[id$="-open"]'],['input','[id$="-draft"]','Saved text'],['click','[id$="-confirm"]'],['click','[id$="-open"]'],['click','[id$="-close"]']],
 filter:[['input','[id$="-query"]','Item 1'],['click','[data-row="1"] button',0],['click','[data-row="1"] button',1],['click','[id$="-onlydone"]'],['input','[id$="-query"]',''],['click','[id$="-onlydone"]'],['click','[id$="-add"]'],['click','[id$="-reverse"]'],['click','[data-row="2"] button',2]],
 summary:[['click','[id$="-rate"]'],['click','[data-row="1"] button',0],['click','[data-row="1"] button',1],['click','[id$="-add"]'],['click','[id$="-reverse"]'],['click','[data-row="2"] button',2]]
};
// Text-node segmentation is a compiler choice; compare the same visible text.
export const snapshotFunction=`function walk(n){if(n.nodeType===3)return n.data;if(n.nodeType!==1)return null;const children=[];for(const child of n.childNodes){const v=walk(child);if(v===null||v==='')continue;if(typeof v==='string'&&typeof children.at(-1)==='string')children[children.length-1]+=v;else children.push(v);}return {tag:n.tagName,id:n.id,cls:n.className,hidden:n.hidden,disabled:n.disabled||false,value:/^(INPUT|TEXTAREA)$/.test(n.tagName)?n.value:null,attrs:[...n.attributes].filter(a=>a.name.startsWith('data-')||a.name==='role').map(a=>[a.name,a.value]).sort(),children}}`;
