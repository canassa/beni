import process from"node:process";
let j=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let k=f=>Array.from(f);let d=f=>k(f).length;let e=g=>String(g);
let a=(b,c)=>{if(typeof b==="string")return b+c;if(c.length===0)return b;if(b.length===0)return c;return(Array.isArray(b)?b:b.$plain()).concat(Array.isArray(c)?c:c.$plain())};
let l=a=>(Array.isArray(a)?a:a.$plain());let b=d=>{let c=l(d);return{code:0,out:c.length===0?"":`${c.join("\n")}\n`}};
const c=3,
f=(b)=>{for(;;){if(d(b)>=6){return b;}else{b=a(b,".");}}},
g=(a)=>a,
h=()=>6,
i=b([f("ab"),f("abcdefgh"),e(g(5)),e(g(7)),e(h())]);
j(i);
