export const csp=policy=>{
 const meta=globalThis.document.createElement('meta');
 meta.httpEquiv='Content-Security-Policy';
 meta.content=policy;
 globalThis.document.head.appendChild(meta);
};
