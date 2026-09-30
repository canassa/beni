import{a}from"./_core/Basics.mjs";
import{b}from"./_core/String.mjs";
const c=(a,b,d)=>{for(;;){if(d===a.length)return 0-1;if(a[d]===b)return d;d=d+1;}},
d=(c)=>{if(c<0){const e=0-c;return a("minus ",b(e));}if(c===0)return"zero";const f=b(c);return a("plus ",f);},
e=(a)=>{if(a.v!==null)throw"set twice";a.v=1;a.n=0;a.done=true;},
f=(a)=>{if(a!==null)if(a.a===undefined)a.a=1;else a.b=2;};
export{c,d,e,f};
