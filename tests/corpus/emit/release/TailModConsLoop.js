import{a,b,c}from"./_core/List.mjs";
import{d}from"./_platform/Node.mjs";
const e=(c,d)=>{const f=[];for(;;){if(c.length===0){return f;}else{const g=a(c,0),h=b(c,1);f.push(d(g));c=h;}}},
f=(c)=>{const d=[];for(;;){if(c.length===0){return d;}else{const e=a(c,0),g=b(c,1);d.push(e);d.push(e);c=g;}}},
g=(c,d)=>{const e=[];for(;;){if(c.length===0){return e;}else{const f=a(c,0),h=b(c,1);if(d(f)){e.push(f);c=h;}else{c=h;}}}},
h=(a,b)=>c(a,b),
i=d([]);
export{i,e,f,g,h};
