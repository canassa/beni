let count=0;
let brand=false;
export const csp=policy=>{
 const Native=globalThis.Worker;
 globalThis.Worker=new Proxy(Native,{construct:(target,args)=>{count++;brand=globalThis.trustedTypes.isScriptURL(args[0]);return Reflect.construct(target,args)}});
 const meta=globalThis.document.createElement('meta');
 meta.httpEquiv='Content-Security-Policy';
 meta.content=policy;
 globalThis.document.head.appendChild(meta);
};
export const observation=()=>`constructs=${count};trusted=${brand}`;
