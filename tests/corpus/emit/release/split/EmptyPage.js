const a=(b)=>{if(b.u===null||b.u.length===0){return b.i===null?b.m:l(b.i);}else{return l(b.u[0]);}},
l=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>{if(a.m===null){return a.u===null||a.u.length===0?w(a.i):w(a.u[a.u.length-1]);}else{return a.m;}},
w=(a)=>a.e===null?b(a.q):a.e,
c=(a,b,d,e)=>{for(;;){const f=b.nextSibling;a.insertBefore(b,e);if(b===d){return null;}else{b=f;}}},
z=(a,b,d)=>c(a,l(b),w(b),d),
d=(a,b)=>{for(;;){const c=a.nextSibling;a.remove();if(a===b){return null;}else{a=c;}}},
A=(a)=>d(l(a),w(a)),
e=(a,b)=>{const c=l(a);z(c.parentNode,b,c);return A(a);},
f=(a,b)=>{for(;;){if(a.firstChild===null){return b;}else{b.appendChild(a.firstChild);}}},
g=(a,b)=>{const c=globalThis.document,d=c.createElement("template");d.innerHTML=a;const e=d.content,h=(b&2)!==0?e.firstChild:e;if((b&4)!==0){return(b&2)!==0?f(h,c.createDocumentFragment()):h;}else{return h.firstChild;}},
h=(a,b)=>{let c=null;return()=>{if(c===null)c=g(a,b);return(b&1)!==0?globalThis.document.importNode(c,true):c.cloneNode(true);};},
B=(a,b,c)=>({b:null,cx:c,d:false,i:null,m:b,p:a,u:null,x:null,y:null,z:null}),
C=(a)=>a.p===null?a.m.parentNode:a.p,
D=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c;},
E=(a,b,c)=>{if(b===a.b){return a;}else{if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a;}else{const d=D(b,c);e(a,d);return d;}}},
F=(a,b)=>{if(a.i===null){z(C(a),b,a.m);}else{e(a.i,b);}a.i=b;return null;},
G=(a,b)=>{if(a.i===null){return F(a,D(b,a.cx));}else{a.i=E(a.i,b,a.cx);return null;}};
let i=[];
let j=false;
let k=null;
const m=(a,b)=>{for(;;){if(b===a.length){return;}else{a[b]();b=b+1;}}},
n=()=>{j=false;const a=i;i=[];m(a,0);return k===null?null:k();},
o=(a,b)=>{const c=a.n;if(b===null){return`no element has the id "${c}" to mount a program at`;}else{return a.n===null?"the page's body already holds a program":`the element "${c}" already holds a program`;}},
p=(a,b)=>{throw globalThis.Error(o(a,b));},
q=()=>j?n():null,
r=(a,b)=>{const c=B(b,null,null);let d=a.init;let e=false;const f=()=>{e=false;return G(c,a.view(d));};b.$$root=(g)=>{if(!e){e=true;i.push(f);if(!j){j=true;globalThis.queueMicrotask(()=>q());}}d=a.update(g,d);return null;};G(c,a.view(d));},
s=(a)=>{k=a;return j;},
t=(a)=>{const b=globalThis.document,c=a.n===null?b.body:b.getElementById(a.n);if(c===null){p(a,c);}else{if(c.$$root!==undefined)p(a,c);}a.h===undefined?r(a.a,c):r(a.h(c,n,(d)=>s(d)),c);},
u=(a,b)=>{for(;;){if(b===a.length){return null;}else{const c=a[b];t(c);b=b+1;}}},
v=(a)=>u(a,0);
let x=b=>[{a:b,n:null}];
const y=h("<!>",0),
H={m:(a,b)=>{const c=y();return{s:c,q:null,e:c};},p:(d,e)=>{}},
I={t:H,v:null},
J=(a)=>I,
K=x({init:{},update:(a,b)=>b,view:J});
v(K);
export{n as flush};
