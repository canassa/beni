import{a}from"./_platform/Io.mjs";
import{b,c,d}from"./_core/Basics.mjs";
import{e,f}from"./_core/Task.mjs";
const g=(c)=>e(a(c),(d)=>b(c,1)),
h=(a)=>{const b=(d)=>c(d,2);if(a>0){return e(g(a),(i)=>b(i));}else{return b(0);}},
i=(a,c)=>{i:while(true){const d=a,h=c;if(d.$===0){return h;}else{const k=d.b,l=g(d.a);if(f(l))return e(l,(l)=>{a=k;c=b(h,l);return i(a,c);});a=k;c=b(h,l);continue i;}}},
j=(a,b)=>a(a(b)),
k=(a,b)=>e(a(b),(c)=>a(c)),
l=(a)=>e(k(g,a),(c)=>b(c,j((d)=>b(d,1),a))),
m=(a)=>a<=0?0:b(a,m(d(a,1)));
export{g,h,i,l,m};
