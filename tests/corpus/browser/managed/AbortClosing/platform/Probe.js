export const hold = handle => {
  const native=handle.native;
  const post=native.postMessage.bind(native);
  native.reviewClosing=false;
  native.postMessage=frame=>{
    if(frame.kind!=="Close")post(frame);
    else {
      native.reviewClosing=true;
      if(native.reviewWait){const wake=native.reviewWait;native.reviewWait=null;wake(null)}
    }
  };
};
export const onClose=(handle,wake)=>{
  if(handle.native.reviewClosing)wake(null);
  else handle.native.reviewWait=wake;
};
