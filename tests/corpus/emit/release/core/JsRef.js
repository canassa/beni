const a=(b)=>{let c=null;return()=>{if(c===null){const d=globalThis.document.createElement("template");d.innerHTML=b;c=d.content.firstChild;}return c.cloneNode(true);};};
let b=false;
const c=()=>{b=false;},
d=()=>{if(!b){b=true;globalThis.queueMicrotask(()=>b?c():null);}},
e=(a)=>({v:a}),
f=(a)=>{a.v=a.v+1;},
g=(a)=>{const b=e(a);f(b);return b.v;};
export{a,c,d,e,f,g};
