import{a,b,c}from"./_core/List.mjs";
import{d}from"./_platform/Node.mjs";
const e=(c,d)=>{const f=a(c);c=b(c);const g=[];while(f.length!==c){const h=f[c],i=c+1;g.push(d(h));c=i}return g},
f=(c)=>{const d=a(c);c=b(c);const e=[];while(d.length!==c){const g=d[c],h=c+1;e.push(g);e.push(g);c=h}return e},
g=(c,d)=>{const e=a(c);c=b(c);const f=[];while(e.length!==c){const h=e[c],i=c+1;if(d(h)){f.push(h);c=i}else c=i}return f},
h=(a,b)=>c(a,b),
i=d([]);
export{i,e,f,g,h};
