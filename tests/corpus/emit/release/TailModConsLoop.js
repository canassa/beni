import{a}from"./_core/List.mjs";
import{b}from"./_platform/Node.mjs";
const c=(a,b)=>{const d={$:1,a:null,b:null};let e=d;c:while(true){const f=a;if(f.$===0){e.b={$:0,a:null,b:null};return d.b;}else{const h=f.b;e.b={$:1,a:b(f.a),b:null};e=e.b;a=h;continue c;}}},
d=(a)=>{const b={$:1,a:null,b:null};let c=b;d:while(true){const e=a;if(e.$===0){c.b={$:0,a:null,b:null};return b.b;}else{const f=e.a,g=e.b;c.b={$:1,a:f,b:null};c=c.b;c.b={$:1,a:f,b:null};c=c.b;a=g;continue d;}}},
e=(a,b)=>{const c={$:1,a:null,b:null};let d=c;e:while(true){const f=a;if(f.$===0){d.b={$:0,a:null,b:null};return c.b;}else{const g=f.a,h=f.b;if(b(g)){d.b={$:1,a:g,b:null};d=d.b;a=h;continue e;}else{a=h;continue e;}}}},
f=(b,c)=>a(b,c),
g=b({$:0,a:null,b:null});
export{g,c,d,e,f};
