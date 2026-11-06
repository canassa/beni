export const install=()=>{
  const Native=globalThis.Worker;
  globalThis.Worker=function(url,options){
    const worker=new Native(url,options);
    worker.addEventListener("message",event=>{
      if(event.data?.probeCleanup){event.stopImmediatePropagation();globalThis.document.querySelector("#stage").textContent=event.data.probeCleanup}
    });
    return worker;
  };
};
export const fail=value=>{
  const remove=globalThis.removeEventListener.bind(globalThis);
  const removed=[];
  globalThis.removeEventListener=(kind,callback)=>{
    remove(kind,callback);
    if(kind==="message"||kind==="messageerror"){
      removed.push(kind);
      if(removed.join(",")==="message,messageerror")globalThis.postMessage({probeCleanup:"both holds removed"});
    }
  };
  throw new globalThis.Error(value);
};
