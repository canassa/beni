// Fetch only the four pinned assets needed by research 29's existing runner.
// Solid's builds use bench/ui/apps/solid2's committed package-lock.json.
import {readFileSync,writeFileSync,mkdirSync,existsSync} from 'node:fs';
import {createHash} from 'node:crypto';
const base='https://raw.githubusercontent.com/krausest/js-framework-benchmark/652198560d0ccdafb9be833dac53e154bd1a0d1d/';
const entries=[
 ['css/currentStyle.css','css/currentStyle.css','45f7d016571351942baf18489716fb342532a305feda38f2f98112109933e22c'],
 ['css/main.css','css/main.css','d8d5b527c71c8a71fd273310650180318f8e8361334d96c9a27bdc85fa1b75e3'],
 ['css/bootstrap/dist/css/bootstrap.min.css','css/bootstrap/dist/css/bootstrap.min.css','eece6e0c65b7007ab0eb1b4998d36dafe381449525824349128efc3f86f4c91c'],
 ['frameworks/keyed/vanillajs/src/Main.js','jfb/Main.js','08a5cb7d5cec199396561ed28b3c2db77577f066480f33c19f22ce6b0b0c980f'],
];
for(const [source,dest,expected] of entries){
 const url=new URL('../ui/out/'+dest,import.meta.url);
 let bytes;
 if(existsSync(url))bytes=readFileSync(url);else{const response=await fetch(base+source);if(!response.ok)throw new Error('fetch '+response.status);bytes=Buffer.from(await response.arrayBuffer())}
 const actual=createHash('sha256').update(bytes).digest('hex');if(actual!==expected)throw new Error(dest+' hash mismatch');
 mkdirSync(new URL('.',url),{recursive:true});writeFileSync(url,bytes);
}
console.log('Verified four pinned JFB assets');
