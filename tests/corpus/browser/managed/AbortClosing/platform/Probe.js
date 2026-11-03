// Observe the native constructor boundary; the opaque Handle stays in beni.
let native;
export const install = ignored => {
  const Original = globalThis.Worker;
  globalThis.Worker = function(url, options) {
    native = new Original(url, options);
    return native;
  };
  return null;
};
export const hold = ignored => {
  const target = native;
  const post=target.postMessage.bind(target);
  target.reviewClosing=false;
  target.postMessage=frame=>{
    if((frame.kind !== "Close" && frame.kind !== 4))post(frame);
    else {
      target.reviewClosing=true;
      if(target.reviewWait){const wake=target.reviewWait;target.reviewWait=null;wake(null)}
    }
  };
};
export const onClose=wake=>{
  if(native.reviewClosing)wake(null);
  else native.reviewWait=wake;
};
