import{a}from"./_core/List.mjs";
import{b}from"./_platform/Node.mjs";
const c=(a,b)=>{const d={$:1,a:null,b:null};let e=d;for(;;){if(a.$===0){e.b={$:0,a:null,b:null};return d.b;}else{const f=a.a,g=a.b;e.b={$:1,a:b(f),b:null};e=e.b;a=g;}}},
d=(a)=>{const b={$:1,a:null,b:null};let c=b;for(;;){if(a.$===0){c.b={$:0,a:null,b:null};return b.b;}else{const e=a.a,f=a.b;c.b={$:1,a:e,b:null};c=c.b;c.b={$:1,a:e,b:null};c=c.b;a=f;}}},
e=(a,b)=>{const c={$:1,a:null,b:null};let d=c;for(;;){if(a.$===0){d.b={$:0,a:null,b:null};return c.b;}else{const f=a.a,g=a.b;if(b(f)){d.b={$:1,a:f,b:null};d=d.b;a=g;}else{a=g;}}}},
f=(b,c)=>a(b,c),
g=b({$:0,a:null,b:null});
export{g,c,d,e,f};
