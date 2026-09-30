import process from"node:process";
let j=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let k=f=>Array.from(f);let d=f=>k(f).length;let e=g=>String(g);
let l=a=>(Array.isArray(a)?a:a.$plain());let b=d=>{let c=l(d);return{code:0,out:c.length===0?"":`${c.join("\n")}\n`}};
const c=(a)=>{for(;;){if(d(a)>=6)return a;a+="."}},
f=(a)=>a,
g=()=>6,
h=()=>"quiet",
i=b([c("ab"),c("abcdefgh"),e(f(5)),e(f(7)),e(g()),h()]);
j(i);
