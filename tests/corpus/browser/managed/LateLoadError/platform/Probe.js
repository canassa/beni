let worker;
export const install=()=>{
  const Native=globalThis.Worker;
  globalThis.Worker=function(url,opts){
    worker=new Native(url,opts);
    const post=worker.postMessage.bind(worker);
    worker.postMessage=frame=>{if(frame.kind!=="Hello"&&frame.kind!=="Close")post(frame)};
    queueMicrotask(()=>{
      worker.dispatchEvent(new globalThis.Event("error"));
      globalThis.document.querySelector("#stage").textContent="load failed";
    });
    return worker;
  };
};
export const late=()=>{worker.dispatchEvent(new globalThis.Event("error"));worker.terminate()};
