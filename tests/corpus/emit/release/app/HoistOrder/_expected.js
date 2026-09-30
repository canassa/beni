import process from"node:process";
let h=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let i=b=>(Array.isArray(b)?b:b.$plain());let a=d=>{let c=i(d);return{code:0,out:c.length===0?"":`${c.join("\n")}\n`}};
let j=f=>Array.from(f);let d=f=>j(f).length;let e=g=>String(g);
const b=d("seven!!");
const c=b*3;
const f=b+1;
const g=a([e(c+f)]);
h(g);
