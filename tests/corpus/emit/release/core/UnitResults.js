const a=(b,c)=>{if(b.i===null)b.first=c;else b.prev=b.i;b.i=c},
b=(a,c)=>{for(;;){if(c===a.length)return;a[c]();c=c+1}},
c=(b,d)=>{let e=0;function f(g){if(!(g>3))a(d,g)}b.$$send=(h)=>{f(e);e=h}},
d=(a)=>a===null?0:a.length;
export{a,b,c,d};
