let events=0;
const terminals=[];
export const install=()=>{
  const Native=globalThis.Worker;
  globalThis.Worker=function(url,options){
    const worker=new Native(url,options);
    worker.addEventListener("message",event=>{
      if((event.data.kind === "Event" || event.data.kind === 14))events++;
      if((event.data.kind === "Interrupt" || event.data.kind === 6))terminals.push(events);
    });
    return worker;
  };
};
export const trace=()=>terminals.join(",");
