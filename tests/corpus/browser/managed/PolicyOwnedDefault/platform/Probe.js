let count=0;
let callbackCount=0;
let brand=false;
export const arm=mode=>{
 const Native=globalThis.Worker;
 globalThis.Worker=new Proxy(Native,{construct:(target,args)=>{count++;brand=globalThis.trustedTypes.isScriptURL(args[0]);return Reflect.construct(target,args)}});
 if(mode==='null'||mode==='empty')globalThis.trustedTypes.createPolicy('default',{createScriptURL:()=>{callbackCount++;return mode==='null'?null:''}});
};
export const observation=()=>`constructs=${count};callbacks=${callbackCount};trusted=${brand}`;
export const trusted=url=>globalThis.trustedTypes.isScriptURL(url);
export const throwing=_=>{throw new TypeError('policy allow exploded')};
