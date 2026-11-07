export const install=()=>{};
export const fail=value=>{
  globalThis.addEventListener("message",event=>{if(event.data?.probe)event.stopImmediatePropagation()});
  for(let index=0;index<65;index++)globalThis.dispatchEvent(new globalThis.MessageEvent("message",{data:{probe:true}}));
  return value;
};
