import process from"node:process";const c=a=>{if(a.out.length!==0)process.stdout.write(a.out);process.exitCode=a.code};const a=b=>({code:0,out:`${b}\n`});const b=a(String(73));c(b);
