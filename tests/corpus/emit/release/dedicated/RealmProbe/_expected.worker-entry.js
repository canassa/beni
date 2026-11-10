globalThis.__beniWorkerFingerprint = "8e2ec2daaa9d71f4-78e412bd1d8bbac1";
const report = event => {
  const cause = event.error ?? event.reason;
  globalThis.postMessage({worker: 1, kind: "Defect", payload: {
    name: typeof cause?.name === "string" ? cause.name.slice(0, 64) : null,
    message: String(cause?.message ?? event.message ?? cause ?? "Worker defect").slice(0, 4096),
    stack: String(cause?.stack ?? "").slice(0, 16384)
  }});
};
globalThis.addEventListener("error", report);
globalThis.addEventListener("unhandledrejection", report);
const pending = [];
const hold = event => {
  event.stopImmediatePropagation();
  if (pending.length === 64) {
    for (const port of event.ports ?? []) port.close();
    throw new RangeError("Worker startup message queue is full");
  }
  pending.push(event);
};
globalThis.addEventListener("message", hold);
globalThis.addEventListener("messageerror", hold);
try {
const M=(m,q,b)=>{if(m===null)return b;let[roles,nodes]=m;let i=b=>{if(b===null||typeof b!=="object")return b;if(typeof b.$plain==="function")return i(b.$plain());let d=b;for(let c of Object.keys(b)){let e=i(b[c]);if(e===b[c])continue;if(d===b)d=Array.isArray(b)?[...b]:{...b};d[c]=e}return d};let h=(j,b)=>{let f=nodes[j];if(f===0)return b;let[kind,edges]=f;if(kind===1){let n=Array.isArray(b)?b:b.$plain();return nodes[edges[0][1]]===0?n:n.map(r=>h(edges[0][1],r))}if(kind===5)return i(b);if(kind===4){let s=edges.find(t=>t[0]===b.$);return h(s[1],b)}let d=b;for(let[c,child]of edges){if(nodes[child]===0)continue;let e=h(child,b[c]);if(e===b[c])continue;if(d===b)d={...b};d[c]=e}return d};let o=(b,g,f,k=0)=>{if(k===g.length)return h(f,b);let c=g[k];let e=o(b[c],g,f,k+1);return e===b[c]?b:{...b,[c]:e}};for(let[j,f,g]of roles){if(j===q)b=o(b,g,f)}return b};let N=null;let O=null;const P=[];const H=u=>{N=u.$wire;globalThis.addEventListener("message",event=>{if(O===null)P.push(event.data);else O(event.data)})};const I=p=>{O=p;for(let l of P)p(l);P.length=0};const J=l=>{globalThis.postMessage(M(N,1,l))};const a={$:1,a:null},b={};let c=null,d=null;const e=[];let f=0,g=false,h=null;const i=[],j=a=>{let b=globalThis.setImmediate;if(typeof b==="function")b(a);else{if(h===null){let c=new globalThis.MessageChannel();c.port1.onmessage=()=>i.shift()();h=c.port2}i.push(a);h.postMessage(null)}};let k=0,l=false,m=null,n=false,o=null,p=0;const q=[],r=()=>{k=3;let a=o;if(a!==null)clearTimeout(a);o=null},s=(a,b)=>{a.outcome=b;a.stack=null;p--;let c=a.scope;if(c!==null)c.children.delete(a);else{let d=q.indexOf(a);if(d>=0)q.splice(d,1)}let e=a.observers;a.observers=null;if(e!==null){for(let b of e)b(a)}if(p===0&&k===2)r()},t=()=>s(d,a),u=a=>{if(!(a.outcome!==null||a.unwinding)){a.interrupted=true;let b=a.parked;if(!(b===null||a.masks!==0)){a.parked=null;b.done=true;v(a);let c=b.cancel;if(c!==null)c(null)}}},w=(a,b)=>{if(a.observers===null)a.observers=[b];else a.observers.push(b)},x=a=>{a.unwinding=true;a.parked=null;let b=a.stack;b.length=0;b.push(t)},y=(a,e,f)=>{if(f!==null&&a.parked!==f)return false;let g=d;d=a;a.parked=null;let h=e;for(;;){let e;if(a.interrupted&&a.masks===0&&!a.unwinding){x(a);e=null}else e=h;let g=a.stack.pop()(e);if(a.outcome!==null)break;if(g===b){let i=c;c=null;let j=i.ks,k=a.stack;for(let l=j.length-1;!(l<0);l--)k.push(j[l]);if(!i.interrupt){a.parked=i.wait;break}x(a);h=null}else h=g}d=g;return true},z=[];let A=0;const B=a=>{a.interrupted=true;a.parked=null;a.masks=0;if(!a.unwinding)x(a);else{let b=a.stack;if(b.length===0)b.push(t)}},C=()=>{if(k===1){k=2;for(let a of q)if(a.stack===undefined){a.closed=true;for(let b of a.children)z.push(b)}else z.push(a)}let a=false;try{for(;;){let a=A;if(!(a<z.length))break;A=a+1;u(z[a])}a=true}finally{if(!a)j(C)}let b=m;if(b!==null){m=null;if(b.outcome===null){B(b);v(b)}}p===0?r():D()},D=()=>{if(!(k&1)){let a=false,b;try{let h=0,i;for(;;){let a=f;if(a>=e.length){i=true;break}if(h===64||k===1){let b=e.length;if(a>=65536&&a>=b-a){e.copyWithin(0,a);e.length=b-a;f=0}j(E);i=false;break}let o=e[a],p=e[a+1],q=e[a+2],r=e[a+3];e[a]=null;e[a+1]=null;e[a+2]=null;e[a+3]=null;f=a+4;h=o(p,q,r)?h+1:h}a=true;b=i}finally{if(!a)if(l){let b=d;d=null;c=null;if(k<2){m=b;if(k===0)k=1;g=true;if(!n){n=true;j(C)}}else{if(b!==null&&b.outcome===null){B(b);v(b)}j(E)}}else k=1}if(b){e.length=0;f=0;g=false}}},E=D,v=a=>{e.push(y,a,null,null);if(!g){g=true;queueMicrotask(E)}},F=a=>{d.unwinding=true;s(d,{$:0,a:a});return a},G=(a,b)=>{l=true;let c={children:null,finalizers:null,interrupted:false,masks:0,observers:null,outcome:null,parent:null,parked:null,scope:null,stack:[F,a],unwinding:false};p++;q.push(c);if(k!==0)c.interrupted=true;v(c);w(c,a=>b(a.outcome))};const K=a=>{let b=a.a;H(a);return G(()=>{let a=b.init(null,null);I(c=>G(()=>J(b.handle(c,a,null)),()=>null));return b.start(a,null)},()=>null)};const L=(()=>{let d={$:"Program",a:{handle:()=>globalThis.document===undefined?"no document":"document",init:()=>null,start:()=>null}};return d.$wire=[[[0,0,[],[]],[1,1,[],[]]],[0,0,0,0]],d})();K(L);
} finally {
  globalThis.removeEventListener("message", hold);
  globalThis.removeEventListener("messageerror", hold);
}
for (const event of pending) globalThis.dispatchEvent(new MessageEvent(event.type, {
  data: event.data, origin: event.origin, lastEventId: event.lastEventId,
  source: event.source, ports: event.ports
}));
