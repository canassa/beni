export const arm=()=>{const Native=globalThis.Worker;globalThis.Worker=function(url,options){throw new globalThis.RangeError("unmatched constructor");}};
