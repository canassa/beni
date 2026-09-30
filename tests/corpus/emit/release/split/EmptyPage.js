const a=(b)=>{if(b.u===null||b.u.length===0){return b.i===null?b.m:l(b.i);}else{return l(b.u[0]);}},
l=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>{if(a.m===null){return a.u===null||a.u.length===0?w(a.i):w(a.u[a.u.length-1]);}else{return a.m;}},
w=(a)=>a.e===null?b(a.q):a.e,
z=(a,b,c)=>{let d=l(b);const e=w(b);for(;;){const f=d.nextSibling;a.insertBefore(d,c);if(d===e){return null;}else{d=f;}}},
A=(a)=>{let b=l(a);const c=w(a);for(;;){const d=b.nextSibling;b.remove();if(b===c){return null;}else{b=d;}}},
c=(a,b)=>{const d=l(a);z(d.parentNode,b,d);return A(a);},
d=(a,b)=>{const c=globalThis.document,e=c.createElement("template");e.innerHTML=a;const f=e.content,g=(b&2)!==0?f.firstChild:f;if((b&4)!==0){if((b&2)!==0){const h=c.createDocumentFragment();for(;;){if(g.firstChild===null){return h;}else{h.appendChild(g.firstChild);}}}else{return g;}}else{return g.firstChild;}},
e=(a,b)=>{let c=null;return()=>{if(c===null)c=d(a,b);return(b&1)!==0?globalThis.document.importNode(c,true):c.cloneNode(true);};},
B=(a,b,c)=>({b:null,cx:c,d:false,i:null,m:b,p:a,u:null,x:null,y:null,z:null}),
C=(a)=>a.p===null?a.m.parentNode:a.p,
D=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c;},
E=(a,b,d)=>{if(b===a.b){return a;}else{if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a;}else{const e=D(b,d);c(a,e);return e;}}},
F=(a,b)=>{if(a.i===null){z(C(a),b,a.m);}else{c(a.i,b);}a.i=b;return null;},
G=(a,b)=>{if(a.i===null){return F(a,D(b,a.cx));}else{a.i=E(a.i,b,a.cx);return null;}};
let f=[];
let g=false;
let h=null;
const i=(a,b)=>{for(;;){if(b===a.length){return;}else{a[b]();b=b+1;}}},
j=()=>{g=false;const a=f;f=[];i(a,0);return h===null?null:h();},
k=(a,b)=>{const c=a.n;if(b===null){return`no element has the id "${c}" to mount a program at`;}else{return a.n===null?"the page's body already holds a program":`the element "${c}" already holds a program`;}},
m=(a,b)=>{throw globalThis.Error(k(a,b));},
n=(a,b)=>{const c=B(b,null,null);let d=a.init;let e=false;const h=()=>{e=false;return G(c,a.view(d));};b.$$root=(i)=>{if(!e){e=true;f.push(h);if(!g){g=true;globalThis.queueMicrotask(()=>g?j():null);}}d=a.update(i,d);return null;};G(c,a.view(d));},
o=(a)=>{const b=globalThis.document,c=a.n===null?b.body:b.getElementById(a.n);if(c===null){m(a,c);}else{if(c.$$root!==undefined)m(a,c);}a.h===undefined?n(a.a,c):n(a.h(c,j,(d)=>{h=d;return g;}),c);},
p=(a)=>{let b=0;for(;;){if(b===a.length){return null;}else{const c=a[b];o(c);b=b+1;}}};
let q=b=>[{a:b,n:null}];
const r=e("<!>",0),
s={m:(a,b)=>{const c=r();return{s:c,q:null,e:c};},p:(d,e)=>{}},
t={t:s,v:null},
u=(a)=>t,
v=q({init:{},update:(a,b)=>b,view:u});
p(v);
export{j as flush};
