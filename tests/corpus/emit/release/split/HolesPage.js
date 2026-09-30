const a=(b)=>b.u===null||b.u.length===0?b.i===null?b.m:c(b.i):c(b.u[0]),
c=(b)=>b.s===null?a(b.q):b.s,
b=(a)=>a.m===null?a.u===null||a.u.length===0?d(a.i):d(a.u[a.u.length-1]):a.m,
d=(a)=>a.e===null?b(a.q):a.e,
e=(a,b,f)=>{let g=c(b);const h=d(b);for(;;){const i=g.nextSibling;a.insertBefore(g,f);if(g===h)return;g=i}},
l=(a)=>{let b=c(a);const e=d(a);for(;;){const f=b.nextSibling;b.remove();if(b===e)return;b=f}},
f=(a,b)=>{const d=c(a);e(d.parentNode,b,d);l(a)},
g=(a,b)=>{while(a.firstChild!==null)b.appendChild(a.firstChild)},
h=(a,b)=>{let c=null;return()=>{if(c===null){const d=document,e=d.createElement("template");e.innerHTML=a;c=e.content;if(b&2)c=c.firstChild;if(b&4){if(b&2){const f=d.createDocumentFragment();g(c,f);c=f}}else c=c.firstChild}return b&1?document.importNode(c,true):c.cloneNode(true)}},
i=(a,b,c)=>({b:null,cx:c,d:false,i:null,m:b,p:a,u:null,x:null,y:null,z:null}),
q=(a)=>a.p===null?a.m.parentNode:a.p,
v=(a,b)=>{const c=a.t.m(a.v,b);c.t=a.t;c.b=a;return c},
w=(a,b,c)=>{if(b===a.b)return a;if(b.t===a.t){b.t.p(a,b.v);a.b=b;return a}const d=v(b,c);f(a,d);return d},
x=(a,b)=>{if(a.i===null)e(q(a),b,a.m);else f(a.i,b);a.i=b},
j=(a,b)=>{if(a.i===null)x(a,v(b,a.cx));else a.i=w(a.i,b,a.cx)};
let k=[],
m=false;
const n=()=>{m=false;const a=k;k=[];for(const b of a)b()},
o=(a,b)=>{const c=i(b,null,null);let d=a.init,e=false;const f=()=>{e=false;j(c,a.view(d))};b.$$root=(g)=>{if(!e){e=true;k.push(f);if(!m){m=true;queueMicrotask(()=>{if(m)n()})}}d=a.update(g,d)};j(c,a.view(d))},
p=(a)=>{for(const b of a){const c=document,d=b.n===null?c.body:c.getElementById(b.n);if(d===null||d.$$root!==undefined){const e=b.n;throw new Error(d===null?`no element has the id "${e}" to mount a program at`:b.n===null?"the page's body already holds a program":`the element "${e}" already holds a program`)}o(b.a,d)}},
r=(a,b)=>{if(b===null){if(a.i!==null){l(a.i);a.i=null}}else j(a,b)},
s=(a,b,c)=>a.insertBefore(document.createTextNode(c),b),
t=(a,b,c)=>c===null?a.removeAttribute(b):a.setAttribute(b,c),
u=(a,b,c,d)=>d===null?a.removeAttributeNS(b,c.slice(c.indexOf(":")+1)):a.setAttributeNS(b,c,d),
y={m:(a)=>{const b=document.createTextNode(a);return{d:a,e:b,q:null,s:b}},p:(c,d)=>{if(d!==c.d){c.d=d;c.s.data=d}}},
z=()=>({t:y,v:"count"}),
A={m:(a,b)=>{const c={f:a[1],up:b},d=i(null,null,c);d.i=v(a[0],c);return{c:c,e:null,q:d,s:null}},p:(e,f)=>{e.c.f=f[1];e.q.i=w(e.q.i,f[0],e.c)}},
B=(a,b)=>({t:A,v:[a,b]});
let Q=(z,event,A,C)=>{if(C&1)event.preventDefault();let F=z[`${A}X`];let E=F===undefined?z[A]:z[A](F(event));for(let D=z.$$cx;D!=null;D=D.up)E=D.f(E);let B=z.parentNode;while(B!==null&&B.$$root===undefined)B=B.parentNode;if(B!==null)B.$$root(E);if(C&2)event.stopPropagation()};let R=event=>{let A=`$$${event.type}`;for(let z=event.target;z!==null;z=z.parentNode){if(z[A]!==undefined&&!z.disabled){let C=z[`${A}F`]??0;Q(z,event,A,C);if(C&2)return}}};let S=new Set();let T=H=>{for(let name of H){if(S.has(name))continue;S.add(name);globalThis.document.addEventListener(name,R)}};let U=G=>{if(G.delegate!==undefined)T(G.delegate)};
let C=d=>String(d);
const D=(a)=>a;
const E=(a)=>[{a:a,n:null}];
const F={$:"Nothing",a:null},
G=h("<button>flip",0),
H={m:(a,b)=>{const c=G();c.$$click=a[0];if(b!==null)c.$$cx=b;return{s:c,q:null,e:c,w0:c,a0:a[0]}},p:(d,e)=>{if(e[0]!==d.a0){d.a0=e[0];d.w0.$$click=e[0]}}},
I=h("<b>on",0),
J={m:(a,b)=>{const c=I();return{s:c,q:null,e:c}},p:(d,e)=>{}},
K={t:J,v:null},
L=h("<main><p> <!></p><!><input><my-icon>",1),
M={m:(a,b)=>{const c=L(),d=c.firstChild,e=d.firstChild,f=e.nextSibling,g=d.nextSibling,h=g.nextSibling,k=h.nextSibling,l=i(d,e,b),m=i(c,g,b),n=i(c,h,b);j(l,a[0]);const o=s(d,f,a[1]);r(m,a[2].a);j(n,a[3]);t(h,"disabled",a[4]?"":null);u(k,"http://www.w3.org/XML/1998/namespace","xml:lang",a[5]);return{s:c,q:null,e:c,w5:h,w6:k,c0:l,x1:o,c2:m,c3:n,a1:a[1],a4:a[4],a5:a[5]}},p:(p,q)=>{j(p.c0,q[0]);if(q[1]!==p.a1){p.a1=q[1];p.x1.data=q[1]}r(p.c2,q[2].a);j(p.c3,q[3]);if(q[4]!==p.a4){t(p.w5,"disabled",q[4]?"":null);p.a4=q[4]}if(q[5]!==p.a5){u(p.w6,"http://www.w3.org/XML/1998/namespace","xml:lang",q[5]);p.a5=q[5]}}},
N=(a)=>{const b=!a.on;return{t:H,v:[b]}},
O=(a)=>{const b=z(),c=C(a.count),d=a.on?{$:"Just",a:K}:F,e=B(N(a),D),f=a.on,g=a.on?"en":"pt";return{t:M,v:[b,c,d,e,f,g]}},
P=E({init:{count:0,on:false},update:(a,b)=>({count:b.count+1,on:a}),view:O});
U({"delegate":["click"]});
p(P);
export{n as flush};
