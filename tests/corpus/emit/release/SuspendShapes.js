import{a}from"./_platform/Io.mjs";
import{b,c}from"./_core/Task.mjs";
import{d,e}from"./_core/List.mjs";
const f=(c)=>b(a(c),(d)=>c+1),
g=(a)=>{const c=(d)=>d*2;if(a>0)return b(f(a),(h)=>c(h));return c(0)},
h=(a,g)=>{h:for(;;){const i=a,j=g;if(i.length===0)return j;else{const k=d(i,0),l=e(i,1),m=f(k);if(c(m))return b(m,(m)=>{a=l;g=j+m;return h(a,g)});a=l;g=j+m}}},
i=(a,b)=>a(a(b)),
j=(a,c)=>b(a(c),(d)=>a(d)),
k=(a)=>b(j(f,a),(c)=>c+i((d)=>d+1,a)),
l=(a)=>a<=0?0:a+l(a-1);
export{f,g,h,k,l};
