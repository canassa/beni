import{a}from"./_core/Debug.mjs";
import{b}from"./_platform/Node.mjs";
const c=(a,b)=>{for(;;){if(a<=0){return b;}else{b=b+a;a=a-1;}}},
d=()=>7,
e=(b)=>{a(b,"say");},
f=(a)=>{e(1);if(a)e(d());return 2;},
g=(a)=>a,
h=b({$:0,a:null,b:null});
export{h,c,f,g};
