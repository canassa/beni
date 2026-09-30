import{a}from"./_platform/Io.mjs";
import{b,c}from"./_core/Task.mjs";
const d=(c)=>b(a(c),(e)=>c+1),
e=(a)=>{const c=(f)=>f*2;if(a>0){return b(d(a),(h)=>c(h));}else{return c(0);}},
f=(a,e)=>{f:for(;;){const g=a,h=e;if(g.$===0){return h;}else{const j=g.b,k=d(g.a);if(c(k))return b(k,(k)=>{a=j;e=h+k;return f(a,e);});a=j;e=h+k;}}},
g=(a,b)=>a(a(b)),
h=(a,c)=>b(a(c),(d)=>a(d)),
i=(a)=>b(h(d,a),(c)=>c+g((e)=>e+1,a)),
j=(a)=>a<=0?0:a+j(a-1);
export{d,e,f,i,j};
