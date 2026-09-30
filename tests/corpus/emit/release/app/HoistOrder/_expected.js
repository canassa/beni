import process from"node:process";
let g=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let h=b=>(Array.isArray(b)?b:b.$plain());let a=d=>{let c=h(d);return{code:0,out:c.length===0?"":`${c.join("\n")}\n`}};
let d=e=>String(e);
const b=7;
const c=21;
const e=8;
const f=a([d(29)]);
g(f);
