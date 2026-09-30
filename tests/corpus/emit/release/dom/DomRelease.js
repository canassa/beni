import{delegate as a}from"./_platform/runtime.foreign.mjs";
import{b}from"./_platform/Rt.mjs";
const c=b("<tr><td><a> ",0),
d={m:(b,e)=>{const f=c(),h=f.firstChild.firstChild,i=h.firstChild;a(["click"]);h.$$click=b[0];if(e!==null)h.$$cx=e;i.data=b[1];return{s:f,q:null,e:f,w2:h,w3:i,a0:b[0],a1:b[1]}},p:(j,k)=>{if(k[0]!==j.a0){j.a0=k[0];j.w2.$$click=k[0]}if(k[1]!==j.a1){j.a1=k[1];j.w3.data=k[1]}}},
e=(a,b)=>a.a<b.a?"LT":a.a>b.a?"GT":"EQ",
f=(a,b)=>a.a===b.a,
g=(a)=>{const b={$:"Pick",a:a.id};return{t:d,v:[b,a.label]}},
h=(a)=>({...a,label:"x"});
export{e,f,g,h};
