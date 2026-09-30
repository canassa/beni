import process from"node:process";
let g=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let h=d=>{let b=[];for(let c=d;c.$===1;c=c.b)b.push(c.a);return b};let a=e=>{let b=h(e);return{code:0,out:b.length===0?"":`${b.join("\n")}\n`}};
let d=e=>String(e);
const b=7;
const c=b*3;
const e=b+1;
const f=a({$:1,a:d(c+e),b:{$:0,a:null,b:null}});
g(f);
