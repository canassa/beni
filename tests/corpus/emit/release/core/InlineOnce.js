import{a,b}from"./_core/String.mjs";
const c=(a,b,d)=>{let e=b.first;const f=b.last;for(;;){const g=e.nextSibling;a.insertBefore(e,d);if(e===f){return null;}else{e=g;}}},
d=(c,e)=>a(b(c*2+1),e),
e=(b,c)=>c?a(b,"!"):b,
f=(a)=>a===0?"none":"some",
g=(a)=>f(a-1),
h=(a)=>a*2,
i=(a)=>h(a)+h(a+1),
j=(a)=>a+1,
k=j(41);
export{c,d,e,g,i,j,k};
