import{a,b,c}from"./core/Basics.mjs";
import{d}from"./platform/Node.mjs";
const e=(c)=>{const d=a(c,2),f=a(d,3),g=a(f,4);return b(b(d,f),g);};
const f=(b)=>b>0?a(b,2):c(b,1);
const g=(a,d)=>{g:while(true){const e=a,f=d;if(e<=0){return f;}else{a=c(e,1);d=b(f,e);continue g;}}};
const h=(b)=>({count:b,label:a(b,2)});
const i=d({$:0,a:null,b:null});
export{i,e,f,g,h};
