import{a,b}from"./_core/Basics.mjs";
import{c}from"./_platform/Node.mjs";
const d=(a,b)=>{const c=a.a<b.a?"LT":a.a>b.a?"GT":"EQ";if(c!=="EQ")return c;return a.b<b.b?"LT":a.b>b.b?"GT":"EQ";},
e=(a,b)=>a.a===b.a&&a.b===b.b,
f=(b)=>a(b.a,b.b),
g=(a)=>({$:"Pair",a:a.b,b:a.a}),
h=(a)=>{const c=a.a;return b(c,c);},
i=(b)=>{const c=f(b);return a(c,1);},
j=c({$:0,a:null,b:null});
export{d,e,j,f,g,h,i};
