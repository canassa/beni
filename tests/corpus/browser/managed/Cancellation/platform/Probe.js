let events=0;
const terminals=[];
export const install=()=>{
  const Native=globalThis.Worker;
  globalThis.Worker=function(url,options){
    const worker=new Native(url,options);
    worker.addEventListener("message",event=>{
      if(event.data.kind==="Event")events++;
      if(event.data.kind==="Interrupt")terminals.push(events);
    });
    return worker;
  };
};
export const trace=()=>terminals.join(",");
