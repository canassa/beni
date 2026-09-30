import{a,b,c,d,e,f}from"./_core/List.mjs";
import{g}from"./_platform/Node.mjs";
const h=(c,d)=>{const e=a(c);c=b(c);for(;;){if(e.length===c){return d;}else{const f=e[c],g=c+1;c=g;d=d+f;}}},
i=(c,d)=>{const e=a(c);c=b(c);const f=[];for(;;){if(e.length===c){return f;}else{const g=e[c],h=c+1;f.push(d(g));c=h;}}},
j=(e,f)=>{const g=e,h=a(e);e=b(e);const i=f,k=a(f);f=b(f);const l=[];for(;;){if(h.length===e){return d(l,k.length-f===i.length?i:c(k,f));}else{const m=h[e],n=e+1;if(k.length===f){return d(l,h.length-e===g.length?g:c(h,e));}else{const o=k[f],p=f+1;if(m<=o){l.push(m);e=n;f=f;}else{l.push(o);e=e;f=p;}}}}},
k=(d,e)=>{const f=d,g=a(d);d=b(d);for(;;){if(g.length===d){return g.length-d===f.length?f:c(g,d);}else{const h=g[d],i=d+1;if(e(h)){d=i;}else{return g.length-d===f.length?f:c(g,d);}}}},
l=(d,f)=>{const g=a(d);d=b(d);for(;;){const h=d,i=f;if(g.length===h){return i;}else{const j=h+1;d=j;f=e(i,()=>c(g,j).length);}}},
m=(c)=>{const d=a(c);c=b(c);const e=[];for(;;){f:{if(d.length>c){if(d.length>c+1){const g=d[c],h=d[c+1],i=c+2;e.push({a:g,b:h});c=i-1;continue;}else{break f;}}else{break f;}}return e;}},
n=(a,b)=>{for(;;){if(a.length===0){return b;}else{const d=c(a,1);a=f(d,1);b=b-1;}}},
o=g([]);
export{o,h,i,j,k,l,m,n};
