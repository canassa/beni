import process from"node:process";
let k=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let l=f=>Array.from(f);let d=f=>l(f).length;let e=g=>String(g);
let b=(a,c)=>{if(typeof a==="string")return a+c;if(c.length===0)return a;if(a.length===0)return c;return(Array.isArray(a)?a:a.$plain()).concat(Array.isArray(c)?c:c.$plain())};
let m=a=>(Array.isArray(a)?a:a.$plain());let c=d=>{let b=m(d);return{code:0,out:b.length===0?"":`${b.join("\n")}\n`}};
const f=(a)=>{for(;;){if(d(a)>=6)return a;a=b(a,".");}},
g=(a)=>a,
h=()=>6,
i=()=>"quiet",
j=c([f("ab"),f("abcdefgh"),e(g(5)),e(g(7)),e(h()),i()]);
k(j);
