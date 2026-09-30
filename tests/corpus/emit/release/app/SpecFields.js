import process from"node:process";
let e=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};
let f=b=>(Array.isArray(b)?b:b.$plain());let a=d=>{let c=f(d);return{code:0,out:c.length===0?"":`${c.join("\n")}\n`}};
let d=e=>String(e);
const b=()=>({tag:"shown",x:3,y:6}),
c=(()=>{const e=b();return a([d(e.x+e.y),e.tag])})();
e(c);
